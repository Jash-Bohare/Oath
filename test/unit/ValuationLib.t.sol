// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {ValuationLib} from "../../src/libraries/ValuationLib.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {OathTestBase} from "../utils/OathTestBase.sol";

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

    // ---------------------------------------------------------------- fees and NAV (02_MATH §7)

    function test_feesOwed_basic() public pure {
        // 1 unit of growth per liquidity (2^128) over L = 1e16 owes exactly 1e16.
        assertEq(ValuationLib.feesOwed(1e16, 0, 1 << 128), 1e16);
        assertEq(ValuationLib.feesOwed(1e16, 5, 5), 0);
    }

    /// @dev Fee growth may wrap past 2^256; the unchecked difference still gives the true growth.
    function testFuzz_feesOwed_wrapsLikeV4(uint128 liquidity, uint256 last, uint128 growth) public pure {
        uint256 mark;
        unchecked {
            mark = last + growth;
        }
        assertEq(ValuationLib.feesOwed(liquidity, last, mark), ValuationLib.feesOwed(liquidity, 0, growth));
    }

    function test_feesOwed_wrapExample() public pure {
        assertEq(ValuationLib.feesOwed(1 << 64, type(uint256).max - 5, 10), 16 * (1 << 64) >> 128);
        assertEq(ValuationLib.feesOwed(1 << 127, type(uint256).max, 1), 1);
    }

    /// @dev With no position, NAV is just the idle tokens' value.
    function test_nav_idleOnly() public pure {
        ValuationLib.Position memory none;
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(-199196);
        (uint256 navValue, uint256 f0, uint256 f1) = ValuationLib.nav(1e18, 500e6, none, sqrtP);
        assertEq(navValue, ValuationLib.value(1e18, 500e6, sqrtP));
        assertEq(f0, 0);
        assertEq(f1, 0);
    }
}

/// @notice ValuationLib against the real PoolManager (07_TEST_PLAN §2): `principal` equals the amounts a
///         real withdrawal returns, to the wei, below, inside and above the range and at both boundaries.
contract ValuationLibPoolTest is OathTestBase {
    using StateLibrary for IPoolManager;

    int24 internal constant START_TICK = -199196; // 02_MATH §9.1
    bytes32 internal constant BACKGROUND_SALT = bytes32(uint256(1));
    bytes32 internal constant POSITION_SALT = bytes32(uint256(2));

    PoolKey internal poolKey;

    function setUp() public override {
        super.setUp();
        // A plain pool (no hook) with the demo fee and spacing: ValuationLib does not depend on the hook.
        poolKey = PoolKey(currency0, currency1, POOL_FEE, TICK_SPACING, IHooks(address(0)));
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(START_TICK));
        // Deep full-range background liquidity so swaps can move the price anywhere we need.
        (int24 tickMin, int24 tickMax) = _fullRange();
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(tickMin, tickMax, 1e22, BACKGROUND_SALT), ZERO_BYTES
        );
    }

    function test_principal_equalsWithdrawalBelowRange() public {
        _assertPrincipalEqualsWithdrawal(-199400, -199000, 1e16, TickMath.getSqrtPriceAtTick(-199900));
    }

    function test_principal_equalsWithdrawalInsideRange() public {
        _assertPrincipalEqualsWithdrawal(-199400, -199000, 1e16, TickMath.getSqrtPriceAtTick(-199123) + 12_345);
    }

    function test_principal_equalsWithdrawalAboveRange() public {
        _assertPrincipalEqualsWithdrawal(-199400, -199000, 1e16, TickMath.getSqrtPriceAtTick(-198500));
    }

    /// @dev Price exactly at the lower bound, reached by a downward swap (pool tick = tA − 1).
    function test_principal_equalsWithdrawalAtLowerBoundFromAbove() public {
        _assertPrincipalEqualsWithdrawal(-199400, -199000, 1e16, TickMath.getSqrtPriceAtTick(-199400));
    }

    /// @dev Price exactly at the lower bound, reached by an upward swap (pool tick = tA).
    function test_principal_equalsWithdrawalAtLowerBoundFromBelow() public {
        _moveTo(TickMath.getSqrtPriceAtTick(-199600));
        _assertPrincipalEqualsWithdrawal(-199400, -199000, 1e16, TickMath.getSqrtPriceAtTick(-199400));
    }

    function test_principal_equalsWithdrawalAtUpperBound() public {
        _assertPrincipalEqualsWithdrawal(-199400, -199000, 1e16, TickMath.getSqrtPriceAtTick(-199000));
    }

    function testFuzz_principal_equalsWithdrawal(uint128 liquidity, int24 lower, int24 width, uint256 priceSeed)
        public
    {
        liquidity = uint128(bound(liquidity, 1e6, 1e20));
        int24 tA = int24(bound(lower, -202_000, -197_000)) / TICK_SPACING * TICK_SPACING;
        int24 tB = tA + int24(bound(width, 1, 400)) * TICK_SPACING;
        uint160 sqrtP =
            uint160(bound(priceSeed, TickMath.getSqrtPriceAtTick(tA - 1_000), TickMath.getSqrtPriceAtTick(tB + 1_000)));
        _assertPrincipalEqualsWithdrawal(tA, tB, liquidity, sqrtP);
    }

    /// @dev Moves the pool to `sqrtP`, adds liquidity on [tA, tB), removes it immediately (no swaps in
    ///      between, so no fees) and checks the received amounts against `principal` at the pool price.
    function _assertPrincipalEqualsWithdrawal(int24 tA, int24 tB, uint128 liquidity, uint160 sqrtP) internal {
        _moveTo(sqrtP);
        (uint160 poolSqrtP,,,) = manager.getSlot0(poolKey.toId());
        assertEq(poolSqrtP, sqrtP, "pool at target price");

        int256 l = int256(uint256(liquidity));
        modifyLiquidityNoChecks.modifyLiquidity(poolKey, ModifyLiquidityParams(tA, tB, l, POSITION_SALT), ZERO_BYTES);
        BalanceDelta out = modifyLiquidityNoChecks.modifyLiquidity(
            poolKey, ModifyLiquidityParams(tA, tB, -l, POSITION_SALT), ZERO_BYTES
        );

        (uint256 p0, uint256 p1) = ValuationLib.principal(liquidity, tA, tB, poolSqrtP);
        assertEq(int256(out.amount0()), int256(p0), "amount0 to the wei");
        assertEq(int256(out.amount1()), int256(p1), "amount1 to the wei");
    }

    /// @dev NAV with uncollected fees (02_MATH §7): after swaps through the position, principal plus
    ///      `feesOwed` (fee growth inside since the last collection) equals what a real withdrawal pays.
    function test_nav_feesAndPrincipalEqualWithdrawal() public {
        _assertNavEqualsWithdrawal(-199400, -199000, 1e17, 4);
    }

    function testFuzz_nav_feesAndPrincipalEqualWithdrawal(uint128 liquidity, int24 lower, int24 width, uint8 swaps)
        public
    {
        // Down to L = 1e14 (the 02_MATH §9.1 curator position is ~3.1e16): smaller positions earn < 1 wei of
        // currency1 fees per crossing, which v4 correctly rounds to 0, so "earned fees" would not be testable.
        liquidity = uint128(bound(liquidity, 1e14, 1e20));
        int24 tA = int24(bound(lower, -200_000, -198_400)) / TICK_SPACING * TICK_SPACING;
        int24 tB = tA + int24(bound(width, 1, 200)) * TICK_SPACING;
        _assertNavEqualsWithdrawal(tA, tB, liquidity, bound(swaps, 2, 8));
    }

    /// @dev Adds a position, swaps back and forth across it (alternately to start − 1,500 and start + 3,500
    ///      ticks, which crosses every range the tests use), then compares `nav` with a real withdrawal.
    function _assertNavEqualsWithdrawal(int24 tA, int24 tB, uint128 liquidity, uint256 swaps) internal {
        int256 l = int256(uint256(liquidity));
        modifyLiquidityNoChecks.modifyLiquidity(poolKey, ModifyLiquidityParams(tA, tB, l, POSITION_SALT), ZERO_BYTES);
        for (uint256 i = 0; i < swaps; i++) {
            _moveTo(TickMath.getSqrtPriceAtTick(START_TICK + (i % 2 == 0 ? int24(-1_500) : int24(3_500))));
        }
        (uint160 sqrtP,,,) = manager.getSlot0(poolKey.toId());

        PoolId id = poolKey.toId();
        ValuationLib.Position memory pos;
        pos.liquidity = liquidity;
        pos.tickLower = tA;
        pos.tickUpper = tB;
        (, pos.feeGrowthInside0Last, pos.feeGrowthInside1Last) =
            manager.getPositionInfo(id, address(modifyLiquidityNoChecks), tA, tB, POSITION_SALT);
        (pos.feeGrowthInside0Mark, pos.feeGrowthInside1Mark) = manager.getFeeGrowthInside(id, tA, tB);
        (uint256 navValue, uint256 f0, uint256 f1) = ValuationLib.nav(0, 0, pos, sqrtP);
        assertGt(f0 + f1, 0, "swaps earned fees");

        BalanceDelta out = modifyLiquidityNoChecks.modifyLiquidity(
            poolKey, ModifyLiquidityParams(tA, tB, -l, POSITION_SALT), ZERO_BYTES
        );
        (uint256 p0, uint256 p1) = ValuationLib.principal(liquidity, tA, tB, sqrtP);
        assertEq(int256(out.amount0()), int256(p0 + f0), "amount0 = principal0 + fees0, to the wei");
        assertEq(int256(out.amount1()), int256(p1 + f1), "amount1 = principal1 + fees1, to the wei");
        assertEq(navValue, ValuationLib.value(uint128(out.amount0()), uint128(out.amount1()), sqrtP), "nav");
    }

    /// @dev Swaps exact-input against the background liquidity until the price is exactly `target`.
    function _moveTo(uint160 target) internal {
        (uint160 current,,,) = manager.getSlot0(poolKey.toId());
        if (current == target) return;
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: target < current, amountSpecified: -1e40, sqrtPriceLimitX96: target}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }
}
