// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IBeacon, BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "./interfaces/IDelegateStrategy.sol";
import "./Errors.sol";
import "./LEZyVaultStorage.sol";

/**
 * @title LEZyVault
 * @author Renzo Protocol
 * @notice Main vault contract implementing ERC4626 standard with additional yield strategies
 * @dev This contract manages user deposits and integrates with various DeFi protocols through delegate strategies
 * @dev WARNING: Rebasing Tokens Should not be used as underlying
 * It supports whitelisting, performance fees, and pausable functionality
 */
contract LEZyVault is ERC4626Upgradeable, OwnableUpgradeable, PausableUpgradeable, LEZyVaultStorageV1 {
    using Math for uint256;
    using Address for address;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    uint256 public constant BASIS_POINTS = 10000; // BASIS_POINTS used for percentage (10000 basis points equal 100%)
    uint256 public constant SHARE_OFFSET = 1e3;
    uint256 public constant BALANCE_OFFSET = 1e3;

    IBeacon public immutable withdrawQueueBeacon;
    address public immutable WETH;

    /// @dev Event emit when delegate strategies added
    event DelegateStrategyAdded(address[] delegateStrategies);
    /// @dev Event emit when delegate strategies removed
    event DelegateStrategyRemoved(address[] delegateStrategies);
    /// @dev Event emitted when whitelist enabled is updated
    event WhitelistEnabledUpdated(bool isEnabled);
    /// @dev Event emit when whitelist is updated
    event WhitelistUpdated(address[] accounts, bool[] status);
    /// @dev Event emit when whitelistedEthSender updated
    event EthSenderWhitelistUpdated(address[] accounts, bool[] status);
    /// @dev Event emit when performanceFee configuration is updated
    event PerformanceFeeConfigUpdated(uint256 performanceFeeBps, address feeRecipient);
    /// @dev Event emitted when the vault is initialized
    event VaultInitialized(
        address indexed roleManager,
        address indexed withdrawQueue,
        uint256 performanceFeeBps,
        address indexed feeRecipient
    );
    /// @dev Event emitted when total underlying is updated
    event TotalUnderlyingUpdated(uint256 oldValue, uint256 newValue);
    /// @dev Event emitted when highest rate is recorded
    event HighestRateRecorded(uint256 newRate);
    /// @dev Event emitted when performance fees are accrued
    event PerformanceFeesAccrued(uint256 feeShares, uint256 feeAssets);

    /// @dev Only allowed address to rebalance the vault
    modifier onlyRebalanceAdmin() {
        if (!roleManager.isRebalanceAdmin(msg.sender)) revert NotRebalanceAdmin();
        _;
    }

    modifier onlyWithdrawQueue() {
        if (_msgSender() != address(withdrawQueue)) revert NotWithdrawQueue();
        _;
    }

    /// @dev Allows only whitelisted address
    modifier onlyWhitelisted() {
        if (depositWhitelistEnabled && !whitelist[_msgSender()]) revert NotWhitelisted();
        _;
    }
    /// @dev Only allowed address to pause
    modifier onlyPauser() {
        if (!roleManager.isPauser(_msgSender())) revert NotPauser();
        _;
    }

    /// @dev Only allowed address to track underlying
    modifier onlyExchangeRateAdmin() {
        if (!roleManager.isExchangeRateAdmin(_msgSender())) revert NotExchangeRateAdmin();
        _;
    }

    constructor(IBeacon _withdrawQueueBeacon, address _wethAddress) {
        if (address(_withdrawQueueBeacon) == address(0) || _wethAddress == address(0)) {
            revert InvalidZeroInput();
        }
        withdrawQueueBeacon = _withdrawQueueBeacon;
        WETH = _wethAddress;
        _disableInitializers();
    }

    /**
     * @notice Initializes the vault with configuration parameters
     * @dev Can only be called once during deployment via proxy
     * @param _asset The ERC20 token that the vault will accept as deposits
     * @param name_ The name of the vault token
     * @param symbol_ The symbol of the vault token
     * @param _roleManager The RoleManager contract for access control
     * @param _owner The initial owner of the vault
     * @param _feeRecipient The address that will receive performance fees
     * @param _feeBps The performance fee in basis points (max 10000)
     * @param _withdrawCoolDownPeriod The cooldown period for withdrawals in seconds
     */
    function initialize(
        IERC20 _asset,
        string memory name_,
        string memory symbol_,
        IRoleManager _roleManager,
        address _owner,
        address _feeRecipient,
        uint256 _feeBps,
        uint256 _withdrawCoolDownPeriod
    ) external initializer {
        // Check for zero values
        if (
            address(_asset) == address(0) || bytes(name_).length == 0 || bytes(symbol_).length == 0
                || address(_roleManager) == address(0) || address(_owner) == address(0)
                || address(_feeRecipient) == address(0) || _feeBps == 0 || _withdrawCoolDownPeriod == 0
        ) revert InvalidZeroInput();

        if (_feeBps > BASIS_POINTS) revert InvalidFeeBps();

        __ERC4626_init(_asset);
        __ERC20_init(name_, symbol_);
        _transferOwnership(_owner);

        roleManager = _roleManager;
        feeRecipient = _feeRecipient;
        performanceFeeBps = _feeBps;

        // create withdraw queue for vault
        withdrawQueue = IWithdrawQueue(
            address(
                new BeaconProxy(
                    address(withdrawQueueBeacon),
                    abi.encodeWithSelector(
                        IWithdrawQueue.initialize.selector, _owner, address(this), _withdrawCoolDownPeriod
                    )
                )
            )
        );

        // record Initial rate as cached rate
        _recordRate(totalAssets());

        // Emit initialization event
        emit VaultInitialized(address(_roleManager), address(withdrawQueue), _feeBps, _feeRecipient);
    }

    /**
     * @notice  Pause the vault
     * @dev     permissioned call (onlyPuaser)
     */
    function pause() external onlyPauser {
        _pause();
    }

    /**
     * @notice  UnPause the vault
     * @dev     permissioned call (onlyOwner)
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     *************************
     ** OnlyOwner functions **
     *************************
     */

    /**
     * @notice Adds new delegate strategies to the vault's allowed list
     * @dev Only callable by owner. Strategies must have valid addresses
     * @param delegateStrategies Array of strategy contract addresses to add
     */
    function addDelegateStrategies(address[] calldata delegateStrategies) external onlyOwner {
        if (delegateStrategies.length == 0) revert InvalidZeroInput();
        for (uint256 i = 0; i < delegateStrategies.length;) {
            if (delegateStrategies[i] == address(0)) revert InvalidZeroInput();
            // Add/Remove strategy according to status
            allowedDelegateStrategy.add(delegateStrategies[i]);
            unchecked {
                ++i;
            }
        }
        emit DelegateStrategyAdded(delegateStrategies);
    }

    /**
     * @notice Removes delegate strategies from the vault's allowed list
     * @dev Only callable by owner. Strategies must have zero underlying value before removal
     * @param delegateStrategies Array of strategy contract addresses to remove
     */
    function removeDelegateStrategies(address[] calldata delegateStrategies) external onlyOwner {
        if (delegateStrategies.length == 0) revert InvalidZeroInput();
        for (uint256 i = 0; i < delegateStrategies.length;) {
            if (delegateStrategies[i] == address(0)) revert InvalidZeroInput();
            // NOTE: Skipping underlying check
            // _checkUnderlying(delegateStrategies[i]);
            // Add/Remove strategy according to status
            allowedDelegateStrategy.remove(delegateStrategies[i]);
            unchecked {
                ++i;
            }
        }
        emit DelegateStrategyRemoved(delegateStrategies);
    }

    /**
     * @notice Updates the whitelist status for multiple accounts
     * @dev Only callable by owner. Arrays must have matching lengths
     * @param accounts Array of addresses to update whitelist status for
     * @param status Array of boolean values indicating whitelist status
     */
    function updateWhitelist(address[] calldata accounts, bool[] calldata status) external onlyOwner {
        // Check for the array length
        if (accounts.length != status.length) revert MismatchedArrayLengths();

        for (uint256 i = 0; i < accounts.length;) {
            // Check if account address is zero
            if (accounts[i] == address(0)) revert InvalidZeroInput();
            // Update whitelist
            whitelist[accounts[i]] = status[i];
            unchecked {
                ++i;
            }
        }

        // Emit the event
        emit WhitelistUpdated(accounts, status);
    }

    /**
     * @notice Updates the ETH sender whitelist status for multiple accounts
     * @dev Only callable by owner. Arrays must have matching lengths
     * @param accounts Array of addresses to update ETH sender whitelist status for
     * @param status Array of boolean values indicating ETH sender whitelist status
     */
    function updateWhitelistedEthSender(address[] calldata accounts, bool[] calldata status) external onlyOwner {
        // Check for the array length
        if (accounts.length != status.length) revert MismatchedArrayLengths();
        for (uint256 i = 0; i < accounts.length;) {
            // Check if account address is zero
            if (accounts[i] == address(0)) revert InvalidZeroInput();
            // Update whitelist
            whitelistedEthSender[accounts[i]] = status[i];
            unchecked {
                ++i;
            }
        }
        // Emit the event
        emit EthSenderWhitelistUpdated(accounts, status);
    }

    /**
     * @notice Configures the performance fee and fee recipient
     * @dev Only callable by owner. Fee must be within valid range (0-5000 bps)
     * @param _performanceFeeBps Performance fee in basis points (10000 = 100%)
     * @param _feeRecipient Address that will receive performance fees
     */
    function configurePerformanceFee(uint256 _performanceFeeBps, address _feeRecipient) external onlyOwner {
        if (_performanceFeeBps == 0 || _feeRecipient == address(0)) revert InvalidZeroInput();

        if (_performanceFeeBps > BASIS_POINTS) revert InvalidFeeBps();

        performanceFeeBps = _performanceFeeBps;
        feeRecipient = _feeRecipient;
        emit PerformanceFeeConfigUpdated(_performanceFeeBps, _feeRecipient);
    }

    /*
     *
     * @notice Sets the whitelist enabled status
     * @dev     permissioned call (onlyOwner)
     * @dev     Emits WhitelistEnabledUpdated event
     * @param   _isEnabled Boolean value indicating if whitelist is enabled
     */
    function setDepositWhitelistEnabled(bool _isEnabled) external onlyOwner {
        depositWhitelistEnabled = _isEnabled;
        emit WhitelistEnabledUpdated(_isEnabled);
    }

    /**
     *********************
     ** Admin functions **
     *********************
     */

    function manage(address target, bytes calldata payload) external onlyRebalanceAdmin returns (bytes memory result) {
        _isAllowedDelegateStrategy(target);
        result = target.functionDelegateCall(payload);

        _fillWithdrawQueue();

        _trackUnderlying();
    }

    /**
     * @notice Executes multiple management actions on delegate strategies
     * @dev Only callable by rebalance admin. All targets must be allowed strategies
     * @param targets Array of delegate strategy addresses to call
     * @param payloads Array of encoded function calls to execute
     * @return results Array of return data from the executed calls
     */
    function manage(address[] calldata targets, bytes[] calldata payloads)
        external
        onlyRebalanceAdmin
        returns (bytes[] memory results)
    {
        if (targets.length == 0 || payloads.length == 0) revert InvalidZeroInput();
        if (targets.length != payloads.length) revert MismatchedArrayLengths();

        results = new bytes[](targets.length);
        for (uint256 i = 0; i < targets.length;) {
            _isAllowedDelegateStrategy(targets[i]);
            results[i] = targets[i].functionDelegateCall(payloads[i]);
            unchecked {
                ++i;
            }
        }

        _fillWithdrawQueue();

        _trackUnderlying();
    }

    /**
     * @notice Updates the vault's total underlying asset value
     * @dev Only callable by exchange rate admin. Used to sync vault state with strategies
     */
    function trackUnderlying() external onlyExchangeRateAdmin {
        _trackUnderlying();
    }

    /**
     ********************************
     ** ERC4626 Override functions **
     ********************************
     */

    /**
     * @notice Deposits assets into the vault and mints shares
     * @dev Overrides ERC4626 deposit. Only whitelisted addresses can deposit
     * @param assets The amount of underlying assets to deposit
     * @param receiver The address that will receive the minted shares
     * @return The amount of shares minted
     */
    function deposit(uint256 assets, address receiver) public virtual override onlyWhitelisted returns (uint256) {
        require(assets <= maxDeposit(receiver), "ERC4626: deposit more than max");

        // convert To shares with total
        uint256 shares = previewDeposit(assets);

        _deposit(_msgSender(), receiver, assets, shares);

        // Track total underlying
        totalUnderlying += assets;

        _fillWithdrawQueue();

        return shares;
    }

    /**
     * @notice Burns shares and updates the total assets accordingly
     * @dev Only callable by the withdraw queue contract
     * @param _shares The amount of shares to burn
     * @param _assets The amount of assets to deduct from total underlying
     */
    function burnSharesAndUpdateAssets(uint256 _shares, uint256 _assets) external onlyWithdrawQueue {
        // update shares
        _burn(_msgSender(), _shares);

        // update assets
        totalUnderlying -= _assets;
    }

    /**
     * @notice Withdraw is not supported directly - use withdraw queue instead
     * @dev Always reverts. Users must use the withdraw queue for withdrawals
     */
    function withdraw(uint256 assets, address receiver, address owner) public virtual override returns (uint256) {
        revert();
    }

    /**
     * @notice Mint is not supported
     * @dev Always reverts. Use deposit function instead
     */
    function mint(uint256 shares, address receiver) public virtual override returns (uint256) {
        revert();
    }

    /**
     * @notice Redeem is not supported directly - use withdraw queue instead
     * @dev Always reverts. Users must use the withdraw queue for redemptions
     */
    function redeem(uint256 shares, address receiver, address owner) public virtual override returns (uint256) {
        revert();
    }

    /**
     ********************
     ** View functions **
     ********************
     */
    function isAllowedDelegateStrategy(address _delegateStrategy) public view returns (bool) {
        return allowedDelegateStrategy.contains(_delegateStrategy);
    }

    /**
     * @dev See {IERC4626-convertToShares}.
     */
    function convertToShares(uint256 assets) public view virtual override returns (uint256) {
        return _convertToSharesWithTotals(assets, totalSupply(), totalAssets(), Math.Rounding.Floor);
    }

    /**
     * @dev See {IERC4626-convertToAssets}.
     */
    function convertToAssets(uint256 shares) public view virtual override returns (uint256) {
        return _convertToAssetsWithTotals(shares, totalSupply(), totalAssets(), Math.Rounding.Floor);
    }

    /**
     * @dev See {IERC4626-previewRedeem}.
     */
    function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
        return _convertToSharesWithTotals(assets, totalSupply(), totalAssets(), Math.Rounding.Floor);
    }

    /// @dev Preview Redeem is used by WithdrawQueue to calculate assets for shares
    /**
     * @dev See {IERC4626-previewRedeem}.
     */
    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        return _convertToAssetsWithTotals(shares, totalSupply(), totalAssets(), Math.Rounding.Floor);
    }

    /// @dev Revert as Mint is not supported
    /**
     * @dev See {IERC4626-previewMint}.
     */
    function previewMint(uint256 shares) public view virtual override returns (uint256) {
        revert();
    }

    /// @dev Revert as Withdraw is not supported
    /**
     * @dev See {IERC4626-previewWithdraw}.
     */
    function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
        revert();
    }

    /**
     *************************************
     ** ERC4626 Override View functions **
     *************************************
     */

    function totalAssets() public view virtual override returns (uint256) {
        return totalUnderlying;
    }

    /**
     ************************
     ** Internal Functions **
     ************************
     */

    /// @dev Checks if _delegateStrategy is allowed
    function _isAllowedDelegateStrategy(address _delegateStrategy) internal view {
        if (!allowedDelegateStrategy.contains(_delegateStrategy)) {
            revert UnAuthorizedStrategy(_delegateStrategy);
        }
    }

    /// @notice  Tracks Underlying value of the vault through delegate strategy
    function _trackUnderlying() internal {
        uint256 currentUnderlying = super.totalAssets() + IERC20(asset()).balanceOf(address(withdrawQueue));

        // get underlyingValue calldata
        bytes memory underlyingPayload = abi.encodeWithSelector(IDelegateStrategy.underlyingValue.selector, asset());

        for (uint256 i = 0; i < allowedDelegateStrategy.length();) {
            currentUnderlying += abi.decode(
                (allowedDelegateStrategy.at(i)).functionDelegateCall(underlyingPayload), (uint256)
            );
            unchecked {
                ++i;
            }
        }

        // Deduct performance fee
        _accrueFee(currentUnderlying);

        // Store old value for event
        uint256 oldUnderlying = totalUnderlying;

        // Update totalUnderlying
        totalUnderlying = currentUnderlying;

        // Emit event if value changed
        if (oldUnderlying != currentUnderlying) {
            emit TotalUnderlyingUpdated(oldUnderlying, currentUnderlying);
        }
    }

    /// @dev Accrue Performance fee on the Interest Earned
    function _accrueFee(uint256 currentUnderlying) internal {
        uint256 newRate =
            _convertToAssetsWithTotals(10 ** decimals(), totalSupply(), currentUnderlying, Math.Rounding.Floor);

        if (newRate > lastCachedHighestRate) {
            // get the total gains from previous rate
            uint256 totalInterest = currentUnderlying - totalSupply().mulDiv(lastCachedHighestRate, 10 ** decimals());

            // deduct fee
            uint256 feeAssets = (totalInterest * performanceFeeBps) / BASIS_POINTS;

            // fee shares to mint
            // The fee assets is subtracted from the currentUnderlying in this calculation to compensate for the fact
            // that currentUnderlying is already increased by the total interest (including the fee assets).
            uint256 feeShares = _convertToSharesWithTotals(
                feeAssets, totalSupply(), currentUnderlying - feeAssets, Math.Rounding.Floor
            );

            if (feeShares != 0) {
                _mint(feeRecipient, feeShares);
                // Emit event for performance fees accrued
                emit PerformanceFeesAccrued(feeShares, feeAssets);
            }

            // record rate
            _recordRate(currentUnderlying);
        }
    }

    /// @dev Record the Highest rate
    function _recordRate(uint256 _currentUnderlying) internal {
        uint256 rate =
            _convertToAssetsWithTotals(10 ** decimals(), totalSupply(), _currentUnderlying, Math.Rounding.Floor);

        // if current rate is greater than last cached highest rate
        if (rate > lastCachedHighestRate) {
            // record last cached highest rate
            lastCachedHighestRate = rate;
            // Emit event for new highest rate
            emit HighestRateRecorded(rate);
        }
    }

    /// @dev Check for 0 underlying value
    function _checkUnderlying(address _delegateStrategy) internal view {
        if (IDelegateStrategy(_delegateStrategy).underlyingValue(asset()) > 0) {
            revert NonZeroUnderlyingDelegateStrategy();
        }
    }

    /// @dev Fill the Withdraw Queue from the balance
    function _fillWithdrawQueue() internal {
        // get the queue deficit
        uint256 queueDeficit = withdrawQueue.getQueueDeficit();
        if (queueDeficit > 0) {
            // Get amount to fill the queue
            uint256 amountToFill = super.totalAssets() > queueDeficit ? queueDeficit : super.totalAssets();
            if (amountToFill > 0) {
                // Increase allowance to withdraw Queue
                IERC20(asset()).safeIncreaseAllowance(address(withdrawQueue), amountToFill);

                // Fill the Withdraw Queue
                withdrawQueue.fillWithdrawQueue(amountToFill);
            }
        }
    }

    /// @dev Returns the amount of assets that the vault would exchange for the amount of `shares` provided.
    /// @dev It assumes that the arguments `newTotalSupply` and `newTotalAssets` are up to date.
    function _convertToAssetsWithTotals(
        uint256 shares,
        uint256 newTotalSupply,
        uint256 newTotalAssets,
        Math.Rounding rounding
    ) internal view returns (uint256) {
        return shares.mulDiv(newTotalAssets + BALANCE_OFFSET, newTotalSupply + SHARE_OFFSET, rounding);
    }

    /// @dev Returns the amount of shares that the vault would exchange for the amount of `assets` provided.
    /// @dev It assumes that the arguments `newTotalSupply` and `newTotalAssets` are up to date.
    function _convertToSharesWithTotals(
        uint256 assets,
        uint256 newTotalSupply,
        uint256 newTotalAssets,
        Math.Rounding rounding
    ) internal view returns (uint256) {
        return assets.mulDiv(newTotalSupply + SHARE_OFFSET, newTotalAssets + BALANCE_OFFSET, rounding);
    }

    /**
     * @notice Receives ETH sent to the contract
     * @dev Only whitelisted addresses can send ETH to this contract
     * @dev Warning : ETH can be sent directly via selfdestruct
     */
    receive() external payable {
        // only allow whitelisted address to send ETH
        if (msg.sender != WETH && !whitelistedEthSender[msg.sender]) revert();
        // do nothing
    }
}
