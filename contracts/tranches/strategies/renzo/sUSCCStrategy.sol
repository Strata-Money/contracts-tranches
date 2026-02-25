// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IErrors} from "../../interfaces/IErrors.sol";
import {IStrataCDO} from "../../interfaces/IStrataCDO.sol";
import {IERC20Cooldown, IUnstakeCooldown} from "../../interfaces/cooldown/ICooldown.sol";
import {Strategy} from "../../Strategy.sol";

contract sUSCCStrategy is Strategy {
    IERC4626 public immutable ezUSCC1;
    IERC20 public immutable USDC;

    IERC20Cooldown public erc20Cooldown;
    IUnstakeCooldown public unstakeCooldown;

    /// @notice Vesting period duration (24 hours)
    uint256 public constant VESTING_PERIOD = 24 hours;

    /// @notice Timestamp when the current vesting period started
    uint256 public lastVestingTimestamp;

    /// @notice Amount being vested in the current period
    uint256 public vestingAmount;

    /// @notice Raw total assets at the last vesting checkpoint
    uint256 public lastTotalAssets;


    event VestingUpdated(uint256 vestingAmount, uint256 lastTotalAssets, uint256 timestamp);

    constructor(IERC4626 ezUSCC1_, IERC20 USDC_) {
        ezUSCC1 = ezUSCC1_;
        USDC = USDC_;
    }

    function initialize(
        address owner_,
        address acm_,
        IStrataCDO cdo_,
        IERC20Cooldown erc20Cooldown_,
        IUnstakeCooldown unstakeCooldown_
    ) public virtual initializer {
        AccessControlled_init(owner_, acm_);

        cdo = cdo_;
        erc20Cooldown = erc20Cooldown_;
        unstakeCooldown = unstakeCooldown_;

        SafeERC20.forceApprove(ezUSCC1, address(unstakeCooldown), type(uint256).max);
    }

    /**
     * @notice Processes asset deposits for the CDO contract.
     * @dev This method is called by the CDO contract to handle asset deposits.
     *      The only accepted token is USDC and it will be staked to receive ezUSCC shares.
     * @param token The address of the token being deposited
     * @param tokenAmount The amount of tokens being deposited
     * @param baseAssets The amount of base assets represented by the deposit
     * @param owner The address of the asset owner from whom to transfer tokens
     * @return The amount of base assets received after deposit
     */
    function deposit(
        address,
        /* tranche */
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address owner
    )
        external
        onlyCDO
        returns (uint256)
    {
        if (token != address(USDC)) {
            revert UnsupportedToken(token);
        }

        _updateVesting();

        SafeERC20.safeTransferFrom(IERC20(token), owner, address(this), tokenAmount);

        SafeERC20.forceApprove(USDC, address(ezUSCC1), tokenAmount);
        ezUSCC1.deposit(tokenAmount, address(this));

        // Update lastTotalAssets to include the new deposit so it is not
        // counted as yield gain in the next vesting period.
        lastTotalAssets = _getRawTotalAssets();

        return tokenAmount;
    }

    /**
     * @notice Processes asset withdrawals for the CDO contract.
     * @dev This method is called by the CDO contract to handle asset withdrawals.
     */
    function withdraw(
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address sender,
        address receiver
    ) external onlyCDO returns (uint256) {
        return withdrawInner(tranche, token, tokenAmount, baseAssets, sender, receiver, false);
    }

    function withdraw(
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address sender,
        address receiver,
        bool shouldSkipCooldown
    ) external onlyCDO returns (uint256) {
        return withdrawInner(tranche, token, tokenAmount, baseAssets, sender, receiver, shouldSkipCooldown);
    }

    function withdrawInner(
        address,
        address token,
        uint256,
        /* tokenAmount */
        uint256 baseAssets,
        address sender,
        address receiver,
        bool
    ) internal returns (uint256) {

        if (token != address(USDC)) {
            revert UnsupportedToken(token);
        }


        _updateVesting();

        uint256 shares = ezUSCC1.convertToShares(baseAssets);
        unstakeCooldown.transfer(ezUSCC1, sender, receiver, shares);

        // Update lastTotalAssets to reflect the withdrawal so it is not
        // counted as negative gain in the next vesting period.
        lastTotalAssets = _getRawTotalAssets();

        return baseAssets;
    }

    /**
     * @notice Allows the CDO to withdraw tokens from the strategy's reserve
     * @param token The address of the token to be withdrawn (USDC only)
     * @param tokenAmount The amount of tokens to be withdrawn
     * @param receiver The address that will receive the withdrawn tokens
     */
    function reduceReserve(address token, uint256 tokenAmount, address receiver) external onlyCDO {
        if (token != address(USDC)) {
            revert UnsupportedToken(token);
        }
        // tokenAmount is in USDC, convert to ezUSCC shares and trigger unstaking
        uint256 shares = ezUSCC1.convertToShares(tokenAmount);
        if (shares == 0) {
            revert ZeroAmount();
        }
        unstakeCooldown.transfer(ezUSCC1, receiver, receiver, shares);
    }

    /*//////////////////////////////////////////////////////////////
                            VESTING LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the raw total assets from the underlying vault
     * @dev This is the actual value without vesting adjustments
     */
    function _getRawTotalAssets() internal view returns (uint256) {
        uint256 shares = ezUSCC1.balanceOf(address(this));
        return ezUSCC1.previewRedeem(shares);
    }

    /**
     * @notice Returns the amount of assets that are still unvested
     * @dev Calculates based on time elapsed since last vesting timestamp
     */
    function getUnvestedAmount() public view returns (uint256) {
        if (lastVestingTimestamp == 0) {
            return 0;
        }
        uint256 timeSinceLastVesting = block.timestamp - lastVestingTimestamp;
        if (timeSinceLastVesting >= VESTING_PERIOD) {
            return 0;
        }
        uint256 deltaT;
        unchecked {
            deltaT = VESTING_PERIOD - timeSinceLastVesting;
        }
        return (deltaT * vestingAmount) / VESTING_PERIOD;
    }

    /**
     * @notice Updates the vesting state
     * @dev Called on every deposit/withdraw to ensure vesting is up to date
     *      - First call: initializes vesting without any vesting amount
     *      - During vesting period: no update
     *      - After vesting period: calculates new gain and starts new vesting
     */
    function _updateVesting() internal {
        uint256 rawAssets = _getRawTotalAssets();

        if (lastVestingTimestamp == 0) {
            // First deposit - initialize without vesting
            lastVestingTimestamp = block.timestamp;
            lastTotalAssets = rawAssets;
            vestingAmount = 0;
            emit VestingUpdated(0, rawAssets, block.timestamp);
            return;
        }

        uint256 timeSinceLastVesting = block.timestamp - lastVestingTimestamp;
        if (timeSinceLastVesting < VESTING_PERIOD) {
            // Still in current vesting window - no update needed
            return;
        }

        // Vesting period has elapsed, calculate new gain
        // Gain = rawAssets - lastTotalAssets (the increase due to exchange rate change)
        uint256 gain = rawAssets > lastTotalAssets ? rawAssets - lastTotalAssets : 0;

        // Start new vesting period
        vestingAmount = gain;
        lastVestingTimestamp = block.timestamp;
        lastTotalAssets = rawAssets;

        emit VestingUpdated(gain, rawAssets, block.timestamp);
    }

    /**
     * @notice Calculates the total assets managed by this strategy (vested only)
     * @dev Anchors on lastTotalAssets (the snapshot at the last vesting checkpoint) and
     *      adds only the portion of vestingAmount that has elapsed so far. This prevents
     *      gains that accrued in the underlying protocol since the last _updateVesting call
     *      from leaking into the reported value before they should be recognized.
     * @return baseAssets The total amount of vested USDC managed by this strategy
     */
    function totalAssets() external view returns (uint256 baseAssets) {
        return lastTotalAssets + vestingAmount - getUnvestedAmount();
    }

    /*//////////////////////////////////////////////////////////////
                            CONVERSION METHODS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Converts a given amount of supported tokens to their equivalent in USDC
     * @param token The address of the token to convert (USDC only)
     * @param tokenAmount The amount of tokens to convert
     * @return The equivalent amount in USDC
     */
    function convertToAssets(address token, uint256 tokenAmount, Math.Rounding)
        external
        view
        returns (uint256)
    {
        if (token != address(USDC)) {
            revert UnsupportedToken(token);
        }
        return tokenAmount;
    }

    /**
     * @notice Converts a given amount of base assets (USDC) to the equivalent amount of supported tokens
     * @param token The address of the token to convert to (USDC only)
     * @param baseAssets The amount of base assets (USDC) to convert
     * @return The equivalent amount in the requested token
     */
    function convertToTokens(address token, uint256 baseAssets, Math.Rounding)
        external
        view
        returns (uint256)
    {
        if (token != address(USDC)) {
            revert UnsupportedToken(token);
        }
        return baseAssets;
    }

    /**
     * @notice Returns an array of supported tokens: USDC only (deposits and withdrawals are in USDC)
     */
    function getSupportedTokens() external view returns (IERC20[] memory) {
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = USDC;
        return tokens;
    }
}
