// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BenchmarkLib} from "../../src/libraries/BenchmarkLib.sol";
import {ValuationLib} from "../../src/libraries/ValuationLib.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {OathTestBase} from "../utils/OathTestBase.sol";

/// @notice Pure tests for BenchmarkLib (02_MATH §6). Expected values come from the high-precision reference
///         model; the 02_MATH §9.1 inputs are real (start TWAP tick −199196, V_S = $30,000).
contract BenchmarkLibTest is Test {
    int24 internal constant SPACING = 10;
    int24 internal constant START_TICK = -199196;
    uint256 internal constant NAV_START = 30_000e6;
    uint256 internal constant ONE_CENT = 10_000; // $0.01 in raw USDC units

    /// @dev Real Nov 8–15 fee growth of the ETH/USDC pool (FORK_TEST_REPORT F2), used by 02_MATH §9.1.
    uint256 internal constant DG0 = 5685705715728585446726598611346846337347;
    uint256 internal constant DG1 = 10323568296605520673412669325024;

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

    // ---------------------------------------------------------------- valueAt (02_MATH §6.2)

    /// @dev 02_MATH §9.1 benchmark fees: 0.005300 ETH + 9.62 USDC (reference 5,300,369,088,004,917.41 wei
    ///      and 9,623,910.38 raw USDC).
    function test_valueAt_workedExampleFees() public pure {
        (, uint256 f0, uint256 f1) = BenchmarkLib.valueAt(_exampleBenchmark(), DG0, DG1, _sqrt(-201275), SPACING);
        assertApproxEqRel(f0, 5_300_369_088_004_917, 1e9);
        assertApproxEqRel(f1, 9_623_910, 1e9);
    }

    /// @dev Loss example: end tick −201275 ($1,816.25); B_E = $27,057.50 (reference 27,057,502,004.45 raw).
    function test_valueAt_workedExampleLoss() public pure {
        (uint256 b,,) = BenchmarkLib.valueAt(_exampleBenchmark(), DG0, DG1, _sqrt(-201275), SPACING);
        assertApproxEqAbs(b, 27_057_502_004, ONE_CENT);
    }

    /// @dev Win example: end tick −199150 ($2,246.25); B_E = $30,090.61 (reference 30,090,605,810.00 raw).
    function test_valueAt_workedExampleWin() public pure {
        (uint256 b,,) = BenchmarkLib.valueAt(_exampleBenchmark(), DG0, DG1, _sqrt(-199150), SPACING);
        assertApproxEqAbs(b, 30_090_605_810, ONE_CENT);
    }

    /// @dev Flat example: end tick −199196 ($2,235.94); B_E = $30,021.48 (reference 30,021,475,217.99 raw).
    function test_valueAt_workedExampleFlat() public pure {
        (uint256 b,,) = BenchmarkLib.valueAt(_exampleBenchmark(), DG0, DG1, _sqrt(-199196), SPACING);
        assertApproxEqAbs(b, 30_021_475_217, ONE_CENT);
    }

    /// @dev With no fee growth and no price move, the benchmark is worth its start value (within rounding).
    function test_valueAt_noGrowthNoMoveIsStartValue() public pure {
        IOathVault.Benchmark memory b = _exampleBenchmark();
        (uint256 v, uint256 f0, uint256 f1) = BenchmarkLib.valueAt(b, b.G0, b.G1, _sqrt(START_TICK), SPACING);
        assertEq(f0, 0);
        assertEq(f1, 0);
        assertApproxEqAbs(v, NAV_START, 6);
        assertLe(v, NAV_START);
    }

    /// @dev Fee growth wraps past 2^256 (02_MATH §1, 06_SECURITY T16): a start snapshot just below the wrap
    ///      gives the same fees as the unwrapped growth.
    function testFuzz_valueAt_feeGrowthWrap(uint256 g0Start, uint256 g1Start) public pure {
        IOathVault.Benchmark memory plain = _exampleBenchmark();
        IOathVault.Benchmark memory wrapped = _exampleBenchmark();
        wrapped.G0 = g0Start;
        wrapped.G1 = g1Start;
        uint256 g0End;
        uint256 g1End;
        unchecked {
            g0End = g0Start + DG0;
            g1End = g1Start + DG1;
        }
        (uint256 v1, uint256 a0, uint256 a1) = BenchmarkLib.valueAt(plain, DG0, DG1, _sqrt(-201275), SPACING);
        (uint256 v2, uint256 b0, uint256 b1) = BenchmarkLib.valueAt(wrapped, g0End, g1End, _sqrt(-201275), SPACING);
        assertEq(v1, v2);
        assertEq(a0, b0);
        assertEq(a1, b1);
    }

    function test_valueAt_feeGrowthWrapExample() public pure {
        IOathVault.Benchmark memory b = _exampleBenchmark();
        b.G0 = type(uint256).max - 41;
        b.G1 = type(uint256).max;
        (, uint256 f0, uint256 f1) = BenchmarkLib.valueAt(b, DG0 - 42, DG1 - 1, _sqrt(-201275), SPACING);
        (, uint256 e0, uint256 e1) = BenchmarkLib.valueAt(_exampleBenchmark(), DG0, DG1, _sqrt(-201275), SPACING);
        assertEq(f0, e0);
        assertEq(f1, e1);
    }

    /// @dev The 02_MATH §9.1 benchmark: created at the start tick with fee growth measured from zero.
    function _exampleBenchmark() internal pure returns (IOathVault.Benchmark memory b) {
        (b.L, b.r0, b.r1) = BenchmarkLib.create(NAV_START, _sqrt(START_TICK), SPACING);
        b.navStart = NAV_START;
        b.startTick = START_TICK;
    }

    function _sqrt(int24 tick) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }
}

/// @notice The benchmark identity on the real PoolManager (07_TEST_PLAN §2): a real full-range position of
///         `L_b`, added at the start price, withdraws exactly the principal and fees `valueAt` computes from
///         two fee-growth reads, to the wei, after any sequence of swaps and donations.
contract BenchmarkLibPoolTest is OathTestBase {
    using StateLibrary for IPoolManager;

    int24 internal constant START_TICK = -199196; // 02_MATH §9.1
    bytes32 internal constant BENCH_SALT = bytes32(uint256(7));

    PoolKey internal poolKey;

    function setUp() public override {
        super.setUp();
        poolKey = PoolKey(currency0, currency1, POOL_FEE, TICK_SPACING, IHooks(address(0)));
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(START_TICK));
        // Background: deep full range plus a concentrated band, like a real pool's layout.
        (int24 tickMin, int24 tickMax) = _fullRange();
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(tickMin, tickMax, 1e22, bytes32(uint256(1))), ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-199_800, -198_590, 1e21, bytes32(uint256(2))), ZERO_BYTES
        );
    }

    function test_valueAt_equalsRealFullRangePosition() public {
        _assertIdentity(30_000e6, 0xC0FFEE, 6, true);
    }

    function testFuzz_valueAt_equalsRealFullRangePosition(
        uint256 navStart,
        uint256 seed,
        uint8 swaps,
        bool withDonation
    ) public {
        _assertIdentity(bound(navStart, 1e6, 1e13), seed, bound(swaps, 1, 8), withDonation);
    }

    function _assertIdentity(uint256 navStart, uint256 seed, uint256 swaps, bool withDonation) internal {
        PoolId id = poolKey.toId();
        (int24 tickMin, int24 tickMax) = _fullRange();

        // Epoch start: create the benchmark at the pool price and record global fee growth.
        (uint160 sqrtStart,,,) = manager.getSlot0(id);
        IOathVault.Benchmark memory b;
        (b.L, b.r0, b.r1) = BenchmarkLib.create(navStart, sqrtStart, TICK_SPACING);
        (b.G0, b.G1) = manager.getFeeGrowthGlobals(id);

        // The real twin: the same liquidity full range. The pool charges exactly create's costs.
        int256 l = int256(uint256(b.L));
        BalanceDelta paid = modifyLiquidityNoChecks.modifyLiquidity(
            poolKey, ModifyLiquidityParams(tickMin, tickMax, l, BENCH_SALT), ZERO_BYTES
        );
        (uint256 x, uint256 y) = BenchmarkLib.split(navStart, sqrtStart);
        _assertCostMatches(uint256(uint128(-paid.amount0())), b.r0, x);
        _assertCostMatches(uint256(uint128(-paid.amount1())), b.r1, y);

        // The epoch: random swaps within ±2,000 ticks, optionally a donation.
        for (uint256 i = 0; i < swaps; i++) {
            int24 offset = int24(int256(uint256(keccak256(abi.encode(seed, i))) % 4_001) - 2_000);
            _moveTo(poolKey, TickMath.getSqrtPriceAtTick(START_TICK + offset));
            if (withDonation && i == 0) donateRouter.donate(poolKey, 1e18, 2_000e6, ZERO_BYTES);
        }

        // Epoch end: value the benchmark from two reads, then withdraw the real twin.
        (uint160 sqrtEnd,,,) = manager.getSlot0(id);
        (uint256 g0End, uint256 g1End) = manager.getFeeGrowthGlobals(id);
        (uint256 benchValue, uint256 f0, uint256 f1) = BenchmarkLib.valueAt(b, g0End, g1End, sqrtEnd, TICK_SPACING);
        assertGt(f0 + f1, 0, "fees earned");

        BalanceDelta out = modifyLiquidityNoChecks.modifyLiquidity(
            poolKey, ModifyLiquidityParams(tickMin, tickMax, -l, BENCH_SALT), ZERO_BYTES
        );
        (uint256 p0, uint256 p1) = ValuationLib.principal(b.L, tickMin, tickMax, sqrtEnd);
        uint256 out0 = uint256(uint128(out.amount0()));
        uint256 out1 = uint256(uint128(out.amount1()));
        assertEq(out0, p0 + f0, "currency0: principal + fees, to the wei");
        assertEq(out1, p1 + f1, "currency1: principal + fees, to the wei");
        assertEq(benchValue, ValuationLib.value(out0 + b.r0, out1 + b.r1, sqrtEnd), "B_E = real position + leftovers");
    }

    /// @dev If the pool charged no more than the split, the leftover is exactly the rest of the split.
    function _assertCostMatches(uint256 charged, uint256 leftover, uint256 available) internal pure {
        if (charged <= available) assertEq(charged + leftover, available, "leftover = split - real cost");
        else assertEq(leftover, 0, "no leftover when cost exceeds split");
    }
}
