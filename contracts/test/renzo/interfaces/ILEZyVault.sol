// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IRoleManager } from "./IRoleManager.sol";

/**
 * @title ILEZyVault
 * @author Renzo Protocol
 * @notice Interface for the LEZyVault contract
 * @dev Extends ERC4626 standard with additional functionality for managing shares and assets
 */
interface ILEZyVault is IERC4626 {
    /**
     * @notice Burns shares and updates the total assets accordingly
     * @dev This function should only be called by authorized contracts (e.g., WithdrawQueue)
     * @param _shares The amount of shares to burn
     * @param _assets The amount of assets to deduct from total assets
     */
    function burnSharesAndUpdateAssets(uint256 _shares, uint256 _assets) external;

    /**
     * @notice Returns the RoleManager contract address
     * @return The RoleManager contract instance used for access control
     */
    function roleManager() external returns (IRoleManager);
}