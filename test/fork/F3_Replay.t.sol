// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {BenchmarkLib} from "../../src/libraries/BenchmarkLib.sol";
import {ValuationLib} from "../../src/libraries/ValuationLib.sol";
import {ForkBase} from "./ForkBase.sol";

/// @notice F3: the hypothetical benchmark against a real full-range position on real flow: the first 500 mainnet
///         swaps after B0, replayed from the same B0 state in two worlds (MATH.md §13).
///         - World 1: the vault's capital sits in a ±200-tick curator range. The benchmark is computed the Oath way,
///           from world-1 pool state: `BenchmarkLib.create` at B0 and `BenchmarkLib.valueAt` with world-1 fee
///           growth and end price.
///         - World 2: the same capital is a real full-range position of the benchmark's `L_b`, poked and withdrawn
///           after the same swaps.
///         Two flow models: price-anchored (each swap moves the pool to the recorded post-swap price: arbitrage
///         flow) and amount-anchored (each swap pays the recorded input amount: fixed-size flow).
///         Pass criterion (unchanged from the feasibility study): price-anchored, up to 1% of TVL, total-value error
///         ≤ 25 bps. At those sizes the benchmark's fees also equal the real position's to the wei. Amount-anchored
///         at 1% of TVL must stay within the 35 bps band this error sets (MATH.md §9.3).
contract F3ReplayForkTest is ForkBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant SWAPS = 500;

    PoolModifyLiquidityTest internal lpRouter;
    PoolSwapTest internal swapRouter;
    int256[] internal amount0;
    int256[] internal amount1;
    uint256[] internal prices;
    uint256 internal tvl;
    int24 internal lower;
    int24 internal upper;

    struct Result {
        uint160 sqrtEnd1;
        uint160 sqrtEnd2;
        uint256 benchEnd;
        uint256 benchFees0;
        uint256 benchFees1;
        uint256 realEnd;
        uint256 realFees0;
        uint256 realFees1;
        uint256 misses;
    }

    function setUp() public {
        _fork(B0);
        (lpRouter, swapRouter) = _routers();
        string memory swaps = vm.readFile(string.concat(vm.projectRoot(), SWAPS_FILE));
        int256[] memory a0 = vm.parseJsonIntArray(swaps, ".amount0");
        int256[] memory a1 = vm.parseJsonIntArray(swaps, ".amount1");
        uint256[] memory p = vm.parseJsonUintArray(swaps, ".sqrtPriceX96");
        assertEq(vm.parseJsonUint(swaps, ".fromBlock"), B0, "swaps start at B0");
        assertGe(a0.length, SWAPS);
        for (uint256 i; i < SWAPS; ++i) {
            amount0.push(a0[i]);
            amount1.push(a1[i]);
            prices.push(p[i]);
        }
        string memory layout = vm.readFile(string.concat(vm.projectRoot(), LAYOUT_FILE));
        assertEq(vm.parseJsonUint(layout, ".block"), B0, "layout at B0");
        tvl = vm.parseJsonUint(layout, ".tvlUSDCunits");

        (, int24 tick,,) = MANAGER.getSlot0(realId);
        int24 center = tick / SPACING * SPACING;
        if (tick < 0 && tick % SPACING != 0) center -= SPACING;
        (lower, upper) = (center - 200, center + 200);
    }

    // ---------------------------------------------------------------- cases

    function test_F3_price_0p1pct() public {
        Result memory r = _run(10, true);
        _assertPriceAnchored(r);
    }

    function test_F3_price_1pct() public {
        Result memory r = _run(100, true);
        _assertPriceAnchored(r);
    }

    function test_F3_price_10pct() public {
        Result memory r = _run(1_000, true);
        assertEq(r.misses, 0, "every recorded price reached");
    }

    function test_F3_amount_0p1pct() public {
        _run(10, false);
    }

    function test_F3_amount_1pct() public {
        Result memory r = _run(100, false);
        assertLe(_bps100(r.benchEnd, r.realEnd), 3_500, "fixed-size flow at 1% of TVL: within the 35 bps band");
    }

    function test_F3_amount_10pct() public {
        _run(1_000, false);
    }

    /// @dev The recorded data's sign convention: exactly one side paid in, and the price moves the way it implies.
    function test_F3_signConventionOnRecordedData() public view {
        (uint160 previous,,,) = MANAGER.getSlot0(realId);
        for (uint256 i; i < SWAPS; ++i) {
            bool zeroForOne = amount0[i] < 0;
            assertTrue(zeroForOne ? amount1[i] >= 0 : (amount1[i] < 0 && amount0[i] >= 0), "one side paid in");
            if (zeroForOne) assertLe(prices[i], previous, "zeroForOne lowers the price");
            else assertGe(prices[i], previous, "oneForZero raises the price");
            previous = uint160(prices[i]);
        }
    }

    // ---------------------------------------------------------------- one (size, flow model) case

    /// @dev Capital `sizeBps` of the pool's TVL at B0, split 50/50 by value; both worlds from the same snapshot.
    function _run(uint256 sizeBps, bool priceAnchored) internal returns (Result memory r) {
        (uint160 sqrtStart,,,) = MANAGER.getSlot0(realId);
        uint256 capital = tvl * sizeBps / 10_000;
        IOathVault.Benchmark memory b;
        (b.L, b.r0, b.r1) = BenchmarkLib.create(capital, sqrtStart, SPACING);
        (uint256 x, uint256 y) = BenchmarkLib.split(capital, sqrtStart);
        uint256 snapshot = vm.snapshotState();

        // World 1: the capital in the curator range; the benchmark from world-1 state.
        uint128 curatorL = LiquidityAmounts.getLiquidityForAmounts(
            sqrtStart, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), x, y
        );
        lpRouter.modifyLiquidity{value: x}(
            realKey, ModifyLiquidityParams(lower, upper, int256(uint256(curatorL)), bytes32(uint256(1))), ""
        );
        (b.G0, b.G1) = MANAGER.getFeeGrowthGlobals(realId);
        r.misses = _replay(priceAnchored);
        (uint256 g0End, uint256 g1End) = MANAGER.getFeeGrowthGlobals(realId);
        (r.sqrtEnd1,,,) = MANAGER.getSlot0(realId);
        (r.benchEnd, r.benchFees0, r.benchFees1) = BenchmarkLib.valueAt(b, g0End, g1End, r.sqrtEnd1, SPACING);
        vm.revertToState(snapshot);

        // World 2: the same capital as a real full-range position of L_b.
        bytes32 salt = bytes32(uint256(2));
        lpRouter.modifyLiquidity{value: x}(
            realKey, ModifyLiquidityParams(tickMin, tickMax, int256(uint256(b.L)), salt), ""
        );
        r.misses += _replay(priceAnchored);
        (r.sqrtEnd2,,,) = MANAGER.getSlot0(realId);
        (uint256 eth0, uint256 usdc0) = _balances();
        lpRouter.modifyLiquidity(realKey, ModifyLiquidityParams(tickMin, tickMax, 0, salt), ""); // fees only
        (uint256 eth1, uint256 usdc1) = _balances();
        lpRouter.modifyLiquidity(realKey, ModifyLiquidityParams(tickMin, tickMax, -int256(uint256(b.L)), salt), "");
        (uint256 eth2, uint256 usdc2) = _balances();
        (r.realFees0, r.realFees1) = (eth1 - eth0, usdc1 - usdc0);
        r.realEnd = ValuationLib.value(eth2 - eth0 + b.r0, usdc2 - usdc0 + b.r1, r.sqrtEnd2);
        vm.revertToState(snapshot);

        _log(sizeBps, priceAnchored, capital, b.L, r);
    }

    /// @dev Replays the 500 swaps; returns how many recorded prices were not reached (price-anchored only).
    function _replay(bool priceAnchored) internal returns (uint256 misses) {
        for (uint256 i; i < SWAPS; ++i) {
            if (!priceAnchored) {
                bool z = amount0[i] < 0;
                int256 amountIn = z ? amount0[i] : amount1[i]; // negative: exact input of what the swapper paid
                swapRouter.swap{value: z ? uint256(-amountIn) : 0}(
                    realKey,
                    SwapParams(z, amountIn, z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
                    PoolSwapTest.TestSettings(false, false),
                    ""
                );
                continue;
            }
            (uint160 current,,,) = MANAGER.getSlot0(realId);
            uint160 target = uint160(prices[i]);
            if (current == target) continue;
            bool zf = target < current;
            // 10M ETH or 10B USDC of exact input: the price limit binds first.
            swapRouter.swap{value: zf ? 10_000_000 ether : 0}(
                realKey,
                SwapParams(zf, zf ? -int256(10_000_000 ether) : -int256(1e16), target),
                PoolSwapTest.TestSettings(false, false),
                ""
            );
            (current,,,) = MANAGER.getSlot0(realId);
            if (current != target) ++misses;
        }
    }

    function _assertPriceAnchored(Result memory r) internal pure {
        assertEq(r.misses, 0, "every recorded price reached");
        assertEq(r.sqrtEnd1, r.sqrtEnd2, "both worlds end at the recorded price");
        assertEq(r.benchFees0, r.realFees0, "benchmark fees0 = real fees0, to the wei");
        assertEq(r.benchFees1, r.realFees1, "benchmark fees1 = real fees1, to the wei");
        assertLe(_bps100(r.benchEnd, r.realEnd), 2_500, "total-value error <= 25 bps");
    }

    function _log(uint256 sizeBps, bool priceAnchored, uint256 capital, uint128 benchL, Result memory r) internal pure {
        console2.log("==== F3 size (bps of TVL), price-anchored (1) ====", sizeBps, priceAnchored ? 1 : 0);
        console2.log("  capital (USDC units) / L_b", capital, benchL);
        console2.log("  benchmark fees ETH wei / USDC", r.benchFees0, r.benchFees1);
        console2.log("  real fees      ETH wei / USDC", r.realFees0, r.realFees1);
        console2.log("  total value benchmark / real (USDC units)", r.benchEnd, r.realEnd);
        console2.log("  total-value error (0.01 bps)", _bps100(r.benchEnd, r.realEnd));
        console2.log("  end sqrtPrice gap (0.01 bps)", _bps100(r.sqrtEnd1, r.sqrtEnd2));
    }
}
