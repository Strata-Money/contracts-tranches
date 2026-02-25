// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {USCCDeploy, DummyDelegateStrategy} from "./USCCDeploy.t.sol";
import {IsUSCC} from "../../contracts/tranches/strategies/renzo/interfaces/IsUSCC.sol";
import {ICooldown} from "../../contracts/tranches/interfaces/cooldown/ICooldown.sol";
import {WithdrawQueue} from "../../contracts/test/renzo/WithdrawQueue.sol";

/**
 * @title USCCTest
 * @notice Unit tests for the USCC (Renzo) Strategy
 * @dev Tests deposit, withdrawal, vesting, and cooldown mechanisms.
 *      Key differences from Neutrl strategy:
 *      - Only USDC is supported as deposit/withdrawal token (no direct ezUSCC deposits)
 *      - Withdrawals always go through Renzo's WithdrawQueue with 7-day cooldown
 *      - Strategy has its own 24-hour vesting for yield (superstate doesn't have built-in vesting)
 */
contract USCCTest is USCCDeploy {
    // Test users
    address public alice;
    address public bob;

    // Test amounts (using ether scale to satisfy MIN_SHARES constraint in Tranche)
    uint256 constant INITIAL_BALANCE = 10_000 ether;
    uint256 constant DEPOSIT_AMOUNT = 1000 ether;
    uint256 constant MIN_SHARES = 1 ether;

    // Helper contracts for withdraw queue operations
    DummyDelegateStrategy internal dummyStrategy;
    address internal rebalanceAdmin;

    function setUp() public override {
        super.setUp();

        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.label(alice, "Alice");
        vm.label(bob, "Bob");

        // Deploy the full Strata stack
        _deployStrataStack();

        // Set up rebalance admin and dummy strategy for withdraw queue operations
        rebalanceAdmin = makeAddr("rebalanceAdmin");
        roleManager.setRebalanceAdmin(rebalanceAdmin, true);
        roleManager.setExchangeRateAdmin(rebalanceAdmin, true);

        dummyStrategy = new DummyDelegateStrategy();
        address[] memory strategies = new address[](1);
        strategies[0] = address(dummyStrategy);
        vm.prank(owner);
        ezUSCC.addDelegateStrategies(strategies);

        // Mint USDC to test users
        _mintUSDC(alice, INITIAL_BALANCE);
        _mintUSDC(bob, INITIAL_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DepositUSDC_ToJrtVault() public {
        vm.startPrank(alice);

        uint256 balanceBefore = IERC20(USDC).balanceOf(alice);

        // Approve and deposit USDC into JRT vault
        IERC20(USDC).approve(address(jrtVault), DEPOSIT_AMOUNT);
        uint256 shares = jrtVault.deposit(USDC, DEPOSIT_AMOUNT, alice);

        // Verify shares received
        assertGt(shares, 0, "Should receive shares");
        assertEq(jrtVault.balanceOf(alice), shares, "Alice should have shares");

        // Verify USDC was transferred
        uint256 balanceAfter = IERC20(USDC).balanceOf(alice);
        assertEq(balanceBefore - balanceAfter, DEPOSIT_AMOUNT, "USDC should be transferred");

        // Verify strategy holds ezUSCC shares (not raw USDC)
        uint256 strategyEzUSCCBalance = IERC20(address(ezUSCC)).balanceOf(address(strategy));
        assertGt(strategyEzUSCCBalance, 0, "Strategy should hold ezUSCC shares");

        // Verify strategy has no leftover USDC
        uint256 strategyUSDCBalance = IERC20(USDC).balanceOf(address(strategy));
        assertEq(strategyUSDCBalance, 0, "Strategy should have no USDC");

        vm.stopPrank();
    }

    function test_DepositUSDC_ToSrtVault() public {
        // First deposit to JRT to meet minimum ratio requirements
        _depositToJrt(alice, DEPOSIT_AMOUNT * 2);

        vm.startPrank(alice);

        uint256 balanceBefore = IERC20(USDC).balanceOf(alice);

        // Approve and deposit USDC into SRT vault
        IERC20(USDC).approve(address(srtVault), DEPOSIT_AMOUNT);
        uint256 shares = srtVault.deposit(USDC, DEPOSIT_AMOUNT, alice);

        // Verify shares received
        assertGt(shares, 0, "Should receive shares");
        assertEq(srtVault.balanceOf(alice), shares, "Alice should have shares");

        // Verify USDC was transferred
        uint256 balanceAfter = IERC20(USDC).balanceOf(alice);
        assertEq(balanceBefore - balanceAfter, DEPOSIT_AMOUNT, "USDC should be transferred");

        vm.stopPrank();
    }

    function test_DepositToReceiver() public {
        vm.startPrank(alice);

        // Approve and deposit USDC to Bob as receiver
        IERC20(USDC).approve(address(jrtVault), DEPOSIT_AMOUNT);
        uint256 shares = jrtVault.deposit(USDC, DEPOSIT_AMOUNT, bob);

        // Verify Bob received the shares
        assertEq(jrtVault.balanceOf(bob), shares, "Bob should have shares");
        assertEq(jrtVault.balanceOf(alice), 0, "Alice should have no shares");

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           WITHDRAW TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test that USDC withdrawal creates an unstake cooldown request
     * @dev USCC withdrawals always go through Renzo's WithdrawQueue (7-day cooldown)
     */
    function test_WithdrawUSDC_FromJrtVault_CreatesUnstakeRequest() public {
        // Bob deposits to maintain liquidity (prevents MinSharesViolation)
        _depositToJrt(bob, DEPOSIT_AMOUNT);

        // Alice deposits
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        vm.startPrank(alice);

        uint256 shares = jrtVault.balanceOf(alice);
        uint256 withdrawShares = shares - MIN_SHARES;

        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);

        // Redeem USDC - creates an unstake cooldown request
        jrtVault.redeem(USDC, withdrawShares, alice, alice);

        // USDC should NOT be received immediately (goes through WithdrawQueue cooldown)
        uint256 usdcAfter = IERC20(USDC).balanceOf(alice);
        assertEq(usdcAfter, usdcBefore, "USDC should not be received immediately");

        vm.stopPrank();

        // Check unstake cooldown balance
        (uint256 pending, uint256 claimable,,, uint256 totalRequests) = _getUnstakeCooldownBalance(alice);

        assertGt(pending, 0, "Should have pending amount in cooldown");
        assertEq(claimable, 0, "Should have no claimable amount yet");
        assertEq(totalRequests, 1, "Should have one request");
    }

    /**
     * @notice Test full withdraw flow: deposit -> redeem -> fill queue -> wait -> finalize -> receive USDC
     */
    function test_WithdrawUSDC_FinalizeAfterCooldown() public {
        // Bob deposits to maintain liquidity
        _depositToJrt(bob, DEPOSIT_AMOUNT);

        // Alice deposits
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        vm.startPrank(alice);

        uint256 shares = jrtVault.balanceOf(alice);
        uint256 withdrawShares = shares - MIN_SHARES;

        // Redeem USDC
        jrtVault.redeem(USDC, withdrawShares, alice, alice);

        vm.stopPrank();

        // Check pending balance
        (uint256 pending,,,, uint256 totalRequests) = _getUnstakeCooldownBalance(alice);
        assertGt(pending, 0, "Should have pending amount");
        assertEq(totalRequests, 1, "Should have one request");

        // Fill the withdraw queue (simulating rebalance admin action)
        _fillWithdrawQueue();

        // Wait for cooldown period (7 days)
        vm.warp(block.timestamp + 7 days + 1);

        // Check balance is now claimable
        (, uint256 claimable,,,) = _getUnstakeCooldownBalance(alice);
        assertGt(claimable, 0, "Should have claimable amount after cooldown");

        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);

        // Finalize the unstake (claim USDC)
        uint256 claimed = unstakeCooldown.finalize(IERC20(address(ezUSCC)), alice);
        uint256 usdcAfter = IERC20(USDC).balanceOf(alice);
        // Verify USDC received
        assertGt(claimed, 0, "Should claim tokens");
        assertEq(usdcAfter - usdcBefore, claimed, "Should receive USDC");
    }

    /**
     * @notice Test withdrawing from SRT vault also creates unstake request
     */
    function test_WithdrawUSDC_FromSrtVault() public {
        // Deposit to JRT first (for coverage ratio)
        _depositToJrt(alice, DEPOSIT_AMOUNT * 3);

        // Deposit to SRT
        _depositToSrt(alice, DEPOSIT_AMOUNT);

        // Bob deposits to SRT to avoid min shares violation
        _depositToJrt(bob, DEPOSIT_AMOUNT * 3);
        _depositToSrt(bob, DEPOSIT_AMOUNT);

        vm.startPrank(alice);

        uint256 shares = srtVault.balanceOf(alice);
        uint256 withdrawShares = shares - MIN_SHARES;

        // Redeem from SRT
        srtVault.redeem(USDC, withdrawShares, alice, alice);

        vm.stopPrank();

        // Should have unstake cooldown request
        (uint256 pending,,,, uint256 totalRequests) = _getUnstakeCooldownBalance(alice);
        assertGt(pending, 0, "Should have pending amount in cooldown");
        assertEq(totalRequests, 1, "Should have one request");
    }

    /**
     * @notice Test multiple withdrawal requests from the same user
     */
    function test_MultipleWithdrawRequests() public {
        // Bob deposits to maintain liquidity
        _depositToJrt(bob, DEPOSIT_AMOUNT);

        // Alice deposits a larger amount
        _depositToJrt(alice, DEPOSIT_AMOUNT * 5);

        vm.startPrank(alice);

        uint256 withdrawAmount = DEPOSIT_AMOUNT;

        // Make multiple withdrawal requests
        jrtVault.withdraw(USDC, withdrawAmount, alice, alice);

        vm.warp(block.timestamp + 1 hours);

        jrtVault.withdraw(USDC, withdrawAmount, alice, alice);

        vm.warp(block.timestamp + 1 hours);

        jrtVault.withdraw(USDC, withdrawAmount, alice, alice);

        vm.stopPrank();

        // Check we have multiple pending requests
        (,,,, uint256 totalRequests) = _getUnstakeCooldownBalance(alice);
        assertEq(totalRequests, 3, "Should have 3 pending requests");

        // Fill the withdraw queue
        _fillWithdrawQueue();

        // Warp past all cooldowns (7 days)
        vm.warp(block.timestamp + 7 days + 1);

        // Finalize all
        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);
        uint256 claimed = unstakeCooldown.finalize(IERC20(address(ezUSCC)), alice);

        assertGt(claimed, 0, "Should claim all pending tokens");
        uint256 usdcAfter = IERC20(USDC).balanceOf(alice);
        assertEq(usdcAfter - usdcBefore, claimed, "Should receive claimed USDC");

        (uint256 pending, uint256 claimable,,,uint tR) = _getUnstakeCooldownBalance(alice);
        assertEq(pending, 0, "Should have no pending amount");
        assertEq(claimable, 0, "Should have no claimable amount");
        assertEq(tR, 0, "Should have no total requests");
    }

    /*//////////////////////////////////////////////////////////////
                        VESTING TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test that vesting is initialized on first deposit
     * @dev Superstate doesn't have built-in vesting, so the strategy implements its own 24h vesting
     */
    function test_VestingInitializedOnFirstDeposit() public {
        // Before deposit, vesting should not be initialized
        assertEq(strategy.lastVestingTimestamp(), 0, "lastVestingTimestamp should be 0 initially");
        assertEq(strategy.vestingAmount(), 0, "vestingAmount should be 0 initially");
        assertEq(strategy.getUnvestedAmount(), 0, "unvested should be 0 initially");

        // Deposit
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        // After first deposit, vesting should be initialized
        assertEq(strategy.lastVestingTimestamp(), block.timestamp, "lastVestingTimestamp should be set");
        assertEq(strategy.vestingAmount(), 0, "vestingAmount should be 0 for first deposit");
        // lastTotalAssets is updated after the ezUSCC deposit to include the deposit amount
        assertApproxEqRel(strategy.lastTotalAssets(), DEPOSIT_AMOUNT, 0.01e18, "lastTotalAssets should include deposit");
        console2.log("lastTotalAssets", strategy.lastTotalAssets());
        console2.log("DEPOSIT_AMOUNT", DEPOSIT_AMOUNT);
        assertEq(strategy.getUnvestedAmount(), 0, "unvested should be 0 after first deposit");

        // Total assets should equal the deposit amount since no vesting is active
        uint256 totalAssets = strategy.totalAssets();
        assertApproxEqRel(totalAssets, DEPOSIT_AMOUNT, 0.01e18, "totalAssets should equal deposit amount");
    }

    /**
     * @notice Test that vesting timestamp and amount do not update during the vesting period
     * @dev Note: lastTotalAssets IS updated after each deposit (to track capital changes),
     *      but the vesting parameters (timestamp, vestingAmount) remain unchanged.
     */
    function test_DuringVestingPeriod_NoVestingUpdate() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        uint256 initialVestingTimestamp = strategy.lastVestingTimestamp();

        // Warp 12 hours (still within 24h vesting period)
        vm.warp(block.timestamp + 12 hours);

        // Simulate yield
        _simulateYield(5 ether);

        // Another deposit triggers _updateVesting (but it should be a no-op for vesting params)
        _depositToJrt(bob, DEPOSIT_AMOUNT);

        // Vesting timestamp and amount should NOT be updated (still in window)
        assertEq(
            strategy.lastVestingTimestamp(),
            initialVestingTimestamp,
            "lastVestingTimestamp should not change during vesting"
        );
        assertEq(strategy.vestingAmount(), 0, "vestingAmount should still be 0");

        // lastTotalAssets WILL be updated to include Bob's deposit
        assertGt(strategy.lastTotalAssets(), DEPOSIT_AMOUNT, "lastTotalAssets should include both deposits");
    }

    /**
     * @notice Test that vesting updates after the 24-hour period with yield
     */
    function test_VestingUpdatesAfterPeriod() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        uint256 initialVestingTimestamp = strategy.lastVestingTimestamp();

        // Simulate a small yield in ezUSCC
        _simulateYield(5 ether);

        // Warp past vesting period (24 hours)
        vm.warp(block.timestamp + 25 hours);

        // New deposit triggers _updateVesting
        _depositToJrt(bob, DEPOSIT_AMOUNT);

        // Vesting should be updated
        assertGt(strategy.lastVestingTimestamp(), initialVestingTimestamp, "Vesting timestamp should be updated");
        assertGt(strategy.vestingAmount(), 0, "Vesting amount should reflect yield gain");
    }

    /**
     * @notice Test that unvested amount decreases linearly over time
     */
    function test_UnvestedAmount_DecreasesOverTime() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        // Simulate a small yield and warp past first vesting period
        _simulateYield(5 ether);
        vm.warp(block.timestamp + 25 hours);

        // Trigger new vesting period
        _depositToJrt(bob, DEPOSIT_AMOUNT);

        uint256 vestingAmt = strategy.vestingAmount();
        assertGt(vestingAmt, 0, "vestingAmount should be set");

        // At start of new vesting, unvested should approximately equal vestingAmount
        uint256 unvestedAtStart = strategy.getUnvestedAmount();
        assertApproxEqRel(unvestedAtStart, vestingAmt, 0.01e18, "unvested should equal vestingAmount at start");

        // Warp 12 hours (halfway through 24h vesting)
        vm.warp(block.timestamp + 12 hours);
        uint256 unvestedHalfway = strategy.getUnvestedAmount();
        assertApproxEqRel(unvestedHalfway, vestingAmt / 2, 0.05e18, "unvested should be ~50% at halfway");

        // Warp to end of vesting period
        vm.warp(block.timestamp + 12 hours);
        uint256 unvestedAtEnd = strategy.getUnvestedAmount();
        assertEq(unvestedAtEnd, 0, "unvested should be 0 at end of vesting period");
    }

    /**
     * @notice Test that totalAssets excludes unvested amount during active vesting
     */
    function test_TotalAssets_ExcludesUnvested() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        // Simulate a small yield and warp past first vesting period
        _simulateYield(5 ether);
        vm.warp(block.timestamp + 25 hours);

        // Trigger new vesting period
        _depositToJrt(bob, DEPOSIT_AMOUNT);

        uint256 rawAssets = ezUSCC.previewRedeem(IERC20(address(ezUSCC)).balanceOf(address(strategy)));
        uint256 totalAssets = strategy.totalAssets();
        uint256 unvested = strategy.getUnvestedAmount();

        // totalAssets = rawAssets - unvested
        assertApproxEqRel(totalAssets, rawAssets - unvested, 0.01e18, "totalAssets should be rawAssets - unvested");
        assertGt(unvested, 0, "Should have unvested amount during active vesting");
    }

    /**
     * @notice Test totalAssets equals rawAssets when fully vested
     */
    function test_TotalAssets_EqualsRawAssetsWhenFullyVested() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        // Simulate a small yield and warp past first vesting period
        _simulateYield(5 ether);
        vm.warp(block.timestamp + 25 hours);

        // Trigger new vesting period
        _depositToJrt(bob, DEPOSIT_AMOUNT);

        // Warp past the vesting period so everything is fully vested
        vm.warp(block.timestamp + 25 hours);

        uint256 rawAssets = ezUSCC.previewRedeem(IERC20(address(ezUSCC)).balanceOf(address(strategy)));
        uint256 totalAssets = strategy.totalAssets();
        uint256 unvested = strategy.getUnvestedAmount();

        assertEq(unvested, 0, "unvested should be 0");
        assertApproxEqRel(totalAssets, rawAssets, 0.01e18, "totalAssets should equal rawAssets when fully vested");
    }

    /**
     * @notice Test that the vesting period constant is 24 hours
     */
    function test_VestingPeriodConstant() public view {
        assertEq(strategy.VESTING_PERIOD(), 24 hours, "VESTING_PERIOD should be 24 hours");
    }

    /*//////////////////////////////////////////////////////////////
                        APR CALCULATION TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice APR base should be 0 before any deposit (vesting not started)
     */
    function test_APR_zeroBeforeVestingStarts() public view {
        int64 aprBase = provider.getAPRbase();
        assertEq(aprBase, 0, "APR base should be 0 before vesting starts");
    }

    /**
     * @notice APR base should be 0 during the first 24-hour vesting period (no yield yet)
     */
    function test_APR_zeroDuringFirstVestingPeriod() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        // During first 24 hours, vestingAmount is 0, so APR = 0
        vm.warp(block.timestamp + 12 hours);

        int64 aprBase = provider.getAPRbase();
        assertEq(aprBase, 0, "APR base should be 0 during first vesting period (no yield yet)");
    }

    /**
     * @notice APR base should be positive during active vesting with yield
     */
    function test_APR_positiveDuringActiveVesting() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        // Simulate yield and warp past first vesting period
        _simulateYield(5 ether);
        vm.warp(block.timestamp + 25 hours);

        // Trigger new vesting period via deposit
        _depositToJrt(bob, DEPOSIT_AMOUNT);

        // Warp a small amount into the new vesting window so the provider sees active vesting
        vm.warp(block.timestamp + 1 hours);

        // Now during active vesting, APR should be positive
        int64 aprBase = provider.getAPRbase();
        console2.log("APR base during vesting:", aprBase);
        assertGt(aprBase, 0, "APR base should be positive during active vesting");
    }

    /**
     * @notice APR base should return to 0 after the vesting period completes
     */
    function test_APR_zeroAfterVestingComplete() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        // Simulate yield and warp past first vesting period
        _simulateYield(5 ether);
        vm.warp(block.timestamp + 25 hours);

        // Trigger new vesting period
        _depositToJrt(bob, DEPOSIT_AMOUNT);

        // Warp past the new vesting period entirely
        vm.warp(block.timestamp + 25 hours);

        // APR should be 0 after vesting completes (until new yield is detected)
        int64 aprBase = provider.getAPRbase();
        assertEq(aprBase, 0, "APR base should be 0 after vesting completes");
    }

    /**
     * @notice APR target should be derived from the Sky Savings Rate (SSR)
     */
    function test_APRtarget_fromSkySSR() public {
        // Set mock SSR value (5% APR in 1e27 format)
        // ssr = 1e27 + (5% * 1e27 / SECONDS_PER_YEAR)
        uint256 fivePercent = 5 * 1e25;
        uint256 secondsPerYear = 31_536_000;
        uint256 ratePerSecond = fivePercent / secondsPerYear;
        uint256 ssrValue = 1e27 + ratePerSecond;
        sUSDS.setSSR(ssrValue);

        int64 aprTarget = provider.getAPRtarget();
        // APR should be approximately 5% (in 1e12 format = 0.05e12 = 5e10)
        assertGt(aprTarget, 0, "APR target should be positive");
        console2.log("APR target:", aprTarget);
    }

    /**
     * @notice APR target should be 0 when SSR is below 1e27 (no positive rate)
     */
    function test_APRtarget_zeroWhenSSRBelowOne() public {
        // SSR = 0 (default in MockSUSDS) → APR target = 0
        int64 aprTarget = provider.getAPRtarget();
        assertEq(aprTarget, 0, "APR target should be 0 when SSR < 1e27");
    }

    /**
     * @notice Both APR values should be returned together via getAprPair
     */
    function test_getAprPair_returnsBothValues() public {
        // Set up a 5% SSR for target APR
        uint256 fivePercent = 5 * 1e25;
        uint256 secondsPerYear = 31_536_000;
        uint256 ratePerSecond = fivePercent / secondsPerYear;
        sUSDS.setSSR(1e27 + ratePerSecond);

        // Set up active vesting for base APR
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _simulateYield(5 ether);
        vm.warp(block.timestamp + 25 hours);
        _depositToJrt(bob, DEPOSIT_AMOUNT);
        vm.warp(block.timestamp + 1 hours);

        (int64 aprTarget, int64 aprBase, uint64 timestamp) = provider.getAprPair();

        assertGt(aprTarget, 0, "APR target should be positive");
        assertGt(aprBase, 0, "APR base should be positive");
        assertEq(timestamp, uint64(block.timestamp), "Timestamp should be current block");
        console2.log("APR target:", aprTarget);
        console2.log("APR base:", aprBase);
    }

    /*//////////////////////////////////////////////////////////////
                            EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_RevertOnZeroDeposit() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(address(jrtVault), 1);

        vm.expectRevert();
        jrtVault.deposit(USDC, 0, alice);

        vm.stopPrank();
    }

    function test_RevertOnExceedingMaxWithdraw() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);

        vm.startPrank(alice);

        uint256 maxWithdraw = jrtVault.maxWithdraw(alice);

        vm.expectRevert();
        jrtVault.withdraw(USDC, maxWithdraw + 1 ether, alice, alice);

        vm.stopPrank();
    }

    function test_TotalAssets() public {
        _depositToJrt(alice, DEPOSIT_AMOUNT);
        _depositToJrt(bob, DEPOSIT_AMOUNT);

        uint256 totalAssets = strategy.totalAssets();
        assertGt(totalAssets, 0, "Total assets should be positive");

        // Total assets should be approximately equal to deposits
        assertApproxEqRel(totalAssets, DEPOSIT_AMOUNT * 2, 0.01e18, "Total assets should match deposits");
    }

    function test_GetSupportedTokens() public view {
        IERC20[] memory supported = strategy.getSupportedTokens();
        assertEq(supported.length, 1, "Should have 1 supported token");
        assertEq(address(supported[0]), USDC, "Only supported token should be USDC");
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    function _mintUSDC(address to, uint256 amount) internal {
        deal(USDC, to, amount);
    }

    function _depositToJrt(address user, uint256 amount) internal {
        vm.startPrank(user);

        IERC20(USDC).approve(address(jrtVault), amount);
        jrtVault.deposit(USDC, amount, user);

        vm.stopPrank();
    }

    function _depositToSrt(address user, uint256 amount) internal {
        vm.startPrank(user);

        IERC20(USDC).approve(address(srtVault), amount);
        srtVault.deposit(USDC, amount, user);

        vm.stopPrank();
    }

    function _fillWithdrawQueue() internal {
        WithdrawQueue wq = WithdrawQueue(address(ezUSCC.withdrawQueue()));

        uint256 deficit = wq.getQueueDeficit();
        if (deficit == 0) return;

        // Deal USDC to the vault to cover the withdrawal deficit
        deal(USDC, address(ezUSCC), IERC20(USDC).balanceOf(address(ezUSCC)) + deficit);

        // Track underlying so vault recognizes the new USDC
        vm.prank(rebalanceAdmin);
        ezUSCC.trackUnderlying();

        // Rebalance admin calls manage() to trigger _fillWithdrawQueue
        vm.prank(rebalanceAdmin);
        ezUSCC.manage(address(dummyStrategy), abi.encodeWithSelector(DummyDelegateStrategy.noop.selector));
    }

    function _simulateYield(uint256 yieldAmount) internal {
        // Deal USDC directly to ezUSCC vault to simulate yield (increases exchange rate)
        deal(USDC, address(ezUSCC), IERC20(USDC).balanceOf(address(ezUSCC)) + yieldAmount);

        // Track underlying in the vault to update exchange rate
        vm.prank(rebalanceAdmin);
        ezUSCC.trackUnderlying();
    }

    function _getUnstakeCooldownBalance(address user)
        internal
        view
        returns (
            uint256 pending,
            uint256 claimable,
            uint256 nextUnlockAt,
            uint256 nextUnlockAmount,
            uint256 totalRequests
        )
    {
        ICooldown.TBalanceState memory state = unstakeCooldown.balanceOf(IERC20(address(ezUSCC)), user);
        return (state.pending, state.claimable, state.nextUnlockAt, state.nextUnlockAmount, state.totalRequests);
    }
}
