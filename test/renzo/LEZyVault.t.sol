// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LEZyVault} from "../../contracts/test/renzo/LEZyVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IRoleManager} from "../../contracts/test/renzo/interfaces/IRoleManager.sol";
import {IWithdrawQueue} from "../../contracts/test/renzo/interfaces/IWithdrawQueue.sol";
import {WithdrawQueue} from "../../contracts/test/renzo/WithdrawQueue.sol";
import "forge-std/console2.sol";

contract LEZyVaultTest is Test {
    LEZyVault public lezyVault;
    address public owner;
    address public feeRecipient;
    address public depositor;

    address public constant USDC = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    // Mainnet addresses
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // USDC whale for forking
    address public constant USDC_WHALE = 0x28C6c06298d514Db089934071355E5743bf21d60; // Binance hot wallet

    uint256 public constant MAINNET_BLOCK = 23_000_000; // Update with appropriate block number

    // Mock contracts
    MockRoleManager public roleManager;
    MockWithdrawQueue public mockWithdrawQueue;
    UpgradeableBeacon public withdrawQueueBeacon;

    function setUp() public {
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");

        uint256 forkId = vm.createFork(rpcUrl, MAINNET_BLOCK);
        vm.selectFork(forkId);

        owner = makeAddr("strataOwner");
        feeRecipient = makeAddr("feeRecipient");
        depositor = makeAddr("depositor");

        vm.label(owner, "Owner");
        vm.label(feeRecipient, "FeeRecipient");
        vm.label(depositor, "Depositor");
        vm.deal(owner, 100 ether);

        // Deploy mock role manager
        roleManager = new MockRoleManager();

        // Deploy mock withdraw queue implementation
        mockWithdrawQueue = new MockWithdrawQueue();

        // Deploy beacon for withdraw queue
        withdrawQueueBeacon = new UpgradeableBeacon(address(mockWithdrawQueue), owner);

        // Deploy LEZyVault implementation
        LEZyVault implementation = new LEZyVault(IBeacon(address(withdrawQueueBeacon)), WETH);

        // Deploy vault as proxy
        address proxyAddress = address(
            new ERC1967Proxy(
                address(implementation),
                abi.encodeWithSelector(
                    LEZyVault.initialize.selector,
                    IERC20(USDC), // asset
                    "Renzo USDC", // name
                    "USCC", // symbol
                    roleManager, // roleManager
                    owner, // owner
                    feeRecipient, // feeRecipient
                    1000, // feeBps (10%)
                    7 days // withdrawCoolDownPeriod
                )
            )
        );
        lezyVault = LEZyVault(payable(proxyAddress));

        // Disable whitelist for testing
        vm.prank(owner);
        lezyVault.setDepositWhitelistEnabled(false);
    }

    function test_Deposit_USDC_Mints_USCC() public {
        // Get USDC from whale
        uint256 depositAmount = 1000 * 10 ** 6; // 1000 USDC (6 decimals)

        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(depositor, depositAmount);
        vm.stopPrank();

        // Check initial balances
        uint256 initialUSDCBalance = IERC20(USDC).balanceOf(depositor);
        uint256 initialUSCCBalance = IERC20(address(lezyVault)).balanceOf(depositor);
        uint256 initialVaultUSDCBalance = IERC20(USDC).balanceOf(address(lezyVault));

        console2.log("Initial USDC balance{depositor}:", initialUSDCBalance);
        console2.log("Initial USCC balance{depositor}:", initialUSCCBalance);
        console2.log("Initial Vault USDC balance{vault}:", initialVaultUSDCBalance);

        uint256 sharesMinted = _deposit_helper(depositor, depositAmount);

        // Check final balances
        uint256 finalUSDCBalance = IERC20(USDC).balanceOf(depositor);
        uint256 finalUSCCBalance = IERC20(address(lezyVault)).balanceOf(depositor);
        uint256 finalVaultUSDCBalance = IERC20(USDC).balanceOf(address(lezyVault));

        console2.log("Final USDC balance{depositor}:", finalUSDCBalance);
        console2.log("Final USCC balance{depositor}:", finalUSCCBalance);
        console2.log("Final Vault USDC balance{vault}:", finalVaultUSDCBalance);
        console2.log("Shares minted:", sharesMinted);

        // Assertions
        assertEq(finalUSDCBalance, initialUSDCBalance - depositAmount, "USDC should be transferred from depositor");
        assertEq(finalUSCCBalance, initialUSCCBalance + sharesMinted, "USCC should be minted to depositor");
        assertEq(finalVaultUSDCBalance, initialVaultUSDCBalance + depositAmount, "Vault should receive USDC");
        assertGt(sharesMinted, 0, "Shares should be minted");

        // Verify shares match preview
        uint256 expectedShares = lezyVault.previewDeposit(depositAmount);
        assertEq(sharesMinted, expectedShares, "Shares minted should match preview");
    }

    function test_Deposit_Multiple_Deposits() public {
        uint256 firstDeposit = 500 * 10 ** 6; // 500 USDC
        uint256 secondDeposit = 1000 * 10 ** 6; // 1000 USDC

        // Get USDC from whale
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(depositor, firstDeposit + secondDeposit);
        vm.stopPrank();

        vm.startPrank(depositor);
        IERC20(USDC).approve(address(lezyVault), firstDeposit + secondDeposit);

        // First deposit
        uint256 shares1 = lezyVault.deposit(firstDeposit, depositor);
        uint256 balanceAfterFirst = IERC20(address(lezyVault)).balanceOf(depositor);

        // Second deposit
        uint256 shares2 = lezyVault.deposit(secondDeposit, depositor);
        uint256 balanceAfterSecond = IERC20(address(lezyVault)).balanceOf(depositor);

        vm.stopPrank();

        // Assertions
        assertEq(balanceAfterFirst, shares1, "Balance after first deposit should equal shares1");
        assertEq(balanceAfterSecond, shares1 + shares2, "Balance after second deposit should equal shares1 + shares2");
        assertGt(shares2, shares1, "Second deposit should mint more shares (due to exchange rate)");
    }

    function test_Deposit_With_Whitelist() public {
        // Enable whitelist
        vm.prank(owner);
        lezyVault.setDepositWhitelistEnabled(true);

        // Whitelist depositor
        address[] memory accounts = new address[](1);
        bool[] memory status = new bool[](1);
        accounts[0] = depositor;
        status[0] = true;

        vm.prank(owner);
        lezyVault.updateWhitelist(accounts, status);

        // Get USDC and deposit
        uint256 depositAmount = 1000 * 10 ** 6;

        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(depositor, depositAmount);
        vm.stopPrank();

        vm.startPrank(depositor);
        IERC20(USDC).approve(address(lezyVault), depositAmount);

        uint256 sharesMinted = lezyVault.deposit(depositAmount, depositor);
        vm.stopPrank();

        assertGt(sharesMinted, 0, "Shares should be minted for whitelisted user");
    }

    function test_Deposit_Reverts_When_Not_Whitelisted() public {
        // Enable whitelist
        vm.prank(owner);
        lezyVault.setDepositWhitelistEnabled(true);

        // Don't whitelist depositor

        // Get USDC
        uint256 depositAmount = 1000 * 10 ** 6;

        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(depositor, depositAmount);
        vm.stopPrank();

        vm.startPrank(depositor);
        IERC20(USDC).approve(address(lezyVault), depositAmount);

        // Should revert
        vm.expectRevert();
        lezyVault.deposit(depositAmount, depositor);
        vm.stopPrank();
    }

    function test_Withdraw_USDC_Burns_USCC() public {
        // Get USDC from whale
        uint256 depositAmount = 1000 * 10 ** 6; // 1000 USDC (6 decimals)

        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(depositor, depositAmount);
        vm.stopPrank();

        // deposit usdc to lezy vault and mint uscc
        uint256 initialUSCCBalance = IERC20(address(lezyVault)).balanceOf(depositor);
        uint256 sharesMinted = _deposit_helper(depositor, depositAmount);
        uint256 finalUSCCBalance = IERC20(address(lezyVault)).balanceOf(depositor);
        assertEq(finalUSCCBalance, initialUSCCBalance + sharesMinted, "USCC should be minted to depositor");

        // Get withdraw queue address from vault and cast to concrete type for full interface access
        WithdrawQueue withdrawQueue = WithdrawQueue(address(lezyVault.withdrawQueue()));

        // Record balances before withdrawal
        uint256 usccBalanceBeforeWithdraw = IERC20(address(lezyVault)).balanceOf(depositor);
        uint256 usdcBalanceBeforeWithdraw = IERC20(USDC).balanceOf(depositor);

        console2.log("USCC balance before withdraw{depositor}:", usccBalanceBeforeWithdraw);
        console2.log("USDC balance before withdraw{depositor}:", usdcBalanceBeforeWithdraw);

        // Step 1: Approve USCC (LP tokens) to the WithdrawQueue contract and call withdraw
        vm.startPrank(depositor);
        IERC20(address(lezyVault)).approve(address(withdrawQueue), sharesMinted);

        // Call withdraw on the WithdrawQueue - this creates a withdraw request
        withdrawQueue.withdraw(sharesMinted);
        vm.stopPrank();

        // Verify shares were transferred to withdraw queue
        uint256 usccBalanceAfterWithdrawRequest = IERC20(address(lezyVault)).balanceOf(depositor);
        uint256 withdrawQueueUsccBalance = IERC20(address(lezyVault)).balanceOf(address(withdrawQueue));

        console2.log("USCC balance after withdraw request{depositor}:", usccBalanceAfterWithdrawRequest);
        console2.log("WithdrawQueue USCC balance{withdrawQueue}:", withdrawQueueUsccBalance);

        assertEq(usccBalanceAfterWithdrawRequest, 0, "All USCC should be transferred to withdraw queue");
        assertEq(withdrawQueueUsccBalance, sharesMinted, "Withdraw queue should hold the shares");

        // Verify withdraw request was created
        uint256 totalRequests = withdrawQueue.totalUserWithdrawRequests(depositor);
        assertEq(totalRequests, 1, "Should have 1 withdraw request");

        // Step 2: Rebalance admin triggers _fillWithdrawQueue by calling manage()
        // Create a rebalance admin and set up a dummy delegate strategy
        address rebalanceAdmin = makeAddr("rebalanceAdmin");
        roleManager.setRebalanceAdmin(rebalanceAdmin, true);

        // Deploy a dummy delegate strategy
        DummyDelegateStrategy dummyStrategy = new DummyDelegateStrategy();

        // Owner adds the dummy strategy to allowed strategies
        address[] memory strategies = new address[](1);
        strategies[0] = address(dummyStrategy);
        vm.prank(owner);
        lezyVault.addDelegateStrategies(strategies);

        // Rebalance admin calls manage() to trigger _fillWithdrawQueue()
        // The payload calls a no-op function on the dummy strategy
        vm.prank(rebalanceAdmin);
        lezyVault.manage(address(dummyStrategy), abi.encodeWithSelector(DummyDelegateStrategy.noop.selector));

        // Verify USDC was transferred to withdraw queue
        uint256 usdcBalanceOfWithdrawQueue = IERC20(USDC).balanceOf(address(withdrawQueue));
        console2.log("USDC balance of withdraw queue after manage:", usdcBalanceOfWithdrawQueue);
        assertEq(
            usdcBalanceOfWithdrawQueue,
            depositAmount,
            "USDC balance of withdraw queue should be equal to deposit amount"
        );

        // Step 3: Wait for cooldown period to pass (7 days as configured in setUp)
        vm.warp(block.timestamp + 7 days + 1);

        // Record balances before claim
        uint256 usdcBalanceBeforeClaim = IERC20(USDC).balanceOf(depositor);
        uint256 usccTotalSupplyBeforeClaim = IERC20(address(lezyVault)).totalSupply();

        console2.log("USDC balance before claim:", usdcBalanceBeforeClaim);
        console2.log("USCC total supply before claim:", usccTotalSupplyBeforeClaim);

        // Step 4: Claim the withdrawal - anyone can call this for the user
        withdrawQueue.claim(0, depositor);

        // Verify final balances
        uint256 usdcBalanceAfterClaim = IERC20(USDC).balanceOf(depositor);
        uint256 usccTotalSupplyAfterClaim = IERC20(address(lezyVault)).totalSupply();
        uint256 withdrawQueueUsccBalanceAfterClaim = IERC20(address(lezyVault)).balanceOf(address(withdrawQueue));

        console2.log("USDC balance after claim:", usdcBalanceAfterClaim);
        console2.log("USCC total supply after claim:", usccTotalSupplyAfterClaim);
        console2.log("WithdrawQueue USCC balance after claim:", withdrawQueueUsccBalanceAfterClaim);

        // Assertions
        assertGt(usdcBalanceAfterClaim, usdcBalanceBeforeClaim, "Depositor should receive USDC back");
        assertEq(usccTotalSupplyAfterClaim, usccTotalSupplyBeforeClaim - sharesMinted, "USCC should be burned");
        assertEq(withdrawQueueUsccBalanceAfterClaim, 0, "Withdraw queue should have no USCC left");

        // Verify withdraw request was removed
        uint256 totalRequestsAfterClaim = withdrawQueue.totalUserWithdrawRequests(depositor);
        assertEq(totalRequestsAfterClaim, 0, "Withdraw request should be removed after claim");

        // Verify approximate USDC amount received (should be close to deposit amount)
        uint256 usdcReceived = usdcBalanceAfterClaim - usdcBalanceBeforeClaim;
        console2.log("USDC received:", usdcReceived);
        assertApproxEqRel(usdcReceived, depositAmount, 0.01e18, "Should receive approximately the deposited amount");
    }

    function _deposit_helper(address depositor, uint256 depositAmount) internal returns (uint256) {
        vm.startPrank(depositor);
        IERC20(USDC).approve(address(lezyVault), depositAmount);

        uint256 sharesMinted = lezyVault.deposit(depositAmount, depositor);
        vm.stopPrank();

        return sharesMinted;
    }
}

// Mock Role Manager
contract MockRoleManager is IRoleManager {
    mapping(address => bool) public isRebalanceAdminMap;
    mapping(address => bool) public isPauserMap;
    mapping(address => bool) public isExchangeRateAdminMap;

    function isRebalanceAdmin(address potentialAddress) external view override returns (bool) {
        return isRebalanceAdminMap[potentialAddress];
    }

    function isPauser(address potentialAddress) external view override returns (bool) {
        return isPauserMap[potentialAddress];
    }

    function isExchangeRateAdmin(address potentialAddress) external view override returns (bool) {
        return isExchangeRateAdminMap[potentialAddress];
    }

    // Helper functions for testing
    function setRebalanceAdmin(address addr, bool status) external {
        isRebalanceAdminMap[addr] = status;
    }

    function setPauser(address addr, bool status) external {
        isPauserMap[addr] = status;
    }

    function setExchangeRateAdmin(address addr, bool status) external {
        isExchangeRateAdminMap[addr] = status;
    }
}

contract MockWithdrawQueue is WithdrawQueue {}

// Dummy Delegate Strategy for testing - used to trigger _fillWithdrawQueue via manage()
contract DummyDelegateStrategy {
    // Returns 0 underlying value - no assets managed
    function underlyingValue(address) external pure returns (uint256) {
        return 0;
    }

    // No-op function that can be called via delegatecall from manage()
    function noop() external {}
}

