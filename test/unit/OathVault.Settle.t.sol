// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
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
