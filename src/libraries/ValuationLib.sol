// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title ValuationLib
/// @notice Values token amounts, positions and the vault in currency1 units (the numeraire, 02_MATH §1).
///         Every function is pure and mirrors how Uniswap v4 itself values a position, so a real withdrawal
///         at the same price returns exactly these amounts.
library ValuationLib {
    /// @notice A concentrated position and its fee-growth-inside marks (02_MATH §7).
    /// @param liquidity Position liquidity `L`.
    /// @param tickLower Lower tick `tA`.
    /// @param tickUpper Upper tick `tB`.
    /// @param feeGrowthInside0Last Fee growth inside for currency0 when fees were last collected (Q128).
    /// @param feeGrowthInside1Last Fee growth inside for currency1 when fees were last collected (Q128).
    /// @param feeGrowthInside0Mark Fee growth inside for currency0 at the mark time (Q128).
    /// @param feeGrowthInside1Mark Fee growth inside for currency1 at the mark time (Q128).
    struct Position {
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        uint256 feeGrowthInside0Last;
        uint256 feeGrowthInside1Last;
        uint256 feeGrowthInside0Mark;
        uint256 feeGrowthInside1Mark;
    }

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

    /// @notice Fees owed to liquidity `L` between two fee-growth marks (02_MATH §7):
    ///         `mulDiv(growthMark − growthLast, L, Q128)`.
    /// @dev The difference is `unchecked` because fee growth may wrap, exactly as in v4's `Position.sol`.
    /// @param liquidity Liquidity `L`.
    /// @param growthLast Fee growth (inside or global) at the earlier mark (Q128).
    /// @param growthMark Fee growth (inside or global) at the later mark (Q128).
    /// @return Fees in raw units of the growth's currency.
    function feesOwed(uint128 liquidity, uint256 growthLast, uint256 growthMark) internal pure returns (uint256) {
        uint256 delta;
        unchecked {
            delta = growthMark - growthLast;
        }
        return FullMath.mulDiv(delta, liquidity, FixedPoint128.Q128);
    }

    /// @notice Vault NAV at a mark price (02_MATH §7): idle tokens plus the position's principal and
    ///         uncollected fees, valued in currency1:
    ///         `value(idle0 + p0 + u0, idle1 + p1 + u1, sqrtP)`.
    /// @param idle0 Idle currency0 (vault balance).
    /// @param idle1 Idle currency1 (vault balance minus the bond).
    /// @param position The vault position and its fee-growth marks.
    /// @param sqrtPriceX96 Mark price.
    /// @return navValue Vault value in raw currency1 units.
    /// @return fees0 Uncollected currency0 fees `u0`.
    /// @return fees1 Uncollected currency1 fees `u1`.
    function nav(uint256 idle0, uint256 idle1, Position memory position, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint256 navValue, uint256 fees0, uint256 fees1)
    {
        (uint256 p0, uint256 p1) = principal(position.liquidity, position.tickLower, position.tickUpper, sqrtPriceX96);
        fees0 = feesOwed(position.liquidity, position.feeGrowthInside0Last, position.feeGrowthInside0Mark);
        fees1 = feesOwed(position.liquidity, position.feeGrowthInside1Last, position.feeGrowthInside1Mark);
        navValue = value(idle0 + p0 + fees0, idle1 + p1 + fees1, sqrtPriceX96);
    }
}
