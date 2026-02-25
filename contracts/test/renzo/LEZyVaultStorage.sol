// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IWithdrawQueue } from "./interfaces/IWithdrawQueue.sol";
import { IRoleManager } from "./interfaces/IRoleManager.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title LEZyVaultStorageV1
 * @author Renzo Protocol
 * @notice Storage contract for LEZyVault implementation
 * @dev This abstract contract defines the storage layout for the LEZyVault upgradeable contract
 */
abstract contract LEZyVaultStorageV1 {
    /// @dev Tracks allowed DelegateStrategies
    EnumerableSet.AddressSet internal allowedDelegateStrategy;

    /// @dev Tracks the roleManager contract
    IRoleManager public roleManager;

    /// @dev Tracks total underlying value
    uint256 public totalUnderlying;

    /// @dev Tracks WithdrawQueue contract
    IWithdrawQueue public withdrawQueue;

    /// @dev track deposit whitelisted status
    bool public depositWhitelistEnabled;

    /// @dev tracks whitelisted addresses for deposits - requires whitelistEnabled to be true
    mapping(address => bool) public whitelist;

    /// @dev Track High watermark exchange rate
    uint256 public lastCachedHighestRate;

    /// @dev Track performance fee BPS
    uint256 public performanceFeeBps;

    /// @dev Tracks fee Recipient
    address public feeRecipient;

    /// @dev Tracks whitelisted addresses to allow sending ETH to vault
    mapping(address => bool) public whitelistedEthSender;
}