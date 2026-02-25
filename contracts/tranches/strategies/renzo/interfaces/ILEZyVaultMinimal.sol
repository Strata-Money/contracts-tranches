/// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 * @title ILEZyVaultMinimal
 * @dev Minimal interface for getting WithdrawQueue from LEZyVault
 */
interface ILEZyVaultMinimal {
    function withdrawQueue() external view returns (address);
    function asset() external view returns (address);
}

