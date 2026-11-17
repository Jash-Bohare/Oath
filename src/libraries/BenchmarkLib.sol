// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IOathVault} from "../interfaces/IOathVault.sol";
import {ValuationLib} from "./ValuationLib.sol";

/// @title BenchmarkLib
/// @notice The counterfactual Oath measures every curator against: the vault's start value placed full-range
///         in the same pool at the start of the epoch, split 50/50 by value (MATH.md §6). It is hypothetical,
///         so it never touches the pool; it is created from two numbers at the start and valued from two
///         fee-growth reads at the end.
library BenchmarkLib {
    /// @notice Full-range ticks for `tickSpacing`: −887270 / 887270 for spacing 10 (MATH.md §1).
    /// @param tickSpacing The pool's tick spacing.
    /// @return tickMin `TickMath.minUsableTick(tickSpacing)`.
    /// @return tickMax `TickMath.maxUsableTick(tickSpacing)`.
    function fullRange(int24 tickSpacing) internal pure returns (int24 tickMin, int24 tickMax) {
        return (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
    }

    /// @notice Splits `navStart` 50/50 by value at the start price (MATH.md §6.1):
    ///         `half1 = V_S / 2`, `x = mulDiv(mulDiv(half1, Q96, sqrtP), Q96, sqrtP)` (currency0 worth `half1`),
    ///         `y = V_S − half1`.
    /// @param navStart Start value `V_S` in raw currency1 units.
    /// @param sqrtPriceX96 Start TWAP price `sqrtP_S`.
    /// @return x Currency0 side.
    /// @return y Currency1 side.
    // forge-lint: disable-next-line(internal-function-used-once)
    function split(uint256 navStart, uint160 sqrtPriceX96) internal pure returns (uint256 x, uint256 y) {
        uint256 half1 = navStart / 2;
        x = FullMath.mulDiv(FullMath.mulDiv(half1, FixedPoint96.Q96, sqrtPriceX96), FixedPoint96.Q96, sqrtPriceX96);
        y = navStart - half1;
    }

    /// @notice Creates the benchmark at epoch start (MATH.md §6.1): the full-range liquidity `L_b` that
    ///         `(x, y)` buys at the start price, and the leftovers `r0, r1` held outside the pool.
    ///         `L_b = getLiquidityForAmounts(sqrtP_S, sqrtMin, sqrtMax, x, y)`;
    ///         `cost0 = getAmount0Delta(sqrtP_S, sqrtMax, L_b, up)`, `cost1 = getAmount1Delta(sqrtMin, sqrtP_S, L_b, up)`;
    ///         `r_i = max(amount_i − cost_i, 0)`.
    /// @dev Costs round up, as the pool charges to add liquidity, so the benchmark never holds more than the
    ///      vault started with (MATH.md §1 rounding rule). The price is clamped into the full range for the
    ///      costs; this equals the MATH.md formula for every in-range price and matches v4 at the extremes.
    ///      For full range a 50/50 split is almost exactly the pool ratio, so `r0, r1` are dust.
    /// @param navStart Start value `V_S` (vault NAV at `sqrtP_S`).
    /// @param sqrtPriceX96 Start TWAP price `sqrtP_S`.
    /// @param tickSpacing The pool's tick spacing.
    /// @return liquidity Benchmark liquidity `L_b`.
    /// @return r0 Leftover currency0.
    /// @return r1 Leftover currency1.
    // forge-lint: disable-next-line(internal-function-used-once)
    function create(uint256 navStart, uint160 sqrtPriceX96, int24 tickSpacing)
        internal
        pure
        returns (uint128 liquidity, uint256 r0, uint256 r1)
    {
        (uint256 x, uint256 y) = split(navStart, sqrtPriceX96);
        (int24 tickMin, int24 tickMax) = fullRange(tickSpacing);
        uint160 sqrtMin = TickMath.getSqrtPriceAtTick(tickMin);
        uint160 sqrtMax = TickMath.getSqrtPriceAtTick(tickMax);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtMin, sqrtMax, x, y);

        uint160 s = sqrtPriceX96 < sqrtMin ? sqrtMin : (sqrtPriceX96 > sqrtMax ? sqrtMax : sqrtPriceX96);
        uint256 cost0 = SqrtPriceMath.getAmount0Delta(s, sqrtMax, liquidity, true);
        uint256 cost1 = SqrtPriceMath.getAmount1Delta(sqrtMin, s, liquidity, true);
        r0 = x > cost0 ? x - cost0 : 0;
        r1 = y > cost1 ? y - cost1 : 0;
    }

    /// @notice Values the benchmark at epoch end (MATH.md §6.2): its full-range principal at the end price,
    ///         plus the fees `L_b` earned from global fee growth over the epoch, plus the leftovers.
    ///         `(p0, p1) = principal(L_b, tickMin, tickMax, sqrtP_E)`;
    ///         `f_i = mulDiv(G_i,E − G_i,S, L_b, Q128)` (unchecked difference);
    ///         `B_E = value(p0 + f0 + r0, p1 + f1 + r1, sqrtP_E)`.
    /// @dev Exactness (MATH.md §13, F1–F3): principal and fees match a real full-range position to the
    ///      wei, and full-range fee growth inside equals global fee growth.
    /// @param benchmark The epoch's benchmark (`L`, `r0`, `r1`, `G0`, `G1` at start are used).
    /// @param g0End Global fee growth of currency0 at `E` (the hook's boundary snapshot).
    /// @param g1End Global fee growth of currency1 at `E`.
    /// @param sqrtPriceX96 End TWAP price `sqrtP_E`.
    /// @param tickSpacing The pool's tick spacing.
    /// @return benchValue Benchmark value `B_E` in raw currency1 units.
    /// @return fees0 Benchmark fees in currency0 over the epoch.
    /// @return fees1 Benchmark fees in currency1 over the epoch.
    // forge-lint: disable-next-line(internal-function-used-once)
    function valueAt(
        IOathVault.Benchmark memory benchmark,
        uint256 g0End,
        uint256 g1End,
        uint160 sqrtPriceX96,
        int24 tickSpacing
    ) internal pure returns (uint256 benchValue, uint256 fees0, uint256 fees1) {
        (int24 tickMin, int24 tickMax) = fullRange(tickSpacing);
        (uint256 p0, uint256 p1) = ValuationLib.principal(benchmark.L, tickMin, tickMax, sqrtPriceX96);
        fees0 = ValuationLib.feesOwed(benchmark.L, benchmark.G0, g0End);
        fees1 = ValuationLib.feesOwed(benchmark.L, benchmark.G1, g1End);
        benchValue = ValuationLib.value(p0 + fees0 + benchmark.r0, p1 + fees1 + benchmark.r1, sqrtPriceX96);
    }
}
