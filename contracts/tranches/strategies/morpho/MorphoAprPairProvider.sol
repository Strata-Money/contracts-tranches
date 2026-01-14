// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IStrategyAprPairProvider} from "../../interfaces/IAprPairFeed.sol";
import {IMetaMorpho} from "./IMetaMorpho.sol";
import {Id, MarketParams, Market, IMorpho} from "@metamorpho/morpho-blue/interfaces/IMorpho.sol";
import {MathLib, WAD} from "@metamorpho/morpho-blue/libraries/MathLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SharesMathLib} from "@metamorpho/morpho-blue/libraries/SharesMathLib.sol";
import {MorphoLib} from "@metamorpho/morpho-blue/libraries/periphery/MorphoLib.sol";
import {MarketParamsLib} from "@metamorpho/morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "@metamorpho/morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {UtilsLib} from "@metamorpho/morpho-blue/libraries/UtilsLib.sol";
import {IIrm} from "@metamorpho/morpho-blue/interfaces/IIrm.sol";

/// @title MorphoAprPairProvider
/// @notice Provides APR pair data from MetaMorpho vaults
/// @dev APRs are returned in SD7x12 format (scaled by 1e12)
contract MorphoAprPairProvider is IStrategyAprPairProvider {
    using SharesMathLib for uint256;
    using MathLib for uint256;
    using Math for uint256;
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;
    using UtilsLib for uint256;

    /// @notice The Morpho Blue contract
    IMorpho public immutable morpho;

    /// @notice The MetaMorpho vault used as base APR source
    address public immutable baseVault;

    /// @notice The MetaMorpho vault used as target APR source (optional, can be same as baseVault)
    address public immutable targetVault;

    /// @notice Scale factor for converting from WAD (1e18) to SD7x12 (1e12)
    uint256 private constant WAD_TO_SD7X12 = 1e6;

    /// @param morphoAddress The Morpho Blue contract address
    /// @param baseVault_ The MetaMorpho vault for base APR
    /// @param targetVault_ The MetaMorpho vault for target APR (use address(0) for same as base)
    constructor(address morphoAddress, address baseVault_, address targetVault_) {
        require(morphoAddress != address(0), "Morpho address cannot be 0");
        require(baseVault_ != address(0), "Base vault address cannot be 0");

        morpho = IMorpho(morphoAddress);
        baseVault = baseVault_;
        targetVault = targetVault_ == address(0) ? baseVault_ : targetVault_;
    }

    /// @notice Returns the APR pair (target and base) from the configured vaults
    /// @return aprTarget The target APR scaled by 1e12
    /// @return aprBase The base APR scaled by 1e12
    /// @return timestamp The current block timestamp
    function getAprPair() external view returns (int64 aprTarget, int64 aprBase, uint64 timestamp) {
        timestamp = uint64(block.timestamp);
        aprTarget = getAPRtarget();
        aprBase = getAPRbase();
    }

    /// @notice Calculates the target APR from the target vault
    /// @return The target APR as int64, scaled by 1e12
    function getAPRtarget() public view returns (int64) {
        uint256 apyWad = supplyAPYVaultV1(targetVault);
        // Convert from WAD (1e18) to SD7x12 (1e12)
        uint256 apr = apyWad / WAD_TO_SD7X12;
        return int64(int256(apr));
    }

    /// @notice Calculates the base APR from the base vault
    /// @return The base APR as int64, scaled by 1e12
    function getAPRbase() public view returns (int64) {
        uint256 apyWad = supplyAPYVaultV1(baseVault);
        // Convert from WAD (1e18) to SD7x12 (1e12)
        uint256 apr = apyWad / WAD_TO_SD7X12;
        return int64(int256(apr));
    }

    /// @notice Returns the total assets supplied into a specific morpho blue market by a MetaMorpho `vault`.
    /// @param vault The address of the MetaMorpho vault.
    /// @param marketParams The morpho blue market.
    function vaultAssetsInMarket(address vault, MarketParams memory marketParams) public view returns (uint256 assets) {
        assets = morpho.expectedSupplyAssets(marketParams, vault);
    }

    /// @notice Returns the current APY of a Morpho Blue market.
    /// @param marketParams The morpho blue market parameters.
    /// @param market The morpho blue market state.
    function supplyAPYMarketV1(MarketParams memory marketParams, Market memory market)
        public
        view
        returns (uint256 supplyApy)
    {
        // Get the borrow rate
        uint256 borrowRate;
        if (marketParams.irm == address(0)) {
            return 0;
        } else {
            borrowRate = IIrm(marketParams.irm).borrowRateView(marketParams, market).wTaylorCompounded(365 days);
        }

        (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,) = morpho.expectedMarketBalances(marketParams);

        // Get the supply rate
        uint256 utilization = totalBorrowAssets == 0 ? 0 : totalBorrowAssets.wDivUp(totalSupplyAssets);
        supplyApy = borrowRate.wMulDown(1 ether - market.fee).wMulDown(utilization);
    }

    /// @notice Returns the current APY of a MetaMorpho vault.
    /// @dev It is computed as the sum of all APY of enabled markets weighted by the supply on these markets.
    /// @param vault The address of the MetaMorpho vault.
    function supplyAPYVaultV1(address vault) public view returns (uint256 avgSupplyApy) {
        uint256 ratio;
        uint256 queueLength = IMetaMorpho(vault).withdrawQueueLength();

        uint256 totalAmount = IMetaMorpho(vault).totalAssets();
        if (totalAmount == 0) return 0;

        for (uint256 i; i < queueLength; ++i) {
            Id idMarket = IMetaMorpho(vault).withdrawQueue(i);

            MarketParams memory marketParams = morpho.idToMarketParams(idMarket);
            Market memory market = morpho.market(idMarket);

            uint256 currentSupplyAPY = supplyAPYMarketV1(marketParams, market);
            uint256 vaultAsset = vaultAssetsInMarket(vault, marketParams);
            ratio += currentSupplyAPY.wMulDown(vaultAsset);
        }

        avgSupplyApy = ratio.mulDivDown(WAD - IMetaMorpho(vault).fee(), totalAmount);
    }
}
