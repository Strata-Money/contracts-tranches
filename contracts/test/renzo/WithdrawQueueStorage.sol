// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ILEZyVault} from "./interfaces/ILEZyVault.sol";

abstract contract WithdrawQueueStorageV1 {
    struct WithdrawQueue {
        uint256 queuedWithdrawToFill;
        uint256 queuedWithdrawFilled;
    }

    struct WithdrawRequest {
        uint256 withdrawRequestID;
        uint256 amountToRedeem;
        uint256 sharesLocked;
        uint256 createdAt;
        uint256 fillAt;
    }

    /// @dev Tracks the vault of the withdraw queue
    ILEZyVault public vault;

    /// @dev Tracks the withdraw queue state
    WithdrawQueue public withdrawQueue;

    /// @dev nonce for tracking withdraw requests, This only increments (doesn't decrement)
    uint256 public withdrawRequestNonce;

    /// @dev mapping of withdraw requests array, indexed by user address
    mapping(address => WithdrawRequest[]) public withdrawRequests;

    /// @dev cooldown period for user to claim their withdrawal
    uint256 public coolDownPeriod;
}
