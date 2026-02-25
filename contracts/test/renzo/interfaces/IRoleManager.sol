// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 * @title IRoleManager
 * @author Renzo Protocol
 * @notice Interface for the RoleManager contract that handles access control
 * @dev This interface defines functions to check various role permissions
 */
interface IRoleManager {
    /**
     * @notice Checks if an address has the REBALANCE_ADMIN role
     * @param potentialAddress The address to check
     * @return bool True if the address has the REBALANCE_ADMIN role, false otherwise
     */
    function isRebalanceAdmin(address potentialAddress) external view returns (bool);

    /**
     * @notice Checks if an address has the PAUSER role
     * @param potentialAddress The address to check
     * @return bool True if the address has the PAUSER role, false otherwise
     */
    function isPauser(address potentialAddress) external view returns (bool);

    /**
     * @notice Checks if an address has the EXCHANGE_RATE_ADMIN role
     * @param potentialAddress The address to check
     * @return bool True if the address has the EXCHANGE_RATE_ADMIN role, false otherwise
     */
    function isExchangeRateAdmin(address potentialAddress) external view returns (bool);
}