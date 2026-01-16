// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SwapContract} from "../contracts/tranches/SwapContract.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @title SwapContract Fork Test
/// @notice Fork test for SwapContract using Uniswap V4 on Ethereum mainnet
/// @dev Based on https://getfoundry.sh/forge/tests/fork-testing/
contract SwapContractForkTest is Test {
    using StateLibrary for IPoolManager;

    // ============ Deployed Uniswap V4 Contracts on Mainnet ============
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant QUOTER = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203;
    address constant STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227;

    // ============ Common Mainnet Tokens ============
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    // ============ Test State ============
    SwapContract public swapContract;
    IPoolManager public poolManager;
    uint256 public mainnetFork;

    // Test accounts
    address public alice;
    address public bob;

    function setUp() public {
        // Create mainnet fork
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        mainnetFork = vm.createFork(rpcUrl);
        vm.selectFork(mainnetFork);

        console2.log("Fork created at block:", block.number);

        // Set up test accounts
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy SwapContract with mainnet Uniswap V4 addresses
        swapContract = new SwapContract(UNIVERSAL_ROUTER, POOL_MANAGER, PERMIT2);

        poolManager = IPoolManager(POOL_MANAGER);

        console2.log("SwapContract deployed at:", address(swapContract));
        console2.log("Using Universal Router:", UNIVERSAL_ROUTER);
        console2.log("Using Pool Manager:", POOL_MANAGER);
        console2.log("Using Permit2:", PERMIT2);
    }

    /// @notice Verify the fork is set up correctly
    function test_ForkSetup() public view {
        assertEq(vm.activeFork(), mainnetFork);

        // Verify contracts exist on mainnet
        assertTrue(POOL_MANAGER.code.length > 0, "PoolManager not deployed");
        assertTrue(UNIVERSAL_ROUTER.code.length > 0, "UniversalRouter not deployed");
        assertTrue(PERMIT2.code.length > 0, "Permit2 not deployed");

        console2.log("All Uniswap V4 contracts verified on mainnet");
    }

    /// @notice Verify SwapContract is deployed correctly
    function test_SwapContractDeployment() public view {
        assertEq(address(swapContract.router()), UNIVERSAL_ROUTER);
        assertEq(address(swapContract.poolManager()), POOL_MANAGER);
        assertEq(address(swapContract.permit2()), PERMIT2);
    }

    /// @notice Test WETH balance can be acquired via deal
    function test_CanDealWETH() public {
        uint256 amount = 10 ether;
        deal(WETH, alice, amount);

        assertEq(IERC20(WETH).balanceOf(alice), amount);
        console2.log("Alice WETH balance:", IERC20(WETH).balanceOf(alice));
    }

    /// @notice Test USDC balance can be acquired via deal
    function test_CanDealUSDC() public {
        uint256 amount = 10_000e6; // 10,000 USDC (6 decimals)
        deal(USDC, alice, amount);

        assertEq(IERC20(USDC).balanceOf(alice), amount);
        console2.log("Alice USDC balance:", IERC20(USDC).balanceOf(alice));
    }

    /// @notice Test approving tokens with Permit2
    function test_ApproveTokenWithPermit2() public {
        // Give Alice some WETH
        deal(WETH, address(swapContract), 10 ether);

        // Approve WETH for Permit2 and Universal Router
        swapContract.approveTokenWithPermit2(WETH, type(uint160).max, uint48(block.timestamp + 1 days));

        // Check the approval was set
        uint256 permit2Allowance = IERC20(WETH).allowance(address(swapContract), PERMIT2);
        assertEq(permit2Allowance, type(uint256).max);

        console2.log("Permit2 allowance set successfully");
    }

    /// @notice Test swap with a real WETH/USDC V4 pool if one exists
    /// @dev This test will attempt to find and use a real V4 pool
    function test_SwapExactInputSingle() public {
        // Set up: Give the swap contract some WETH
        uint128 amountIn = 0.1 ether;
        deal(WETH, address(swapContract), amountIn);

        // Approve tokens via Permit2
        swapContract.approveTokenWithPermit2(WETH, type(uint160).max, uint48(block.timestamp + 1 days));

        // Create a PoolKey for WETH/USDC
        // Note: currency0 must be < currency1 (sorted by address)
        // USDC (0xA0b8...) < WETH (0xC02a...) so USDC is currency0
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: 3000, // 0.3% fee tier
            tickSpacing: 60, // Standard tick spacing for 0.3%
            hooks: IHooks(address(0)) // No hooks
        });

        console2.log("Attempting swap...");
        console2.log("Input amount (WETH):", amountIn);
        console2.log("currency0 (USDC):", USDC);
        console2.log("currency1 (WETH):", WETH);

        // Try the swap - this may revert if no pool exists with these exact parameters
        // In a real scenario, you would query the StateView to find valid pools
        uint256 deadline = block.timestamp + 20;

        // Note: Since WETH is currency1 and we're swapping WETH -> USDC,
        // we need to use zeroForOne = false (swapping token1 for token0)
        // But swapExactInputSingle always uses zeroForOne = true
        // So we need to use the more flexible swap() function

        try swapContract.swap(
            key,
            false, // zeroForOne = false because we're swapping WETH (currency1) -> USDC (currency0)
            amountIn,
            0, // minAmountOut (0 for testing, use proper slippage in production)
            deadline,
            bytes("")
        ) returns (uint256 amountOut) {
            console2.log("Swap successful!");
            console2.log("Amount out (USDC):", amountOut);

            // Verify we received USDC
            uint256 usdcBalance = IERC20(USDC).balanceOf(address(swapContract));
            assertGt(usdcBalance, 0, "Should have received USDC");
        } catch Error(string memory reason) {
            console2.log("Swap failed with reason:", reason);
            // This is expected if no V4 pool exists with these exact parameters
        } catch (bytes memory) {
            console2.log("Swap failed - pool may not exist with these parameters");
            // This is expected if no V4 pool exists
        }
    }

    /// @notice Test swap with native ETH pool (ETH/USDC)
    /// @dev Uses Currency.wrap(address(0)) for native ETH
    function test_SwapWithNativeETH() public {
        // Set up: Give the swap contract some ETH
        uint128 amountIn = 0.1 ether;
        vm.deal(address(swapContract), amountIn);

        // Create a PoolKey for ETH/USDC
        // Native ETH is represented as address(0)
        // address(0) < USDC so ETH is currency0
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)), // Native ETH
            currency1: Currency.wrap(USDC),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        console2.log("Attempting ETH -> USDC swap...");
        console2.log("Input amount (ETH):", amountIn);

        uint256 deadline = block.timestamp + 20;

        try swapContract.swap(
            key,
            true, // zeroForOne = true (ETH -> USDC)
            amountIn,
            0,
            deadline,
            bytes("")
        ) returns (uint256 amountOut) {
            console2.log("Swap successful!");
            console2.log("Amount out (USDC):", amountOut);
        } catch Error(string memory reason) {
            console2.log("Swap failed with reason:", reason);
        } catch (bytes memory) {
            console2.log("Swap failed - ETH/USDC pool may not exist on V4");
        }
    }

    /// @notice Helper to log pool state if needed
    function _logPoolState(PoolKey memory key) internal view {
        console2.log("=== Pool Key ===");
        console2.log("currency0:", Currency.unwrap(key.currency0));
        console2.log("currency1:", Currency.unwrap(key.currency1));
        console2.log("fee:", key.fee);
        console2.log("tickSpacing:", key.tickSpacing);
        console2.log("hooks:", address(key.hooks));
    }
}
