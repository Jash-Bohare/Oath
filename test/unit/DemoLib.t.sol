// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {DemoLib} from "../../script/demo/DemoLib.sol";
import {OathVaultTestBase} from "../utils/OathVaultTestBase.sol";

/// @notice The demo scripts' pure helpers; the TWAP tick is checked against a real vault's `startEpoch`.
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
}
