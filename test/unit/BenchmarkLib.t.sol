// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BenchmarkLib} from "../../src/libraries/BenchmarkLib.sol";
import {ValuationLib} from "../../src/libraries/ValuationLib.sol";

/// @notice Pure tests for BenchmarkLib (02_MATH §6). Expected values come from the high-precision reference
///         model; the 02_MATH §9.1 inputs are real (start TWAP tick −199196, V_S = $30,000).
contract BenchmarkLibTest is Test {
    int24 internal constant SPACING = 10;
    int24 internal constant START_TICK = -199196;
    uint256 internal constant NAV_START = 30_000e6;

    function test_fullRange_spacing10() public pure {
        (int24 tickMin, int24 tickMax) = BenchmarkLib.fullRange(SPACING);
        assertEq(tickMin, -887270);
        assertEq(tickMax, 887270);
    }

    /// @dev 02_MATH §9.1: x = 6.708588 ETH (reference 6,708,587,690,738,231,160.896 wei), y = 15,000 USDC.
    function test_split_workedExample() public pure {
        (uint256 x, uint256 y) = BenchmarkLib.split(NAV_START, TickMath.getSqrtPriceAtTick(START_TICK));
        assertApproxEqRel(x, 6_708_587_690_738_231_160, 1e9);
        assertEq(y, 15_000e6);
    }

    function test_split_oddValueGivesExtraUnitToCurrency1() public pure {
        (, uint256 y) = BenchmarkLib.split(30_000e6 + 1, TickMath.getSqrtPriceAtTick(START_TICK));
        assertEq(y, 15_000e6 + 1);
    }

    /// @dev 02_MATH §9.1: L_b = 317,220,452,305,763 (reference 317,220,452,305,763.96); leftovers are dust
    ///      (reference r0 = 0, r1 = 0.0000172 raw units).
    function test_create_workedExample() public pure {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(START_TICK);
        (uint128 liquidity, uint256 r0, uint256 r1) = BenchmarkLib.create(NAV_START, sqrtP, SPACING);
        assertApproxEqRel(liquidity, 317_220_452_305_763, 1e9, "L_b");
        assertLe(ValuationLib.value(r0, r1, sqrtP), 1, "leftovers worth <= 1 raw unit ($0.000001)");
    }

    /// @dev 02_MATH §9.1 / §10: the example passes the 0.25% cap against the real pool's active liquidity
    ///      153,902,357,621,796,655 (limit ~3.85e14).
    function test_create_workedExamplePassesCap() public pure {
        (uint128 liquidity,,) = BenchmarkLib.create(NAV_START, TickMath.getSqrtPriceAtTick(START_TICK), SPACING);
        assertLe(liquidity, FullMath.mulDiv(153_902_357_621_796_655, 25, 10_000));
    }

    /// @dev Vault and benchmark start equal by construction (05_SETTLEMENT_SPEC §3): the benchmark's value
    ///      at the start price is never above V_S and below it only by rounding. Let P be the raw price and
    ///      u = value(1 wei of currency0) + 1, so u ≥ P and u ≥ sqrtP. Then x's double floor loses ≤ sqrtP + P
    ///      ≤ 2u of value, principal-vs-cost rounding ≤ u + 1, and the value floors ≤ 2, so the gap is ≤ 6u.
    function testFuzz_create_startsEqualToNavStart(uint256 navStart, int24 tick) public pure {
        navStart = bound(navStart, 1e6, 1e18); // $1 .. $1e12 in 6-decimal units
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(int24(bound(tick, -400_000, 400_000)));
        (uint128 liquidity, uint256 r0, uint256 r1) = BenchmarkLib.create(navStart, sqrtP, SPACING);
        (int24 tickMin, int24 tickMax) = BenchmarkLib.fullRange(SPACING);
        (uint256 p0, uint256 p1) = ValuationLib.principal(liquidity, tickMin, tickMax, sqrtP);

        uint256 valueAtStart = ValuationLib.value(p0 + r0, p1 + r1, sqrtP);
        uint256 u = ValuationLib.value(1, 0, sqrtP) + 1;
        assertLe(valueAtStart, navStart, "never above V_S");
        assertLe(navStart - valueAtStart, 6 * u, "gap <= 6u");
    }

    /// @dev The benchmark never spends more than the split: costs (rounded up) plus leftovers equal x and y.
    function testFuzz_create_costsWithinSplit(uint256 navStart, int24 tick) public pure {
        navStart = bound(navStart, 1e6, 1e18);
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(int24(bound(tick, -400_000, 400_000)));
        (uint256 x, uint256 y) = BenchmarkLib.split(navStart, sqrtP);
        (uint128 liquidity, uint256 r0, uint256 r1) = BenchmarkLib.create(navStart, sqrtP, SPACING);
        (int24 tickMin, int24 tickMax) = BenchmarkLib.fullRange(SPACING);
        (uint256 p0, uint256 p1) = ValuationLib.principal(liquidity, tickMin, tickMax, sqrtP);
        assertLe(p0 + r0, x + 1, "currency0 within split");
        assertLe(p1 + r1, y + 1, "currency1 within split");
    }
}
