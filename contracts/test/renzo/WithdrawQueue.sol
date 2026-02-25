// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "./WithdrawQueueStorage.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "./Errors.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract WithdrawQueue is
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    WithdrawQueueStorageV1
{
    using SafeERC20 for IERC20;

    modifier onlyVault() {
        if (_msgSender() != address(vault)) revert NotUnderlyingVault();
        _;
    }

    event WithdrawRequestCreated(
        address indexed withdrawer,
        WithdrawRequest _withdrawRequest,
        uint256 withdrawRequestIndex
    );
    event WithdrawRequestClaimed(WithdrawRequest _withdrawRequest);
    event WithdrawQueueFilled(uint256 assetAmount);
    event CoolDownPeriodUpdated(uint256 oldCoolDownPeriod, uint256 newCoolDownPeriod);
    event WithdrawQueueInitialized(address indexed vault, uint256 coolDownPeriod);
    event QueuedWithdrawToFillUpdated(uint256 oldValue, uint256 newValue);
    event QueuedWithdrawFilledUpdated(uint256 oldValue, uint256 newValue);

    modifier onlyPauser() {
        if (!vault.roleManager().isPauser(_msgSender())) revert NotPauser();
        _;
    }

    /// @dev Prevents implementation contract from being initialized.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        address _vault,
        uint256 _cooldownPeriod
    ) external initializer {
        if (_owner == address(0) || _vault == address(0) || _cooldownPeriod == 0)
            revert InvalidZeroInput();
        vault = ILEZyVault(_vault);
        coolDownPeriod = _cooldownPeriod;
        _transferOwnership(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();

        // Emit initialization event
        emit WithdrawQueueInitialized(_vault, _cooldownPeriod);
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
     * @notice Updates the coolDownPeriod for withdrawal requests
     * @dev    It is a permissioned call (onlyWithdrawQueueAdmin)
     * @param   _newCoolDownPeriod  new coolDownPeriod in seconds
     */
    function updateCoolDownPeriod(uint256 _newCoolDownPeriod) external onlyOwner {
        if (_newCoolDownPeriod == 0) revert InvalidZeroInput();
        emit CoolDownPeriodUpdated(coolDownPeriod, _newCoolDownPeriod);
        coolDownPeriod = _newCoolDownPeriod;
    }

    /**
     * @notice  Creates a Withdraw request for the user
     * @param   _shares  Shares to withdraw
     */
    function withdraw(uint256 _shares) external nonReentrant whenNotPaused {
        // check if shares more than max redeem allowed
        require(_shares <= vault.maxRedeem(_msgSender()), "ERC4626: redeem more than max");

        // check for 0 value
        if (_shares == 0) revert InvalidZeroInput();

        // transfer vault shares to this address
        IERC20(address(vault)).safeTransferFrom(_msgSender(), address(this), _shares);

        // Calculate amount to Redeem
        uint256 amountToRedeem = vault.previewRedeem(_shares);

        // Store old value for event
        uint256 oldQueuedWithdrawToFill = withdrawQueue.queuedWithdrawToFill;

        // increase the queuedWithdrawalToFill
        withdrawQueue.queuedWithdrawToFill += amountToRedeem;

        // Emit event for queue update
        emit QueuedWithdrawToFillUpdated(
            oldQueuedWithdrawToFill,
            withdrawQueue.queuedWithdrawToFill
        );

        // increment the withdrawRequestNonce
        withdrawRequestNonce++;

        // Create Withdraw Request
        WithdrawRequest memory withdrawRequest = WithdrawRequest(
            withdrawRequestNonce,
            amountToRedeem,
            _shares,
            block.timestamp,
            withdrawQueue.queuedWithdrawToFill
        );

        // add withdraw request for msg.sender
        withdrawRequests[_msgSender()].push(withdrawRequest);

        // emit the event
        emit WithdrawRequestCreated(
            _msgSender(),
            withdrawRequest,
            withdrawRequests[_msgSender()].length - 1
        );
    }

    /**
     * @notice  Claim user withdraw request for underlying
     * @param   withdrawRequestIndex  Index of the withdraw request in user withdraw requests
     * @param   user  address of user to claim the withdraw request for
     */
    function claim(uint256 withdrawRequestIndex, address user) external nonReentrant whenNotPaused {
        // check if provided withdrawRequest Index is valid
        if (withdrawRequestIndex >= withdrawRequests[user].length) revert InvalidWithdrawIndex();

        WithdrawRequest memory _withdrawRequest = withdrawRequests[user][withdrawRequestIndex];

        // check if withdraw request is filled completely and cooldown is passed
        if (
            _withdrawRequest.fillAt > withdrawQueue.queuedWithdrawFilled ||
            (block.timestamp - _withdrawRequest.createdAt) < coolDownPeriod
        ) revert WithdrawalNotClaimable();
        uint256 claimAmountToRedeem = vault.previewRedeem(_withdrawRequest.sharesLocked);

        if (claimAmountToRedeem < _withdrawRequest.amountToRedeem) {
            // Increase the Queue filled by the delta
            withdrawQueue.queuedWithdrawFilled += (_withdrawRequest.amountToRedeem -
                claimAmountToRedeem);
            // update amount to redeem
            _withdrawRequest.amountToRedeem = claimAmountToRedeem;
        }

        // delete the withdraw request
        withdrawRequests[user][withdrawRequestIndex] = withdrawRequests[user][
            withdrawRequests[user].length - 1
        ];
        withdrawRequests[user].pop();

        // burn vault shares
        vault.burnSharesAndUpdateAssets(
            _withdrawRequest.sharesLocked,
            _withdrawRequest.amountToRedeem
        );

        // send selected redeem asset to user
        IERC20(vault.asset()).safeTransfer(user, _withdrawRequest.amountToRedeem);

        // emit the event
        emit WithdrawRequestClaimed(_withdrawRequest);
    }

    /**
     * @notice  Fills the withdraw queue of the vault
     * @dev     Permissioned call (onlyVault)
     * @param   _assetAmount  amount of underlying asset to fill the queue deficit
     */
    function fillWithdrawQueue(uint256 _assetAmount) external nonReentrant onlyVault {
        if (_assetAmount == 0) revert InvalidZeroInput();

        // Transfer asset amount from msg.sender
        IERC20(vault.asset()).safeTransferFrom(msg.sender, address(this), _assetAmount);

        // Store old value for event
        uint256 oldQueuedWithdrawFilled = withdrawQueue.queuedWithdrawFilled;

        // track queue filled
        withdrawQueue.queuedWithdrawFilled += _assetAmount;

        // Emit event for filled update
        emit QueuedWithdrawFilledUpdated(
            oldQueuedWithdrawFilled,
            withdrawQueue.queuedWithdrawFilled
        );

        emit WithdrawQueueFilled(_assetAmount);
    }

    /**
     ********************
     ** View functions **
     ********************
     */

    /**
     * @notice  To get the current queue deficit for the vault
     * @return  uint256  Current queue deficit
     */
    function getQueueDeficit() public view returns (uint256) {
        return withdrawQueue.queuedWithdrawToFill - withdrawQueue.queuedWithdrawFilled;
    }

    function totalUserWithdrawRequests(address _user) public view returns (uint256) {
        return withdrawRequests[_user].length;
    }
}