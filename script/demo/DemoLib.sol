// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ValuationLib} from "../../src/libraries/ValuationLib.sol";

/// @title DemoLib
/// @notice Pure helpers for the demo scripts: the TWAP tick the vault will compute, the curator's range and its
///         swap's price limit, and USD formatting for the results files. Prices are USDC (6 decimals) per ETH
///         (18 decimals).
library DemoLib {
    /// @notice `floorDiv(cumulativeDelta, elapsed)`: the TWAP tick, rounded toward −∞ as the vault and Uniswap v3's
    ///         oracle do (MATH.md §4).
    /// @param cumulativeDelta Growth of the tick cumulative over the window.
    /// @param elapsed Window length in seconds (> 0).
    /// @return The TWAP tick.
    function twapTick(int256 cumulativeDelta, uint256 elapsed) internal pure returns (int24) {
        int256 dt = int256(elapsed);
        int256 tick = cumulativeDelta / dt;
        if (cumulativeDelta < 0 && cumulativeDelta % dt != 0) tick--;
        return int24(tick);
    }

    /// @notice The range `[c − halfWidth, c + halfWidth)` centred on `c`, the multiple of `spacing` at or below
    ///         `tick`.
    /// @param tick The tick to centre on.
    /// @param halfWidth Half the range width in ticks (a multiple of `spacing`).
    /// @param spacing The pool's tick spacing.
    /// @return lower Lower tick.
    /// @return upper Upper tick.
    function rangeAround(int24 tick, int24 halfWidth, int24 spacing) internal pure returns (int24 lower, int24 upper) {
        int24 centre = tick / spacing * spacing;
        if (tick < 0 && tick % spacing != 0) centre -= spacing;
        return (centre - halfWidth, centre + halfWidth);
    }

    /// @notice The price limit for the curator's own swap: `maxIntraBlockTicks − 1` ticks from the spot tick in the
    ///         swap's direction. The hook's guard reverts a vault liquidity change once the price moved more than
    ///         `maxIntraBlockTicks` in the block, so a swap stopped here can never make the reposition revert; an
    ///         unfilled remainder stays idle.
    /// @param tick Spot tick.
    /// @param zeroForOne Swap direction.
    /// @param maxIntraBlockTicks The vault's guard threshold (> 0).
    /// @return The price limit.
    function guardedLimit(int24 tick, bool zeroForOne, int24 maxIntraBlockTicks) internal pure returns (uint160) {
        return
            TickMath.getSqrtPriceAtTick(zeroForOne ? tick - (maxIntraBlockTicks - 1) : tick + (maxIntraBlockTicks - 1));
    }

    /// @notice The price of 1 ETH in USDC units at `sqrtPriceX96` (`ValuationLib.value` of 1e18 wei).
    /// @param sqrtPriceX96 The price.
    /// @return USDC units per ETH.
    function price(uint160 sqrtPriceX96) internal pure returns (uint256) {
        return ValuationLib.value(1 ether, 0, sqrtPriceX96);
    }

    /// @notice USDC units as a decimal dollar amount with 2 decimals, rounded half up (`30000000000` →
    ///         `"30000.00"`).
    /// @param units USDC units (6 decimals).
    /// @return The formatted amount.
    function usd(uint256 units) internal pure returns (string memory) {
        return _cents((units + 5_000) / 10_000);
    }

    /// @notice A signed amount as `usd`, rounded half away from zero; `"-"` only when it rounds to a non-zero
    ///         amount.
    /// @param units Signed USDC units (6 decimals).
    /// @return The formatted amount.
    function usdSigned(int256 units) internal pure returns (string memory) {
        if (units >= 0) return usd(uint256(units));
        uint256 cents = (uint256(-units) + 5_000) / 10_000;
        return cents == 0 ? "0.00" : string.concat("-", _cents(cents));
    }

    function _cents(uint256 cents) private pure returns (string memory) {
        uint256 fraction = cents % 100;
        return string.concat(Strings.toString(cents / 100), fraction < 10 ? ".0" : ".", Strings.toString(fraction));
    }
}
