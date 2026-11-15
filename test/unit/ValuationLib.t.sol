// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {ValuationLib} from "../../src/libraries/ValuationLib.sol";

/// @notice Pure unit tests for ValuationLib (02_MATH §2, §3). Expected values come from the high-precision
///         reference model (02_MATH, exact powers of 1.0001); the contract uses TickMath, so they agree to
///         a relative 1e-9 or better.
contract ValuationLibTest is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 2^96
    int24 internal constant T_LO = -199400; // 02_MATH §9.1 curator range
    int24 internal constant T_HI = -199000;
    uint128 internal constant L = 1e16;

    // ---------------------------------------------------------------- value (02_MATH §2)

    function test_value_atPriceOneIsSum() public pure {
        assertEq(ValuationLib.value(123e18, 456e6, SQRT_PRICE_1_1), 123e18 + 456e6);
    }

    function test_value_onlyCurrency1() public pure {
        assertEq(ValuationLib.value(0, 777, TickMath.getSqrtPriceAtTick(-199196)), 777);
    }

    /// @dev 1 ETH at the §9.1 start tick −199196 is $2,235.94 (reference: 2,235,940,065.404 raw USDC).
    function test_value_oneEthAtStartTick() public pure {
        uint256 v = ValuationLib.value(1e18, 0, TickMath.getSqrtPriceAtTick(-199196));
        assertApproxEqRel(v, 2_235_940_065, 1e9, "rel 1e-9");
        assertApproxEqAbs(v, 2_235_940_065, 1, "abs 1 raw unit");
    }

    function testFuzz_value_additiveInCurrency1(uint256 a0, uint256 a1, int24 tick) public pure {
        a0 = bound(a0, 0, type(uint128).max);
        a1 = bound(a1, 0, type(uint128).max);
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(int24(bound(tick, -400_000, 400_000)));
        assertEq(ValuationLib.value(a0, a1, sqrtP), ValuationLib.value(a0, 0, sqrtP) + a1);
    }

    function testFuzz_value_monotoneInPrice(uint256 a0, int24 tick) public pure {
        a0 = bound(a0, 0, type(uint128).max);
        int24 t = int24(bound(tick, -400_000, 399_999));
        uint256 lo = ValuationLib.value(a0, 0, TickMath.getSqrtPriceAtTick(t));
        uint256 hi = ValuationLib.value(a0, 0, TickMath.getSqrtPriceAtTick(t + 1));
        assertLe(lo, hi);
    }

    /// @dev 1,000 random (a0, a1, tick) points from the reference model (07_TEST_PLAN §2), generated with
    ///      a fixed seed: ticks in [−250000, −150000], a0 ≤ 1e22, a1 ≤ 1e12. Relative error ≤ 1e-9.
    function test_value_matchesReferenceVectors() public view {
        string memory json = vm.readFile("test/vectors/valuation.json");
        assertTrue(vm.keyExistsJson(json, ".[999]") && !vm.keyExistsJson(json, ".[1000]"), "exactly 1,000");
        for (uint256 i = 0; i < 1_000; i++) {
            string memory at = string.concat(".[", vm.toString(i), "]");
            uint256 got = ValuationLib.value(
                vm.parseJsonUint(json, string.concat(at, ".a0")),
                vm.parseJsonUint(json, string.concat(at, ".a1")),
                TickMath.getSqrtPriceAtTick(int24(vm.parseJsonInt(json, string.concat(at, ".tick"))))
            );
            assertApproxEqRel(got, vm.parseJsonUint(json, string.concat(at, ".value")), 1e9, vm.toString(i));
        }
    }

    // ---------------------------------------------------------------- principal (02_MATH §3)

    /// @dev Below the range: all currency0. Reference: 4,230,310,983,057,256,891.706 wei.
    function test_principal_belowRange() public pure {
        (uint256 a0, uint256 a1) = ValuationLib.principal(L, T_LO, T_HI, TickMath.getSqrtPriceAtTick(-199500));
        assertApproxEqRel(a0, 4_230_310_983_057_256_891, 1e9);
        assertEq(a1, 0);
    }

    /// @dev Inside the range. Reference: 2,062,282,155,831,537,219.960 wei and 4,798,390,939.122 raw USDC.
    function test_principal_insideRange() public pure {
        (uint256 a0, uint256 a1) = ValuationLib.principal(L, T_LO, T_HI, TickMath.getSqrtPriceAtTick(-199196));
        assertApproxEqRel(a0, 2_062_282_155_831_537_219, 1e9);
        assertApproxEqRel(a1, 4_798_390_939, 1e9);
    }

    /// @dev Above the range: all currency1. Reference: 9,454,939,273.094 raw USDC.
    function test_principal_aboveRange() public pure {
        (uint256 a0, uint256 a1) = ValuationLib.principal(L, T_LO, T_HI, TickMath.getSqrtPriceAtTick(-198900));
        assertEq(a0, 0);
        assertApproxEqRel(a1, 9_454_939_273, 1e9);
    }

    /// @dev At exactly the lower bound the position is all currency0; at exactly the upper bound all currency1.
    function test_principal_atBoundaries() public pure {
        (uint256 a0, uint256 a1) = ValuationLib.principal(L, T_LO, T_HI, TickMath.getSqrtPriceAtTick(T_LO));
        assertGt(a0, 0);
        assertEq(a1, 0);
        (a0, a1) = ValuationLib.principal(L, T_LO, T_HI, TickMath.getSqrtPriceAtTick(T_HI));
        assertEq(a0, 0);
        assertGt(a1, 0);
    }

    function test_principal_zeroLiquidity() public pure {
        (uint256 a0, uint256 a1) = ValuationLib.principal(0, T_LO, T_HI, TickMath.getSqrtPriceAtTick(-199196));
        assertEq(a0, 0);
        assertEq(a1, 0);
    }

    /// @dev Rounding direction (02_MATH §1): principal rounds down, so it is at most 1 wei below the
    ///      round-up amounts the pool charges to add the same liquidity, per token.
    function testFuzz_principal_roundsDownByAtMostOneWei(uint128 liquidity, int24 lower, int24 width, int24 tick)
        public
        pure
    {
        liquidity = uint128(bound(liquidity, 1, type(uint64).max) * 1e6);
        int24 tA = int24(bound(lower, -800_000, 790_000));
        int24 tB = tA + int24(bound(width, 1, 10_000));
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(int24(bound(tick, tA - 20_000, tB + 20_000)));
        uint160 sA = TickMath.getSqrtPriceAtTick(tA);
        uint160 sB = TickMath.getSqrtPriceAtTick(tB);

        (uint256 a0, uint256 a1) = ValuationLib.principal(liquidity, tA, tB, sqrtP);

        uint160 s0 = sqrtP < sA ? sA : (sqrtP > sB ? sB : sqrtP);
        uint256 up0 = SqrtPriceMath.getAmount0Delta(s0, sB, liquidity, true);
        uint256 up1 = SqrtPriceMath.getAmount1Delta(sA, s0, liquidity, true);
        assertLe(a0, up0);
        assertLe(a1, up1);
        assertLe(up0 - a0, 1);
        assertLe(up1 - a1, 1);
    }
}
