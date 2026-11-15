// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title ValuationLib
/// @notice Values token amounts, positions and the vault in currency1 units (the numeraire, 02_MATH §1).
///         Every function is pure and mirrors how Uniswap v4 itself values a position, so a real withdrawal
///         at the same price returns exactly these amounts.
library ValuationLib {
    /// @notice Value of `a0` currency0 plus `a1` currency1 in currency1 units at `sqrtPriceX96`
    ///         (02_MATH §2): `a1 + mulDiv(mulDiv(a0, sqrtP, Q96), sqrtP, Q96)`.
    /// @dev Two mulDivs because `sqrtP²` can exceed 256 bits. Rounds down.
    /// @param a0 Amount of currency0 (raw units).
    /// @param a1 Amount of currency1 (raw units).
    /// @param sqrtPriceX96 Mark price as `sqrt(P)·2^96`, `P` = raw currency1 per raw currency0.
    /// @return Value in raw currency1 units.
    function value(uint256 a0, uint256 a1, uint160 sqrtPriceX96) internal pure returns (uint256) {
        return a1 + FullMath.mulDiv(FullMath.mulDiv(a0, sqrtPriceX96, FixedPoint96.Q96), sqrtPriceX96, FixedPoint96.Q96);
    }

    /// @notice Token amounts of a position of liquidity `L` on `[tickLower, tickUpper)` at `sqrtPriceX96`
    ///         (02_MATH §3). These are the amounts a withdrawal at that price returns, before fees.
    /// @dev Rounds down, like v4 for a liquidity removal.
    ///      | `sP ≤ sA`      | amount0 = getAmount0Delta(sA, sB, L) | amount1 = 0                          |
    ///      | `sA < sP < sB` | amount0 = getAmount0Delta(sP, sB, L) | amount1 = getAmount1Delta(sA, sP, L) |
    ///      | `sP ≥ sB`      | amount0 = 0                          | amount1 = getAmount1Delta(sA, sB, L) |
    /// @param liquidity Position liquidity `L`.
    /// @param tickLower Lower tick `tA`.
    /// @param tickUpper Upper tick `tB`.
    /// @param sqrtPriceX96 Mark price `sP`.
    /// @return amount0 Currency0 in the position.
    /// @return amount1 Currency1 in the position.
    function principal(uint128 liquidity, int24 tickLower, int24 tickUpper, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtPriceX96 <= sqrtA) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, false);
        } else if (sqrtPriceX96 < sqrtB) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtB, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtPriceX96, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, false);
        }
    }
}
