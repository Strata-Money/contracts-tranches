// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IsUSCC} from "./interfaces/IsUSCC.sol";
import {IStrategyAprPairProvider} from "../../interfaces/IAprPairFeed.sol";

interface IsUSDS {
    // Sky Savings Rate
    function ssr() external view returns (uint256);
    // Timestamp
    function rho() external view returns (uint64);
}

/**
 * @title sUSCC AprPairProvider
 * @notice Fetches target APR from Sky Protocol and base APR from sUSCCStrategy's vesting state
 * @dev Similar to sUSDeAprPairProvider but calculates APR based on our strategy's vesting
 */
contract sUSCCAprPairProvider is IStrategyAprPairProvider {
    uint256 constant SECONDS_PER_YEAR = 31_536_000;

    IsUSDS public sUSDS;
    IsUSCC public sUSCC;

    constructor(IsUSDS _sUSDS, IsUSCC _sUSCC) {
        sUSDS = _sUSDS;
        sUSCC = _sUSCC;
    }

    function getAprPair() external view returns (int64 aprTarget, int64 aprBase, uint64 timestamp) {
        timestamp = uint64(block.timestamp);
        aprTarget = getAPRtarget();
        aprBase = getAPRbase();
    }

    /**
     * @notice Calculates the target APR based on the Sky Savings Rate (SSR)
     * @dev Fetches the current SSR (Growth Factor) from Sky's Protocol and converts it to an annual rate
     * @return The target APR as an int64, scaled by 1e12 (12 decimal places)
     */
    function getAPRtarget() public view returns (int64) {
        // growth per second
        uint256 ssr = sUSDS.ssr();
        uint256 ONE_in = 1e27;
        uint256 ONE_out = 1e12;
        if (ssr < ONE_in) {
            // not possible, but just in case: return 0 if APRssr is negative
            return 0;
        }
        uint256 apr = (ssr - ONE_in) * SECONDS_PER_YEAR * ONE_out / ONE_in;
        return int64(int256(apr));
    }

    /**
     * @notice Calculates the base APR for sUSCC based on the current vesting amount
     * @dev During the first 24 hours (before vesting starts) or after vesting completes, returns 0
     *      During vesting, calculates APR based on remaining unvested amount
     * @return The base APR as an int64, scaled by 1e12 (12 decimal places)
     */
    function getAPRbase() public view returns (int64) {
        uint256 t1 = block.timestamp;
        uint256 t0 = sUSCC.lastVestingTimestamp();

        // If vesting hasn't started yet, APR = 0
        if (t0 == 0) {
            return 0;
        }

        uint256 deltaT = t1 - t0;
        uint256 vestingPeriod = sUSCC.VESTING_PERIOD();

        // If vesting period has elapsed, APR = 0 until next vesting starts
        if (deltaT >= vestingPeriod) {
            return 0;
        }

        uint256 unvestedAmount = sUSCC.getUnvestedAmount();
        uint256 totalAssets = sUSCC.totalAssets();

        // Avoid division by zero
        if (totalAssets == 0) {
            return 0;
        }

        // APR = (unvested / remaining_time) * seconds_per_year / total_assets
        // unvested / remaining_time = rate of vesting per second
        // rate * seconds_per_year / total_assets = APR
        uint256 remainingTime = vestingPeriod - deltaT;
        uint256 apr = unvestedAmount * SECONDS_PER_YEAR * 1e18 / remainingTime / totalAssets;

        // Convert from 1e18 to 1e12 format
        return int64(int256(apr * 1e12 / 1e18));
    }
}
