// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {BenchmarkLib} from "../../src/libraries/BenchmarkLib.sol";
import {ValuationLib} from "../../src/libraries/ValuationLib.sol";
import {DemoCurator} from "../../script/demo/DemoCurator.sol";
import {DemoLib} from "../../script/demo/DemoLib.sol";
import {OathVaultTestBase} from "../utils/OathVaultTestBase.sol";

/// @notice The demo scripts' helpers. The curator's ratio swap runs through a real vault's `startEpoch` and
///         `rebalance` on the real PoolManager, with the hook's intra-block guard.
contract DemoLibTest is OathVaultTestBase {
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------- twapTick

    function test_twapTick_floorsTowardNegativeInfinity() public pure {
        assertEq(DemoLib.twapTick(7, 2), 3);
        assertEq(DemoLib.twapTick(-7, 2), -4);
        assertEq(DemoLib.twapTick(-6, 2), -3);
        assertEq(DemoLib.twapTick(0, 5), 0);
        assertEq(DemoLib.twapTick(int256(START_TICK) * 1800, 1800), START_TICK);
        assertEq(DemoLib.twapTick(int256(START_TICK) * 1800 + 1, 1800), START_TICK);
        assertEq(DemoLib.twapTick(int256(START_TICK) * 1800 - 1, 1800), START_TICK - 1);
    }

    function testFuzz_twapTick_isFloor(int256 delta, uint256 elapsed) public pure {
        elapsed = bound(elapsed, 1, 365 days);
        int256 limit = int256(uint256(int256(TickMath.MAX_TICK))) * int256(elapsed);
        delta = bound(delta, -limit, limit);
        int256 tick = DemoLib.twapTick(delta, elapsed);
        assertLe(tick * int256(elapsed), delta, "tick . dt <= delta");
        assertGt((tick + 1) * int256(elapsed), delta, "(tick + 1) . dt > delta");
    }

    /// @dev The vault computes the same start tick: an open window with a known cumulative.
    function test_twapTick_matchesVaultStartTick() public {
        _createVault(currency0, _demoParams());
        _seedPool(POOL_LIQUIDITY);
        _fundWorkedExample();
        _nextBlock(10 minutes);
        _moveToTick(START_TICK - 37);
        _nextBlock(20 minutes);
        int24 expected = DemoLib.twapTick(hook.cumulativeNow(key) - vault.cumAtOpen(), _time() - vault.openSince());
        _startEpoch(RANGE_LOWER, RANGE_UPPER, _noSwap());
        (,,,,,, int24 startTick) = vault.benchmark();
        assertEq(startTick, expected);
        assertEq(expected, DemoLib.twapTick(int256(START_TICK) * 600 + int256(START_TICK - 37) * 1200, 1800));
    }

    // ---------------------------------------------------------------- rangeAround

    function test_rangeAround_floorsCentreToSpacing() public pure {
        (int24 lower, int24 upper) = DemoLib.rangeAround(START_TICK, 200, TICK_SPACING);
        assertEq(lower, RANGE_LOWER, "MATH.md 9.1 range");
        assertEq(upper, RANGE_UPPER);
        (lower, upper) = DemoLib.rangeAround(-199190, 300, TICK_SPACING);
        assertEq(lower, -199490);
        assertEq(upper, -198890);
        (lower, upper) = DemoLib.rangeAround(15, 3000, TICK_SPACING);
        assertEq(lower, -2990);
        assertEq(upper, 3010);
        (lower, upper) = DemoLib.rangeAround(-1, 200, TICK_SPACING);
        assertEq(lower, -210);
        assertEq(upper, 190);
    }

    function testFuzz_rangeAround(int24 tick, uint8 halfSpacings) public pure {
        tick = int24(bound(tick, TickMath.MIN_TICK + 30_000, TickMath.MAX_TICK - 30_000));
        int24 halfWidth = int24(uint24(bound(halfSpacings, 1, 255))) * TICK_SPACING;
        (int24 lower, int24 upper) = DemoLib.rangeAround(tick, halfWidth, TICK_SPACING);
        int24 centre = lower + halfWidth;
        assertEq(upper - lower, 2 * halfWidth, "width");
        assertEq(lower % TICK_SPACING, 0, "lower on spacing");
        assertEq(upper % TICK_SPACING, 0, "upper on spacing");
        assertLe(centre, tick, "centre <= tick");
        assertGt(centre + TICK_SPACING, tick, "tick < centre + spacing");
    }

    // ---------------------------------------------------------------- formatting

    function test_usd_roundsHalfUpToCents() public pure {
        assertEq(DemoLib.usd(0), "0.00");
        assertEq(DemoLib.usd(4_999), "0.00");
        assertEq(DemoLib.usd(5_000), "0.01");
        assertEq(DemoLib.usd(90_000), "0.09");
        assertEq(DemoLib.usd(1_234_999), "1.23");
        assertEq(DemoLib.usd(1_235_000), "1.24");
        assertEq(DemoLib.usd(30_000e6), "30000.00");
        assertEq(DemoLib.usd(351_970_000), "351.97");
        assertEq(DemoLib.usd(999_995_000), "1000.00");
    }

    function test_usdSigned() public pure {
        assertEq(DemoLib.usdSigned(0), "0.00");
        assertEq(DemoLib.usdSigned(-4_999), "0.00", "no negative zero");
        assertEq(DemoLib.usdSigned(-5_000), "-0.01");
        assertEq(DemoLib.usdSigned(-454_710_000), "-454.71");
        assertEq(DemoLib.usdSigned(454_705_000), "454.71");
        assertEq(DemoLib.usdSigned(-454_705_000), "-454.71");
    }

    /// @dev The real pool's B0 price (MATH.md §9.1): $2,236.09 per ETH.
    function test_price_b0() public pure {
        assertEq(DemoLib.usd(DemoLib.price(3746491021442836852256695)), "2236.09");
        assertEq(DemoLib.price(uint160(1 << 96)), 1e18, "price 1 raw unit per raw unit");
    }

    // ---------------------------------------------------------------- guardedLimit

    function test_guardedLimit_stopsInsideTheGuard() public pure {
        assertEq(DemoLib.guardedLimit(START_TICK, true, 50), TickMath.getSqrtPriceAtTick(START_TICK - 49));
        assertEq(DemoLib.guardedLimit(START_TICK, false, 50), TickMath.getSqrtPriceAtTick(START_TICK + 49));
        assertEq(DemoLib.guardedLimit(-5, false, 1), TickMath.getSqrtPriceAtTick(-5));
    }

    // ---------------------------------------------------------------- DemoCurator

    /// @dev Lopsided holdings (90% of the value in ETH) go into a ±200 range almost entirely with the ratio swap;
    ///      without a swap, over half the value would sit idle. The bisection stops at 1 ppm of the surplus, so
    ///      cents at most stay idle.
    function test_curator_startPutsHoldingsInRange() public {
        _lopsidedVault(POOL_LIQUIDITY);
        uint256 snapshot = vm.snapshotState();
        _startEpoch(RANGE_LOWER, RANGE_UPPER, _noSwap());
        assertGt(_idleValue(), 15_000e6, "without a swap, over half the value stays idle");
        vm.revertToState(snapshot);

        IOathVault.SwapIntent memory s = DemoCurator.startEpoch(vault, RANGE_LOWER, RANGE_UPPER);
        assertTrue(s.zeroForOne, "sells ETH");
        assertEq(s.sqrtPriceLimitX96, DemoLib.guardedLimit(START_TICK, true, 50), "guarded limit");
        assertLt(_idleValue(), 0.1e6, "under $0.10 of $30,000 stays idle");
        assertEq(uint8(vault.state()), uint8(IOathVault.State.ACTIVE));
    }

    /// @dev The dry runs leave no trace: the result equals one direct `startEpoch` with the chosen swap, down to
    ///      the hook's oracle.
    function test_curator_dryRunsLeaveNoTrace() public {
        _lopsidedVault(POOL_LIQUIDITY);
        uint256 snapshot = vm.snapshotState();
        IOathVault.SwapIntent memory s = DemoCurator.startEpoch(vault, RANGE_LOWER, RANGE_UPPER);
        bytes memory viaCurator = _fingerprint();
        vm.revertToState(snapshot);
        _startEpoch(RANGE_LOWER, RANGE_UPPER, s);
        assertEq(_fingerprint(), viaCurator);
    }

    /// @dev Almost no liquidity beyond a narrow band that cannot absorb the whole sale: an unlimited swap of the
    ///      same size would run the price far past the guard's 50 ticks and the vault's add would revert. The guarded limit stops at 49 ticks, so the start
    ///      succeeds and the unfilled part stays idle.
    function test_curator_limitKeepsTheGuard() public {
        _createVault(currency0, _demoParams());
        _seedPool(POOL_LIQUIDITY / 1_000_000);
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams(START_TICK - 24, START_TICK + 26, int256(POOL_LIQUIDITY), bytes32(0)), ""
        );
        _depositLopsided();
        _postBond(BOND);
        _nextBlock(1 hours);

        uint256 snapshot = vm.snapshotState();
        IOathVault.SwapIntent memory s = DemoCurator.startEpoch(vault, RANGE_LOWER, RANGE_UPPER);
        int24 tickAfter = _tick();
        uint128 liquidity = vault.positionLiquidity();
        vm.revertToState(snapshot);
        IOathVault.SwapIntent memory unlimited =
            IOathVault.SwapIntent(true, s.amountSpecified, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectPartialRevert(CustomRevert.WrappedError.selector); // the hook's PriceMovedThisBlock on the add
        _startEpoch(RANGE_LOWER, RANGE_UPPER, unlimited);

        assertGe(tickAfter, START_TICK - 50, "own impact within the guard");
        assertLt(tickAfter, START_TICK - 40, "stopped near the limit");
        assertGt(liquidity, 0, "position opened");
    }

    /// @dev After the price leaves the range, the rebalance recentres with a ratio swap that sells the side the old
    ///      position turned into.
    function test_curator_rebalanceRecentres() public {
        _createVault(currency0, _demoParams());
        _seedPool(POOL_LIQUIDITY);
        _fundWorkedExample();
        _nextBlock(1 hours);
        DemoCurator.startEpoch(vault, RANGE_LOWER, RANGE_UPPER);
        _nextBlock(1 hours);
        _moveToTick(RANGE_LOWER - 300); // below the range: the position is all ETH
        _nextBlock(1 hours);

        (int24 lower, int24 upper) = DemoLib.rangeAround(_tick(), 300, TICK_SPACING);
        IOathVault.SwapIntent memory s = DemoCurator.rebalance(vault, lower, upper);
        assertTrue(s.zeroForOne, "sells ETH");
        (int24 l, int24 u, uint128 liquidity) = vault.positionInfo();
        assertEq(l, lower);
        assertEq(u, upper);
        assertGt(liquidity, 0);
        assertLt(_idleValue(), 0.1e6, "under $0.10 stays idle");
    }

    // ---------------------------------------------------------------- helpers

    /// @dev A demo vault on a pool with `poolLiquidity` full range, holding $27,000 of currency0 and $3,000 of
    ///      currency1 with the $3,000 bond, its open window ready.
    function _lopsidedVault(uint256 poolLiquidity) internal {
        _createVault(currency0, _demoParams());
        _seedPool(poolLiquidity);
        _depositLopsided();
        _postBond(BOND);
        _nextBlock(1 hours);
    }

    /// @dev Alice deposits $27,000 of currency0 and $3,000 of currency1 at the start tick.
    function _depositLopsided() internal {
        (uint256 x,) = BenchmarkLib.split(54_000e6, TickMath.getSqrtPriceAtTick(START_TICK));
        _give(alice, x, 3_000e6);
        _deposit(alice, x, 3_000e6);
    }

    /// @dev Everything a reposition changes: the vault's position and balances, the pool price, the hook oracle.
    function _fingerprint() internal view returns (bytes memory) {
        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        (int24 lower, int24 upper, uint128 liquidity) = vault.positionInfo();
        (uint128 benchL,,,,, uint256 navStart, int24 startTick) = vault.benchmark();
        (uint32 lastTimestamp, uint64 lastSwapBlock, int24 blockStartTick, int256 cumulative) = hook.oracles(key.toId());
        return bytes.concat(
            abi.encode(lower, upper, liquidity, vault.idle0(), vault.idle1(), vault.lastReposition()),
            abi.encode(benchL, navStart, startTick, sqrtP),
            abi.encode(lastTimestamp, lastSwapBlock, blockStartTick, cumulative)
        );
    }

    function _idleValue() internal view returns (uint256) {
        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        return ValuationLib.value(vault.idle0(), vault.idle1(), sqrtP);
    }
}
