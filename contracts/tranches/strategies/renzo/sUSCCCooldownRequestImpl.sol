// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUnstakeHandler} from "../../interfaces/cooldown/IUnstakeHandler.sol";
import {IWithdrawQueueMinimal} from "./interfaces/IWithdrawQueueMinimal.sol";
import {ILEZyVaultMinimal} from "./interfaces/ILEZyVaultMinimal.sol";

/**
 * @title sUSCCCooldownRequestImpl
 * @dev Implementation of the unstake process for ezUSCC (LEZyVault) tokens with cooldown period.
 * This contract is designed to be used within the UnstakeCooldown contract.
 * It handles the cooldown request, finalization, and asset transfer for unstaking ezUSCC tokens
 * through Renzo's WithdrawQueue mechanism.
 */
contract sUSCCCooldownRequestImpl is IUnstakeHandler, Initializable {
    using SafeERC20 for IERC20;

    IERC4626 public immutable ezUSCC;

    IERC20 public immutable USDC;
    address public handler;
    address public user;
    address public receiver;
    uint256 public requestedAt;
    bool public pending;

    uint256 public firstWithdrawRequestIndex;
    uint256 public withdrawRequestIndex;

    constructor(IERC4626 ezUSCC_) {
        _disableInitializers();
        ezUSCC = ezUSCC_;
        USDC = IERC20(ezUSCC_.asset());
    }

    function initialize(address handler_, address user_) public virtual initializer {
        user = user_;
        handler = handler_;
    }

    function request() external returns (uint256 unlockAt) {
        return request(user);
    }

    function request(address receiver_) public returns (uint256 unlockAt) {
        require(msg.sender == handler, "NotAuthorized");

        uint256 shares = IERC20(address(ezUSCC)).balanceOf(address(this));
        IWithdrawQueueMinimal withdrawQueue = _getWithdrawQueue();

        // Approve shares to WithdrawQueue
        IERC20(address(ezUSCC)).forceApprove(address(withdrawQueue), shares);

        // Get current request count before creating new request
        uint256 requestCountBefore = withdrawQueue.totalUserWithdrawRequests(address(this));

        // Create withdraw request in the WithdrawQueue
        withdrawQueue.withdraw(shares);

        // Track the index range: first index is set only on the first call of a lifecycle
        if (!pending) {
            firstWithdrawRequestIndex = requestCountBefore;
        }
        withdrawRequestIndex = requestCountBefore;
        requestedAt = block.timestamp;
        receiver = receiver_;
        pending = true;

        // Return when the request can be claimed
        return block.timestamp + withdrawQueue.coolDownPeriod();
    }

    /**
     * @notice Completes the unstake request and transfers USDC to the receiver
     * @dev Claims from WithdrawQueue and forwards USDC to receiver
     * @return amount The amount of USDC transferred to receiver
     */
    function finalize() external returns (uint256 amount) {
        require(msg.sender == handler, "NotAuthorized");
        require(pending, "No pending request");

        IWithdrawQueueMinimal withdrawQueue = _getWithdrawQueue();

        // Claim all requests in descending order to preserve indices during swap-and-pop
        for (uint256 i = withdrawRequestIndex; ; ) {
            withdrawQueue.claim(i, address(this));
            if (i == firstWithdrawRequestIndex) break;
            unchecked { i--; }
        }

        amount = USDC.balanceOf(address(this));

        if (amount > 0) {
            USDC.safeTransfer(receiver, amount);
        }

        pending = false;
        return amount;
    }

    /**
     * @notice Returns the pending amount to be redeemed in USDC
     * @return amount The amount of USDC pending
     */
    function getPendingAmount() external view returns (uint256 amount) {
        if (!pending) {
            return 0;
        }
        IWithdrawQueueMinimal withdrawQueue = _getWithdrawQueue();
        for (uint256 i = firstWithdrawRequestIndex; i <= withdrawRequestIndex; ) {
            (, uint256 amountToRedeem,,,) = withdrawQueue.withdrawRequests(address(this), i);
            amount += amountToRedeem;
            unchecked { i++; }
        }
    }

    /**
     * @notice Checks if cooldown is active in the WithdrawQueue
     * @return True if cooldown period is greater than 0
     */
    function isCooldownActive() public view returns (bool) {
        IWithdrawQueueMinimal withdrawQueue = _getWithdrawQueue();
        return withdrawQueue.coolDownPeriod() > 0;
    }

    function _getWithdrawQueue() internal view returns (IWithdrawQueueMinimal) {
        address queueAddress = ILEZyVaultMinimal(address(ezUSCC)).withdrawQueue();
        return IWithdrawQueueMinimal(queueAddress);
    }
}
