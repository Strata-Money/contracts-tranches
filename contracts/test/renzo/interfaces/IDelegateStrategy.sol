// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 * @title IDelegateStrategy
 * @author Renzo Protocol
 * @notice Interface that all delegate strategies must implement
 * @dev Delegate strategies are external contracts that manage vault assets in various DeFi protocols
 */
interface IDelegateStrategy {
    /**
     * @notice Returns the value of assets managed by this strategy
     * @dev WARNING: Don't use balanceOf(this) to avoid double counting
     * @param _asset The asset address to query the value for
     * @return The total value of the specified asset managed by this strategy
     */
    function underlyingValue(address _asset) external view returns (uint256);
}