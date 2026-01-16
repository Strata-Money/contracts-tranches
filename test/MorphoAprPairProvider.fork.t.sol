// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {MorphoAprPairProvider} from "../contracts/tranches/strategies/morpho/MorphoAprPairProvider.sol";
import {IMetaMorpho} from "../contracts/tranches/strategies/morpho/IMetaMorpho.sol";
import {IStrategyAprPairProvider} from "../contracts/tranches/interfaces/IAprPairFeed.sol";

/// @title MorphoAprPairProvider Fork Test
/// @notice Fork test for MorphoAprPairProvider using Morpho Blue on Ethereum mainnet
/// @dev Uses the official Morpho contract at 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb
/// @dev Reference: https://docs.morpho.org/get-started/resources/addresses/
contract MorphoAprPairProviderForkTest is Test {
    // ============ Morpho Protocol Contracts on Mainnet ============
    /// @dev Morpho Blue core contract - https://docs.morpho.org/get-started/resources/addresses/
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    // ============ Well-known MetaMorpho Vaults on Mainnet ============
    /// @dev Steakhouse USDC vault (MetaMorpho)
    address constant STEAKHOUSE_USDC = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

    /// @dev Gauntlet USDC Prime vault (MetaMorpho)
    address constant GAUNTLET_USDC_PRIME = 0xdd0f28e19C1780eb6396170735D45153D261490d;

    /// @dev Gauntlet WETH Prime vault (MetaMorpho)
    address constant GAUNTLET_WETH_PRIME = 0x4881Ef0BF6d2365D3dd6499ccd7532bcdBCE0658;

    /// @dev Re7 WETH vault (MetaMorpho)
    address constant RE7_WETH = 0x78Fc2c2eD1A4cDb5402365934aE5648aDAd094d0;

    // ============ Test State ============
    MorphoAprPairProvider public aprProvider;
    uint256 public mainnetFork;

    function setUp() public {
        // Create mainnet fork
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        mainnetFork = vm.createFork(rpcUrl);
        vm.selectFork(mainnetFork);

        console2.log("Fork created at block:", block.number);
        console2.log("Using Morpho at:", MORPHO);
    }

    /// @notice Verify the fork is set up correctly
    function test_ForkSetup() public view {
        assertEq(vm.activeFork(), mainnetFork);

        // Verify Morpho contract exists on mainnet
        assertTrue(MORPHO.code.length > 0, "Morpho not deployed");
        assertTrue(STEAKHOUSE_USDC.code.length > 0, "Steakhouse USDC vault not deployed");

        console2.log("Morpho contract verified on mainnet");
    }

    /// @notice Test deployment with Steakhouse USDC vault
    function test_DeployWithSteakhouseUSDC() public {
        aprProvider = new MorphoAprPairProvider(MORPHO, STEAKHOUSE_USDC, address(0));

        assertEq(address(aprProvider.morpho()), MORPHO);
        assertEq(aprProvider.baseVault(), STEAKHOUSE_USDC);
        assertEq(aprProvider.targetVault(), STEAKHOUSE_USDC);

        console2.log("MorphoAprPairProvider deployed with:");
        console2.log("  Morpho:", address(aprProvider.morpho()));
        console2.log("  Base Vault:", aprProvider.baseVault());
        console2.log("  Target Vault:", aprProvider.targetVault());
    }

    /// @notice Test deployment with different target and base vaults
    function test_DeployWithDifferentVaults() public {
        aprProvider = new MorphoAprPairProvider(MORPHO, STEAKHOUSE_USDC, GAUNTLET_USDC_PRIME);

        assertEq(address(aprProvider.morpho()), MORPHO);
        assertEq(aprProvider.baseVault(), STEAKHOUSE_USDC);
        assertEq(aprProvider.targetVault(), GAUNTLET_USDC_PRIME);
    }

    /// @notice Test that deployment reverts with zero Morpho address
    function test_RevertOnZeroMorphoAddress() public {
        vm.expectRevert("Morpho address cannot be 0");
        new MorphoAprPairProvider(address(0), STEAKHOUSE_USDC, address(0));
    }

    /// @notice Test that deployment reverts with zero base vault address
    function test_RevertOnZeroBaseVaultAddress() public {
        vm.expectRevert("Base vault address cannot be 0");
        new MorphoAprPairProvider(MORPHO, address(0), address(0));
    }

    /// @notice Test getAprPair returns valid data from Steakhouse USDC
    function test_GetAprPairSteakhouseUSDC() public {
        aprProvider = new MorphoAprPairProvider(MORPHO, STEAKHOUSE_USDC, address(0));

        (int64 aprTarget, int64 aprBase, uint64 timestamp) = aprProvider.getAprPair();

        console2.log("=== Steakhouse USDC APR Data ===");
        console2.log("APR Target (scaled 1e12):", uint256(uint64(aprTarget)));
        console2.log("APR Base (scaled 1e12):", uint256(uint64(aprBase)));
        console2.log("Timestamp:", timestamp);

        // Convert to percentage for logging (divide by 1e10 to get percentage with 2 decimals)
        console2.log("APR Target (%):", uint256(uint64(aprTarget)) / 1e10);
        console2.log("APR Base (%):", uint256(uint64(aprBase)) / 1e10);

        // Verify timestamp is current
        assertEq(timestamp, uint64(block.timestamp));

        // Verify APRs are non-negative (they should be positive for an active vault)
        assertTrue(aprTarget >= 0, "Target APR should be non-negative");
        assertTrue(aprBase >= 0, "Base APR should be non-negative");

        // Verify APRs are reasonable (less than 100% = 1e12)
        assertTrue(uint64(aprTarget) < 1e12, "Target APR should be less than 100%");
        assertTrue(uint64(aprBase) < 1e12, "Base APR should be less than 100%");
    }

    /// @notice Test getAprPair with Gauntlet USDC Prime vault
    function test_GetAprPairGauntletUSDCPrime() public {
        aprProvider = new MorphoAprPairProvider(MORPHO, GAUNTLET_USDC_PRIME, address(0));

        (int64 aprTarget, int64 aprBase, uint64 timestamp) = aprProvider.getAprPair();

        console2.log("=== Gauntlet USDC Prime APR Data ===");
        console2.log("APR Target (scaled 1e12):", uint256(uint64(aprTarget)));
        console2.log("APR Base (scaled 1e12):", uint256(uint64(aprBase)));
        console2.log("APR Target (%):", uint256(uint64(aprTarget)) / 1e10);
        console2.log("APR Base (%):", uint256(uint64(aprBase)) / 1e10);

        assertEq(timestamp, uint64(block.timestamp));
        assertTrue(aprBase >= 0, "Base APR should be non-negative");
    }

    /// @notice Test getAprPair with WETH vault
    function test_GetAprPairGauntletWETH() public {
        aprProvider = new MorphoAprPairProvider(MORPHO, GAUNTLET_WETH_PRIME, address(0));

        (int64 aprTarget, int64 aprBase, uint64 timestamp) = aprProvider.getAprPair();

        console2.log("=== Gauntlet WETH Prime APR Data ===");
        console2.log("APR Base (scaled 1e12):", uint256(uint64(aprBase)));
        console2.log("APR Base (%):", uint256(uint64(aprBase)) / 1e10);

        assertEq(timestamp, uint64(block.timestamp));
        assertTrue(aprBase >= 0, "Base APR should be non-negative");
    }

    /// @notice Test individual APR getter functions
    function test_IndividualAPRGetters() public {
        aprProvider = new MorphoAprPairProvider(MORPHO, STEAKHOUSE_USDC, address(0));

        int64 aprTarget = aprProvider.getAPRtarget();
        int64 aprBase = aprProvider.getAPRbase();

        console2.log("=== Individual APR Getters ===");
        console2.log("getAPRtarget():", uint256(uint64(aprTarget)));
        console2.log("getAPRbase():", uint256(uint64(aprBase)));

        // Since target and base vault are the same, they should return the same value
        assertEq(aprTarget, aprBase, "Same vault should return same APR");
    }

    /// @notice Test supplyAPYVaultV1 directly
    function test_SupplyAPYVaultV1() public {
        aprProvider = new MorphoAprPairProvider(MORPHO, STEAKHOUSE_USDC, address(0));

        uint256 apyWad = aprProvider.supplyAPYVaultV1(STEAKHOUSE_USDC);

        console2.log("=== Supply APY (WAD) ===");
        console2.log("Steakhouse USDC APY (WAD):", apyWad);
        console2.log("Steakhouse USDC APY (%):", apyWad / 1e16); // Convert to percentage

        // Verify APY is reasonable (less than 100% = 1e18)
        assertTrue(apyWad < 1e18, "APY should be less than 100%");
    }

    /// @notice Test with different vaults to compare APRs
    function test_CompareVaultAPRs() public {
        console2.log("=== Comparing Vault APRs ===");

        // Test Steakhouse USDC
        MorphoAprPairProvider steakhouseProvider = new MorphoAprPairProvider(MORPHO, STEAKHOUSE_USDC, address(0));
        uint256 steakhouseApy = steakhouseProvider.supplyAPYVaultV1(STEAKHOUSE_USDC);
        console2.log("Steakhouse USDC APY (%):", steakhouseApy / 1e16);

        // Test Gauntlet USDC Prime
        MorphoAprPairProvider gauntletProvider = new MorphoAprPairProvider(MORPHO, GAUNTLET_USDC_PRIME, address(0));
        uint256 gauntletApy = gauntletProvider.supplyAPYVaultV1(GAUNTLET_USDC_PRIME);
        console2.log("Gauntlet USDC Prime APY (%):", gauntletApy / 1e16);

        // Test Gauntlet WETH Prime
        MorphoAprPairProvider wethProvider = new MorphoAprPairProvider(MORPHO, GAUNTLET_WETH_PRIME, address(0));
        uint256 wethApy = wethProvider.supplyAPYVaultV1(GAUNTLET_WETH_PRIME);
        console2.log("Gauntlet WETH Prime APY (%):", wethApy / 1e16);
    }

    /// @notice Test that the provider implements IStrategyAprPairProvider interface
    function test_ImplementsInterface() public {
        aprProvider = new MorphoAprPairProvider(MORPHO, STEAKHOUSE_USDC, address(0));

        // Call through the interface
        IStrategyAprPairProvider provider = IStrategyAprPairProvider(address(aprProvider));
        (int64 aprTarget, int64 aprBase, uint64 timestamp) = provider.getAprPair();

        console2.log("=== Interface Test ===");
        console2.log("Called through IStrategyAprPairProvider");
        console2.log("APR Target:", uint256(uint64(aprTarget)));
        console2.log("APR Base:", uint256(uint64(aprBase)));

        assertEq(timestamp, uint64(block.timestamp));
    }

    /// @notice Test vault with different target and base
    function test_DifferentTargetAndBase() public {
        // Use Steakhouse USDC as base and Gauntlet USDC Prime as target
        aprProvider = new MorphoAprPairProvider(MORPHO, STEAKHOUSE_USDC, GAUNTLET_USDC_PRIME);

        (int64 aprTarget, int64 aprBase, uint64 timestamp) = aprProvider.getAprPair();

        console2.log("=== Different Target and Base ===");
        console2.log("Base (Steakhouse USDC) APR:", uint256(uint64(aprBase)));
        console2.log("Target (Gauntlet USDC Prime) APR:", uint256(uint64(aprTarget)));
        console2.log("Base APR (%):", uint256(uint64(aprBase)) / 1e10);
        console2.log("Target APR (%):", uint256(uint64(aprTarget)) / 1e10);

        assertEq(timestamp, uint64(block.timestamp));

        // Target and base may be different since they come from different vaults
        // Both should be non-negative
        assertTrue(aprTarget >= 0, "Target APR should be non-negative");
        assertTrue(aprBase >= 0, "Base APR should be non-negative");
    }

    /// @notice Test querying market-level data
    function test_VaultAssetsInMarket() public {
        aprProvider = new MorphoAprPairProvider(MORPHO, STEAKHOUSE_USDC, address(0));

        // Get the first market from the withdraw queue
        uint256 queueLength = IMetaMorpho(STEAKHOUSE_USDC).withdrawQueueLength();
        console2.log("=== Vault Market Analysis ===");
        console2.log("Number of markets in withdraw queue:", queueLength);

        assertTrue(queueLength > 0, "Vault should have at least one market");
    }

    /// @notice Test that APR values are stable across multiple calls
    function test_APRStability() public {
        aprProvider = new MorphoAprPairProvider(MORPHO, STEAKHOUSE_USDC, address(0));

        (int64 aprTarget1, int64 aprBase1,) = aprProvider.getAprPair();
        (int64 aprTarget2, int64 aprBase2,) = aprProvider.getAprPair();

        // APRs should be identical when called in the same block
        assertEq(aprTarget1, aprTarget2, "APR target should be stable within same block");
        assertEq(aprBase1, aprBase2, "APR base should be stable within same block");
    }
}

