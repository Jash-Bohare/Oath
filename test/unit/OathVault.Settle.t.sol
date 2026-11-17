// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Vm} from "forge-std/Vm.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IOathHook} from "../../src/interfaces/IOathHook.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {BenchmarkLib} from "../../src/libraries/BenchmarkLib.sol";
import {SettlementLib} from "../../src/libraries/SettlementLib.sol";
import {ValuationLib} from "../../src/libraries/ValuationLib.sol";
import {OathVaultTestBase} from "../utils/OathVaultTestBase.sol";

/// @notice Settling an epoch against its benchmark, on a vault created through the real factory and started with
///         the MATH.md §9.1 deposit and bond in a pool as deep as the real one.
contract OathVaultSettleTest is OathVaultTestBase {
    using StateLibrary for IPoolManager;

    uint256 internal startedAt;
    uint256 internal endsAt;

    function setUp() public override {
        super.setUp();
        _createVault(currency0);
        _seedPool(POOL_LIQUIDITY);
        _fundWorkedExample();
        _wait(1 hours);
    }

    // ---------------------------------------------------------------- outcomes

    /// @dev A full-range curator is the benchmark in real form: both earn the same fees per unit of liquidity and
    ///      move the same way, so the difference stays inside the band and nothing moves. The stored result
    ///      matches an independent recomputation from the hook's checkpoints and snapshot.
    function test_settle_insideBand() public {
        (int24 tickMin, int24 tickMax) = _fullRange();
        _begin(tickMin, tickMax);
        _swapAroundStart(4);
        _toEnd();

        IOathVault.EpochResult memory expected = _expected();
        vm.expectEmit(true, false, false, true, address(vault));
        emit IOathVault.Settled(0, expected);
        _settleAs(keeper);

        IOathVault.EpochResult memory r = vault.getResult(0);
        assertEq(abi.encode(r), abi.encode(expected), "result = independent recomputation");
        assertEq(vault.epochCount(), 1);
        assertGt(r.vaultFees0 + r.vaultFees1, 0, "vault earned fees");
        assertGt(r.benchFees0 + r.benchFees1, 0, "benchmark earned fees");
        assertLe(r.diff < 0 ? uint256(-r.diff) : uint256(r.diff), r.band, "inside the band");
        assertEq(r.payout, 0);
        assertEq(r.fee, 0);
        assertEq(r.feeShares, 0);
        assertEq(r.bondAfter, BOND);
        assertEq(vault.bondBalance(), BOND);
        assertEq(vault.balanceOf(curator), 0);
        assertEq(r.start, startedAt);
        assertEq(r.end, endsAt);
        assertEq(r.startTick, START_TICK);
        assertEq(r.endTick, START_TICK, "price back at the start tick for the whole TWAP window");
        assertEq(r.navStart, NAV_START);
    }

    /// @dev The curator's tight range is left behind by a 2,079-tick fall to the MATH.md §9.1 loss price (−201275,
    ///      $1,816.25): the vault ends almost all currency0 and falls with it, while the passive full-range
    ///      benchmark loses less. The shortfall beyond the band is within the bond, so the bond pays exactly that
    ///      to depositors: the payout stays in the vault and becomes idle. Without each side's own fees, the
    ///      on-chain values match the reference model `oath_math.py` for this example within $0.01: NAV_E
    ///      $24,493.812255 and B_E $27,038.251316 (MATH.md §9.1 lists them with illustrative fees added).
    function test_settle_payoutPath() public {
        _begin(RANGE_LOWER, RANGE_UPPER);
        _nextBlock(1 days);
        _moveToTick(-201275);
        _toEnd();

        IOathVault.EpochResult memory expected = _expected();
        uint256 idle1Before = vault.idle1();
        vm.recordLogs();
        _settleAs(keeper);
        _assertNoBondExhausted();

        IOathVault.EpochResult memory r = vault.getResult(0);
        assertEq(abi.encode(r), abi.encode(expected), "result = independent recomputation");
        assertEq(r.endTick, -201275);
        uint160 sqrtEnd = TickMath.getSqrtPriceAtTick(r.endTick);
        assertApproxEqAbs(
            r.navEnd - ValuationLib.value(r.vaultFees0, r.vaultFees1, sqrtEnd), 24_493_812_255, 10_000, "NAV_E ex fees"
        );
        assertApproxEqAbs(
            r.benchEnd - ValuationLib.value(r.benchFees0, r.benchFees1, sqrtEnd), 27_038_251_316, 10_000, "B_E ex fees"
        );
        assertLt(r.diff, -int256(r.band), "shortfall beyond the band");
        assertEq(r.payout, r.benchEnd - r.navEnd - r.band, "payout = excess shortfall");
        assertGt(r.payout, 1_000e6, "a real loss (> $1,000)");
        assertLt(r.payout, BOND, "within the bond");
        assertEq(r.fee, 0);
        assertEq(r.feeShares, 0);
        assertEq(vault.bondBalance(), BOND - r.payout, "bond reduced");
        assertEq(r.bondAfter, BOND - r.payout);
        assertEq(c1.balanceOf(address(vault)), vault.idle1() + vault.bondBalance(), "payout tokens stay in the vault");
        assertGe(vault.idle1(), idle1Before + r.payout, "payout is idle for depositors");
        assertEq(vault.balanceOf(curator), 0);
    }

    /// @dev A shortfall beyond the band larger than the bond (a 7,000-tick fall, about −50%): the whole bond is
    ///      paid and `BondExhausted` reports the uncovered rest, which stays with depositors.
    function test_settle_bondExhausted() public {
        _begin(RANGE_LOWER, RANGE_UPPER);
        _nextBlock(1 days);
        _moveToTick(START_TICK - 7_000);
        _toEnd();

        IOathVault.EpochResult memory expected = _expected();
        uint256 excess = expected.benchEnd - expected.navEnd - expected.band;
        assertGt(excess, BOND, "shortfall beyond the bond");
        vm.expectEmit(false, false, false, true, address(vault));
        emit IOathVault.BondExhausted(excess - BOND);
        _settleAs(keeper);

        IOathVault.EpochResult memory r = vault.getResult(0);
        assertEq(abi.encode(r), abi.encode(expected));
        assertEq(r.payout, BOND, "the whole bond");
        assertEq(r.bondAfter, 0);
        assertEq(vault.bondBalance(), 0);
    }

    /// @dev Flow keeps the price inside the curator's tight range, where its liquidity earns far more fees than
    ///      the passive benchmark's; the price ends where it started, so principal is unchanged. The excess beyond
    ///      the band earns the curator 20% as new shares: after minting it owns `fee / NAV_E` of the vault.
    function test_settle_feePath() public {
        _begin(RANGE_LOWER, RANGE_UPPER);
        for (uint256 i; i < 30; ++i) {
            _nextBlock(1 hours);
            _moveToTick(START_TICK - 150);
            _nextBlock(1 hours);
            _moveToTick(START_TICK + 150);
        }
        _nextBlock(1 hours);
        _moveToTick(START_TICK);
        _toEnd();

        IOathVault.EpochResult memory expected = _expected();
        uint256 supplyBefore = vault.totalSupply();
        vm.recordLogs();
        _settleAs(keeper);
        _assertNoBondExhausted();

        IOathVault.EpochResult memory r = vault.getResult(0);
        assertEq(abi.encode(r), abi.encode(expected), "result = independent recomputation");
        assertGt(r.diff, int256(r.band), "outperformance beyond the band");
        assertEq(r.fee, (uint256(r.diff) - r.band) * 2_000 / 10_000, "fee = 20% of the excess");
        assertGt(r.feeShares, 0);
        assertEq(r.payout, 0);
        assertEq(vault.bondBalance(), BOND, "bond untouched");
        assertEq(vault.balanceOf(curator), r.feeShares, "fee shares minted to the curator");
        assertEq(vault.totalSupply(), supplyBefore + r.feeShares);
        // The curator's shares are worth the fee at NAV_E, within one raw unit (MATH.md §9).
        assertApproxEqAbs(r.feeShares * r.navEnd / vault.totalSupply(), r.fee, 1, "ownership = fee / NAV_E");
    }

    /// @dev MATH.md §7 / settlement step 3 against reality: with the price at the end TWAP and no swap since `E`,
    ///      the unwind returns to the wei the principal at `sqrtP_E` plus the fees the settlement counted, so
    ///      `NAV_E` is exactly what the depositors now hold (less the bond payout, which is added on top).
    function test_settle_navEqualsRealUnwind() public {
        _begin(RANGE_LOWER, RANGE_UPPER);
        _swapAroundStart(4);
        _nextBlock(1 hours);
        _moveToTick(START_TICK - 60); // the end price, held through the whole TWAP window
        _toEnd();

        (int24 lower, int24 upper, uint128 liquidity) = vault.positionInfo();
        uint256 idle0Before = vault.idle0();
        uint256 idle1Before = vault.idle1();
        _settleAs(keeper);
        IOathVault.EpochResult memory r = vault.getResult(0);
        assertEq(r.endTick, START_TICK - 60);
        uint160 sqrtEnd = TickMath.getSqrtPriceAtTick(r.endTick);
        (uint160 spot,,,) = manager.getSlot0(key.toId());
        assertEq(spot, sqrtEnd, "spot = end TWAP");

        (uint256 p0, uint256 p1) = ValuationLib.principal(liquidity, lower, upper, sqrtEnd);
        assertGt(r.vaultFees0 + r.vaultFees1, 0, "fees counted");
        assertEq(vault.idle0() - idle0Before, p0 + r.vaultFees0, "currency0 withdrawn = principal + fees");
        assertEq(vault.idle1() - idle1Before - r.payout, p1 + r.vaultFees1, "currency1 withdrawn = principal + fees");
        assertEq(ValuationLib.value(vault.idle0(), vault.idle1() - r.payout, sqrtEnd), r.navEnd, "NAV_E to the wei");
    }

    /// @dev If the vault ended with no liquidity, the hook's snapshot of fee growth inside reads an irrelevant
    ///      range; NAV ignores it (fees and principal of zero liquidity are 0) and is the idle value at the end TWAP.
    function test_settle_zeroLiquidityIgnoresSnapshot() public {
        uint256 y = vault.idle1(); // swap all idle currency1: nothing left to pair in range, so L_v = 0
        _startEpoch(
            RANGE_LOWER,
            RANGE_UPPER,
            IOathVault.SwapIntent({
                zeroForOne: false, amountSpecified: -int256(y), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            })
        );
        startedAt = _time();
        endsAt = startedAt + 7 days;
        (,, uint128 liquidity) = vault.positionInfo();
        assertEq(liquidity, 0);
        _swapAroundStart(2);
        _toEnd();

        _settleAs(keeper);
        IOathVault.EpochResult memory r = vault.getResult(0);
        assertEq(r.vaultFees0, 0);
        assertEq(r.vaultFees1, 0);
        assertEq(
            r.navEnd,
            ValuationLib.value(vault.idle0(), vault.idle1() - r.payout, TickMath.getSqrtPriceAtTick(r.endTick)),
            "NAV_E = idle value"
        );
    }

    // ---------------------------------------------------------------- liveness

    /// @dev Anyone can settle: the curator cannot hold depositors in an epoch.
    function testFuzz_settle_byAnyone(address caller) public {
        _begin(RANGE_LOWER, RANGE_UPPER);
        _toEnd();
        _settleAs(caller);
        assertEq(uint8(vault.state()), uint8(IOathVault.State.OPEN));
        assertEq(vault.epochCount(), 1);
    }

    /// @dev The unwind is guarded: if someone moved the price more than `maxIntraBlockTicks` earlier in the
    ///      settlement block, `settle` reverts; anyone can retry in the next block. The result does not depend on
    ///      the move (both sides are marked at the end TWAP).
    function test_settle_retryNextBlock() public {
        _begin(RANGE_LOWER, RANGE_UPPER);
        _toEnd();
        _moveToTick(START_TICK + 51);
        vm.expectRevert(
            _hookError(
                IHooks.beforeRemoveLiquidity.selector,
                abi.encodeWithSelector(IOathHook.PriceMovedThisBlock.selector, START_TICK + 51, START_TICK)
            )
        );
        _settleAs(keeper);
        assertEq(uint8(vault.state()), uint8(IOathVault.State.ACTIVE), "still unsettled");

        _nextBlock(12);
        IOathVault.EpochResult memory expected = _expected();
        _settleAs(keeper);
        assertEq(abi.encode(vault.getResult(0)), abi.encode(expected));
        assertEq(vault.getResult(0).endTick, START_TICK, "marked at the TWAP, not the moved spot");
    }

    // ---------------------------------------------------------------- snapshot exactness

    /// @dev Settlement is deterministic (MATH.md §8): swaps after `E`, through the vault's range and over several
    ///      blocks, change nothing in the `EpochResult`. The first of them records the checkpoints and the snapshot
    ///      exactly as the settle-time poke would, and the vault is frozen. The fees they pay the still-deployed
    ///      position are not measured; they end up idle for the depositors (the gap belongs to them).
    function test_settle_postEpochSwapsDoNotChangeResult() public {
        _begin(RANGE_LOWER, RANGE_UPPER);
        _swapAroundStart(3);
        _toEnd();
        uint256 atEnd = vm.snapshotState();
        uint256 blockAtEnd = _block();

        // A: no swap after E; settled an hour later.
        vm.roll(blockAtEnd + 4);
        vm.warp(endsAt + 1 hours);
        _settleAs(keeper);
        IOathVault.EpochResult memory a = vault.getResult(0);
        (uint256 a0, uint256 a1) = (vault.idle0(), vault.idle1());

        // B: flow through the range right after E, back to the end price; settled at the same time.
        vm.revertToState(atEnd);
        vm.roll(blockAtEnd + 1);
        vm.warp(endsAt + 10 minutes);
        _moveToTick(START_TICK - 40);
        assertTrue(hook.epochData(key).snapTaken, "the first swap after E took the snapshot");
        vm.roll(blockAtEnd + 2);
        vm.warp(endsAt + 20 minutes);
        _moveToTick(START_TICK + 40);
        vm.roll(blockAtEnd + 3);
        vm.warp(endsAt + 30 minutes);
        _moveToTick(START_TICK);
        vm.roll(blockAtEnd + 4);
        vm.warp(endsAt + 1 hours);
        _settleAs(keeper);
        IOathVault.EpochResult memory b = vault.getResult(0);

        assertEq(abi.encode(b), abi.encode(a), "identical EpochResult");
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(START_TICK);
        assertGe(vault.idle0(), a0, "post-E fees in currency0");
        assertGe(vault.idle1(), a1, "post-E fees in currency1");
        assertGt(
            ValuationLib.value(vault.idle0(), vault.idle1(), sqrtP),
            ValuationLib.value(a0, a1, sqrtP),
            "depositors keep the post-E fees"
        );
    }

    /// @dev Spot manipulation at `E` (MATH.md §9.3): pushing the price 2,000 ticks right after `E` and holding
    ///      it through settlement changes nothing in the result, because both sides are marked at the TWAP over
    ///      `[E − W, E]`, recorded before the push.
    function test_settle_spotManipulationAtE_noEffect() public {
        _begin(RANGE_LOWER, RANGE_UPPER);
        _swapAroundStart(3);
        _toEnd();
        uint256 atEnd = vm.snapshotState();
        uint256 blockAtEnd = _block();

        vm.roll(blockAtEnd + 2);
        vm.warp(endsAt + 1 minutes);
        _settleAs(keeper);
        IOathVault.EpochResult memory honest = vault.getResult(0);

        vm.revertToState(atEnd);
        vm.roll(blockAtEnd + 1);
        vm.warp(endsAt + 12);
        _moveToTick(START_TICK + 2_000);
        vm.roll(blockAtEnd + 2);
        vm.warp(endsAt + 1 minutes);
        _settleAs(keeper);
        IOathVault.EpochResult memory pushed = vault.getResult(0);

        assertEq(_tick(), START_TICK + 2_000, "spot still pushed at settlement");
        assertEq(abi.encode(pushed), abi.encode(honest), "identical EpochResult");
        assertEq(pushed.endTick, START_TICK, "end price is the TWAP, not the pushed spot");
    }

    // ---------------------------------------------------------------- unwind and reopen

    /// @dev Settlement removes the whole position (principal and fees become idle), closes the hook's epoch and
    ///      reopens the vault with a new open window from now. It cannot settle twice, deposits and withdrawals work
    ///      again, and the next epoch can start once the new window reaches `W`.
    function test_settle_unwindsAndReopens() public {
        _begin(RANGE_LOWER, RANGE_UPPER);
        _swapAroundStart(4);
        _toEnd();
        assertGt(_poolPositionLiquidity(RANGE_LOWER, RANGE_UPPER), 0);

        // The unwind does not move the price, so the cumulative at T0 is the one readable now.
        int256 cumulativeAtSettle = hook.cumulativeNow(key);
        vm.expectEmit(false, false, false, true, address(vault));
        emit IOathVault.OpenWindowRefreshed(uint32(endsAt), cumulativeAtSettle);
        _settleAs(keeper);

        // Unwound: nothing left in the pool, everything idle (the bond untouched as tokens).
        (int24 lower, int24 upper, uint128 liquidity) = vault.positionInfo();
        assertEq(liquidity, 0, "L_v = 0");
        assertEq(lower, RANGE_LOWER, "last range kept");
        assertEq(upper, RANGE_UPPER);
        assertEq(_poolPositionLiquidity(RANGE_LOWER, RANGE_UPPER), 0, "position removed from the pool");
        assertEq(c1.balanceOf(address(vault)), vault.idle1() + vault.bondBalance());

        // Hook epoch closed; vault OPEN with T0 = now.
        assertFalse(hook.epochData(key).active, "hook epoch closed");
        assertEq(uint8(vault.state()), uint8(IOathVault.State.OPEN));
        assertEq(vault.openSince(), endsAt, "T0 = settlement time");
        assertEq(vault.cumAtOpen(), cumulativeAtSettle, "cumAtOpen = hook cumulative at T0");
        assertFalse(vault.isSettleable());
        vm.expectRevert(IOathVault.NotActive.selector);
        _settleAs(keeper);

        // Open-window actions work again.
        uint256 shares = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        vault.withdraw(shares, 0, 0, alice);
        vm.prank(curator);
        vault.withdrawBond(1);

        // And a second epoch starts after W.
        vm.warp(endsAt + 30 minutes - 1);
        vm.expectRevert(IOathVault.OpenWindowTooShort.selector);
        _startEpoch(RANGE_LOWER, RANGE_UPPER, _noSwap());
        vm.warp(endsAt + 30 minutes);
        _postBond(1);
        _startEpoch(RANGE_LOWER, RANGE_UPPER, _noSwap());
        assertEq(uint8(vault.state()), uint8(IOathVault.State.ACTIVE));
        assertTrue(hook.epochData(key).active, "hook epoch reopened");
        assertEq(vault.epochCount(), 1, "one settled epoch");
    }

    // ---------------------------------------------------------------- live preview

    /// @dev While OPEN nothing is measured: both sides are the idle NAV at spot, before the first epoch and again
    ///      after a settlement.
    function test_preview_openIsIdleNav() public {
        _assertOpenPreview();
        _begin(RANGE_LOWER, RANGE_UPPER);
        _swapAroundStart(2);
        _toEnd();
        _settleAs(keeper);
        _assertOpenPreview();
    }

    /// @dev Right after the start, at spot = start TWAP and no swaps yet, the vault and the benchmark are marked
    ///      equal up to rounding: the benchmark is below `navStart` by at most `6u` (MATH.md §6.1) and the vault's
    ///      position costs at most one raw unit of each currency to round up (`value(1, 1) + 1`).
    function test_preview_startsEqual() public {
        _begin(RANGE_LOWER, RANGE_UPPER);
        (uint256 navNow, uint256 benchNow, int256 diff) = vault.previewLive();
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(START_TICK);
        uint256 u = ValuationLib.value(1, 0, sqrtP) + 1;
        assertLe(navNow, NAV_START);
        assertLe(benchNow, NAV_START);
        assertLe(NAV_START - navNow, ValuationLib.value(1, 1, sqrtP) + 1, "vault at start");
        assertLe(NAV_START - benchNow, 6 * u, "benchmark at start");
        assertEq(diff, int256(navNow) - int256(benchNow));
    }

    /// @dev During the epoch the preview is the vault's NAV with the pool's live fee growth inside its range and
    ///      the benchmark with the live global fee growth, both at spot.
    function test_preview_activeIsLiveMark() public {
        _begin(RANGE_LOWER, RANGE_UPPER);
        _swapAroundStart(3);
        _nextBlock(1 hours);
        _moveToTick(START_TICK - 120); // spot away from the start, inside the range

        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        (uint256 in0, uint256 in1) = manager.getFeeGrowthInside(key.toId(), RANGE_LOWER, RANGE_UPPER);
        (,, uint128 liquidity) = vault.positionInfo();
        (, uint256 last0, uint256 last1) =
            manager.getPositionInfo(key.toId(), address(vault), RANGE_LOWER, RANGE_UPPER, bytes32(0));
        (uint256 navExpected, uint256 fees0,) = ValuationLib.nav(
            vault.idle0(),
            vault.idle1(),
            ValuationLib.Position(liquidity, RANGE_LOWER, RANGE_UPPER, last0, last1, in0, in1),
            sqrtP
        );
        IOathVault.Benchmark memory b;
        (b.L, b.r0, b.r1, b.G0, b.G1, b.navStart, b.startTick) = vault.benchmark();
        (uint256 g0, uint256 g1) = manager.getFeeGrowthGlobals(key.toId());
        (uint256 benchExpected,,) = BenchmarkLib.valueAt(b, g0, g1, sqrtP, TICK_SPACING);

        (uint256 navNow, uint256 benchNow, int256 diff) = vault.previewLive();
        assertGt(fees0, 0, "live fees counted");
        assertEq(navNow, navExpected, "vault live mark");
        assertEq(benchNow, benchExpected, "benchmark live mark");
        assertEq(diff, int256(navNow) - int256(benchNow));
    }

    /// @dev At `E`, with spot equal to the end TWAP and no swap since, the live mark and the settlement agree to
    ///      the wei: live fee growth at `E` is exactly the hook's snapshot.
    function test_preview_atEndEqualsSettlement() public {
        _begin(RANGE_LOWER, RANGE_UPPER);
        _swapAroundStart(3);
        _toEnd();
        (uint256 navNow, uint256 benchNow, int256 diff) = vault.previewLive();
        _settleAs(keeper);
        IOathVault.EpochResult memory r = vault.getResult(0);
        assertEq(r.endTick, START_TICK, "end TWAP = spot");
        assertEq(navNow, r.navEnd, "NAV");
        assertEq(benchNow, r.benchEnd, "benchmark");
        assertEq(diff, r.diff, "difference");
    }

    // ---------------------------------------------------------------- preconditions

    /// @dev Not before `E`: one second earlier reverts; `isSettleable` flips exactly at `E`.
    function test_settle_notBeforeEnd() public {
        _begin(RANGE_LOWER, RANGE_UPPER);
        vm.warp(endsAt - 1);
        assertFalse(vault.isSettleable());
        vm.expectRevert(IOathVault.EpochNotEnded.selector);
        _settleAs(keeper);

        vm.warp(endsAt);
        assertTrue(vault.isSettleable());
        _settleAs(keeper);
    }

    /// @dev Nothing to settle in the open window.
    function test_settle_notActive() public {
        assertFalse(vault.isSettleable());
        vm.expectRevert(IOathVault.NotActive.selector);
        _settleAs(keeper);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev No `BondExhausted` among the logs recorded since `vm.recordLogs()`.
    function _assertNoBondExhausted() internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault)) {
                assertTrue(logs[i].topics[0] != IOathVault.BondExhausted.selector, "no BondExhausted");
            }
        }
    }

    /// @dev OPEN preview: `(value(idle0, idle1, spot), same, 0)`.
    function _assertOpenPreview() internal view {
        assertEq(uint8(vault.state()), uint8(IOathVault.State.OPEN));
        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        uint256 idleNav = ValuationLib.value(vault.idle0(), vault.idle1(), sqrtP);
        assertGt(idleNav, 0);
        (uint256 navNow, uint256 benchNow, int256 diff) = vault.previewLive();
        assertEq(navNow, idleNav, "idle NAV at spot");
        assertEq(benchNow, idleNav, "benchmark = NAV while OPEN");
        assertEq(diff, 0);
    }

    /// @dev The curator starts the epoch on `[lower, upper)` without a swap.
    function _begin(int24 lower, int24 upper) internal {
        _startEpoch(lower, upper, _noSwap());
        startedAt = _time();
        endsAt = startedAt + 7 days;
    }

    /// @dev `rounds` round trips of outside flow 40 ticks either side of the start tick during the epoch, ending
    ///      exactly at the start tick well before `E − W`.
    function _swapAroundStart(uint256 rounds) internal {
        for (uint256 i; i < rounds; ++i) {
            _nextBlock(1 hours);
            _moveToTick(START_TICK - 40);
            _nextBlock(1 hours);
            _moveToTick(START_TICK + 40);
        }
        _nextBlock(1 hours);
        _moveToTick(START_TICK);
    }

    /// @dev Warps to exactly `E` in a new block.
    function _toEnd() internal {
        vm.roll(_block() + 1);
        vm.warp(endsAt);
    }

    function _settleAs(address who) internal {
        vm.prank(who);
        vault.settle();
    }

    /// @dev The `EpochResult` recomputed from raw state: the hook's checkpoints and snapshot (after a poke, which
    ///      anyone may do and which `settle` repeats harmlessly), the pool's record of the vault's position, the
    ///      vault's idle balances, benchmark, bond and supply, and the MATH.md §4–§9 formulas.
    function _expected() internal returns (IOathVault.EpochResult memory r) {
        hook.poke(key);
        IOathHook.Epoch memory e = hook.epochData(key);
        assertTrue(e.snapTaken && e.doneA && e.doneB, "hook ready");
        assertEq(e.checkpointB, endsAt);
        assertEq(e.checkpointA, endsAt - 30 minutes);

        int256 delta = e.cumB - e.cumA;
        int256 tick = delta / 1800;
        if (delta < 0 && delta % 1800 != 0) tick -= 1;
        r.endTick = int24(tick);
        uint160 sqrtEnd = TickMath.getSqrtPriceAtTick(r.endTick);

        (int24 lower, int24 upper, uint128 liquidity) = vault.positionInfo();
        (, uint256 last0, uint256 last1) = manager.getPositionInfo(key.toId(), address(vault), lower, upper, bytes32(0));
        (r.navEnd, r.vaultFees0, r.vaultFees1) = ValuationLib.nav(
            vault.idle0(),
            vault.idle1(),
            ValuationLib.Position(liquidity, lower, upper, last0, last1, e.fgIn0, e.fgIn1),
            sqrtEnd
        );

        IOathVault.Benchmark memory b;
        (b.L, b.r0, b.r1, b.G0, b.G1, b.navStart, b.startTick) = vault.benchmark();
        (r.benchEnd, r.benchFees0, r.benchFees1) = BenchmarkLib.valueAt(b, e.G0, e.G1, sqrtEnd, TICK_SPACING);

        (r.payout, r.fee, r.feeShares, r.diff, r.band) =
            SettlementLib.settle(r.navEnd, r.benchEnd, vault.bondBalance(), vault.totalSupply(), 35, 2_000);
        r.start = uint32(startedAt);
        r.end = uint32(endsAt);
        r.startTick = b.startTick;
        r.navStart = b.navStart;
        r.bondAfter = vault.bondBalance() - r.payout;
    }
}

/// @notice Settlement of a native-ETH vault: the unwind takes ETH from the PoolManager through `receive`.
contract OathVaultSettleNativeTest is OathVaultTestBase {
    function setUp() public override {
        super.setUp();
        _createVault(CurrencyLibrary.ADDRESS_ZERO);
        _seedPool(POOL_LIQUIDITY);
        _fundWorkedExample();
        _wait(1 hours);
    }

    function test_settle_nativeEth() public {
        _startEpoch(RANGE_LOWER, RANGE_UPPER, _noSwap());
        uint256 endsAt = _time() + 7 days;
        uint256 ethBefore = address(vault).balance;
        vm.roll(_block() + 1);
        vm.warp(endsAt);
        vault.settle();

        IOathVault.EpochResult memory r = vault.getResult(0);
        assertEq(uint8(vault.state()), uint8(IOathVault.State.OPEN));
        assertEq(_poolPositionLiquidity(RANGE_LOWER, RANGE_UPPER), 0, "unwound");
        assertGt(address(vault).balance, ethBefore, "ETH taken back from the pool");
        assertEq(vault.idle0(), address(vault).balance);
        assertEq(
            ValuationLib.value(vault.idle0(), vault.idle1() - r.payout, TickMath.getSqrtPriceAtTick(r.endTick)),
            r.navEnd,
            "NAV_E = what the vault holds"
        );
    }
}

/// @notice Regression (found by the invariant suite): an epoch started on a dust vault, here only a speck of
///         currency0 sent straight to the vault (start NAV of 2 raw units), has a benchmark worth 0 at `E` after
///         rounding (MATH.md §6.1, §9.2). Settlement must still complete, with no verdict, and reopen the vault;
///         it used to revert `ZeroBenchmark()` forever and leave the vault stuck ACTIVE.
contract OathVaultSettleDustTest is OathVaultTestBase {
    function setUp() public override {
        super.setUp();
        _createVault(currency0);
        _seedPool(POOL_LIQUIDITY);
    }

    function test_settle_dustVaultSettlesWithoutVerdict() public {
        _fund(c0, address(this), 1_247_579_248);
        c0.transfer(address(vault), 1_247_579_248);
        _wait(1 hours);
        _startEpoch(-200640, -197740, _noSwap());
        (,,,,, uint256 navStart,) = vault.benchmark();
        assertEq(navStart, 2, "dust start NAV");

        vm.roll(_block() + 1);
        vm.warp(vault.epochEnd());
        vault.settle();

        IOathVault.EpochResult memory r = vault.getResult(0);
        assertEq(r.benchEnd, 0, "benchmark rounds to zero");
        assertEq(r.payout, 0, "no payout");
        assertEq(r.fee, 0, "no fee");
        assertEq(r.feeShares, 0);
        assertEq(r.band, 0);
        assertEq(r.diff, int256(r.navEnd));
        assertEq(uint8(vault.state()), uint8(IOathVault.State.OPEN), "vault reopened");
    }
}
