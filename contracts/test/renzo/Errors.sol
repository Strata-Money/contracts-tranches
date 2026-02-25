// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 * @title Errors
 * @author Renzo Protocol
 * @notice This contract defines custom errors used throughout the LiquidVaults protocol
 * @dev All errors are defined as custom errors for gas efficiency
 */

/// @dev Error when Zero Input value
error InvalidZeroInput();

/// @dev Error when caller is not Rebalance admin
error NotRebalanceAdmin();

/// @dev Error when caller is not Exchange rate admin
error NotExchangeRateAdmin();

/// @dev Error when array lengths do not match
error MismatchedArrayLengths();

/// @dev Error when admin tries to execute Non whitelisted strategy
error UnAuthorizedStrategy(address strategy);

/// @dev Error when owner tries to remove non zero underlying delegate strategy
error NonZeroUnderlyingDelegateStrategy();

/// @dev Error when Withdrawal is not claimable
error WithdrawalNotClaimable();

/// @dev Error when caller try to claim invalidWithdrawIndex
error InvalidWithdrawIndex();

/// @dev Error when called is not vault
error NotUnderlyingVault();

/// @dev Error when caller is not Withdraw Queue
error NotWithdrawQueue();

/// @dev Error when caller tries to create already existing vault
error VaultAlreadyCreated();

/// @dev Error when caller is not whitelisted
error NotWhitelisted();

/// @dev Error when fee bps out of range
error InvalidFeeBps();

/// @dev Error when caller does not have pauser role
error NotPauser();

/// @dev Error when eulerswap param is invalid
error InvalidEquilibriumReserve();

/// @dev Error when pool is already installed for the euler account
error PoolAlreadyInstalled();

/// @dev Error when unexpected asset address is passed in
error InvalidAsset();

/// @dev Error when no pool is installed for the euler account when it is expected
error NoPoolInstalled();

/// @dev Error when decimals are invalid
error InvalidDecimals();

/// @dev Error when caller is not owner
error NotOwner();

/// @dev Error when active withdrawal is in progress
error ActiveWithdrawalInProgress();

/// @dev Error when no active withdrawal is in progress
error NoActiveWithdrawalInProgress();

/// @dev Error when active deposit is in progress
error ActiveDepositInProgress();

/// @dev Error when expected amount is invalid
error InvalidExpectedAmount();

/// @dev Error when no active deposit is in progress
error NoActiveDepositInProgress();

/// @dev Error when Oracle Price is invalid
error InvalidOraclePrice();

/// @dev Error when superstate deposit address is already set
error SuperstateAddressAlreadySet();

/// @dev Error when current tick has changed
error InvalidTick();

/// @dev Error when debt value is greater than collateral value
error InvalidDebtValue();

/// @dev Error when referral code is invalid
error InvalidReferralCode();

/// @dev Error when interest rate mode is invalid
error InvalidInterestRateMode();