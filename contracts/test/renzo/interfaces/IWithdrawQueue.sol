// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IWithdrawQueue {
    function withdraw(uint256 _shares, address user) external;

    function fillWithdrawQueue(uint256 _assetAmount) external;

    function getQueueDeficit() external view returns (uint256);

    function initialize(address _owner, address _vault, uint256 _cooldownPeriod) external;

    function setWhiteListed(address[] calldata _accounts, bool[] calldata _accountsStatus) external;
}