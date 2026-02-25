// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IsUSCC
 * @notice Interface for the sUSCCStrategy contract exposing vesting state
 */
interface IsUSCC {
    /// @notice Returns the underlying ezUSCC vault
    function ezUSCC1() external view returns (IERC4626);

    /// @notice Returns the vesting period duration (24 hours)
    function VESTING_PERIOD() external view returns (uint256);

    /// @notice Returns the timestamp when the current vesting period started
    function lastVestingTimestamp() external view returns (uint256);

    /// @notice Returns the amount being vested in the current period
    function vestingAmount() external view returns (uint256);

    /// @notice Returns the raw total assets at the last vesting checkpoint
    function lastTotalAssets() external view returns (uint256);

    /// @notice Returns the amount of assets that are still unvested
    function getUnvestedAmount() external view returns (uint256);

    /// @notice Returns the total vested assets managed by this strategy
    function totalAssets() external view returns (uint256);
}
