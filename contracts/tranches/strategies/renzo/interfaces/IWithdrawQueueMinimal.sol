/// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 * @title IWithdrawQueueMinimal
 * @dev Minimal interface for interacting with Renzo's WithdrawQueue
 */
interface IWithdrawQueueMinimal {
    struct WithdrawRequest {
        uint256 withdrawRequestID;
        uint256 amountToRedeem;
        uint256 sharesLocked;
        uint256 createdAt;
        uint256 fillAt;
    }

    function withdraw(uint256 _shares) external;
    function claim(uint256 withdrawRequestIndex, address user) external;
    function coolDownPeriod() external view returns (uint256);
    function withdrawRequests(address user, uint256 index) external view returns (
        uint256 withdrawRequestID,
        uint256 amountToRedeem,
        uint256 sharesLocked,
        uint256 createdAt,
        uint256 fillAt
    );
    function totalUserWithdrawRequests(address user) external view returns (uint256);
}

