// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title SettlementLib
/// @notice The Oath verdict (MATH.md §9). Compares the vault's NAV with the benchmark
///         at epoch end, both marked at the same TWAP price:
///         - shortfall beyond the band: the curator's bond pays depositors the excess shortfall, up to the bond;
///         - outperformance beyond the band: the curator earns `perfFeeBps` of the excess, as new shares;
///         - inside the band: nothing (the difference is within measurement tolerance).
library SettlementLib {
    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Settles one epoch (MATH.md §9):
    ///         `d = NAV_E − B_E`, `band = mulDiv(B_E, bandBps, 10,000)`;
    ///         `d < −band` → `payout = min(−d − band, bond)`;
    ///         `d > band`  → `fee = mulDiv(d − band, perfFeeBps, 10,000)`;
    ///         `feeShares = mulDiv(supply, fee, NAV_E − fee)`.
    /// @dev Minting `feeShares` gives the curator `fee / NAV_E` of the vault (standard fund-fee dilution).
    ///      `supply` includes the dead shares, so the dilution is pro-rata for everyone. Every amount paid to
    ///      the curator rounds down. A shortfall larger than the bond leaves `−d − band − payout` with
    ///      depositors (the vault emits `BondExhausted`).
    ///      `B_E == 0` gives no verdict (no payout, no fee, `band = 0`, `diff = NAV_E`) so that settlement always
    ///      completes. It happens only for a dust vault: the benchmark starts up to `6u` below `V_S` by rounding
    ///      (MATH.md §6.1, §9.2), so with `V_S ≤ 6u` it can be worth nothing at `E`.
    /// @param navEnd Vault NAV at `E`, `NAV_E` (raw currency1 units).
    /// @param benchEnd Benchmark value at `E`, `B_E` (raw currency1 units).
    /// @param bond Curator bond available for a payout (raw currency1 units).
    /// @param supply Total vault shares before minting the fee shares.
    /// @param bandBps Tolerance band in basis points of `B_E` (35 by default).
    /// @param perfFeeBps Performance fee in basis points of the excess above the band (2,000 by default).
    /// @return payout Currency1 moved from the bond to depositors.
    /// @return fee Performance fee value in currency1 units.
    /// @return feeShares Shares to mint to the curator.
    /// @return diff `NAV_E − B_E`.
    /// @return band The band in currency1 units.
    // forge-lint: disable-next-line(internal-function-used-once)
    function settle(uint256 navEnd, uint256 benchEnd, uint256 bond, uint256 supply, uint16 bandBps, uint16 perfFeeBps)
        internal
        pure
        returns (uint256 payout, uint256 fee, uint256 feeShares, int256 diff, uint256 band)
    {
        diff = SafeCast.toInt256(navEnd) - SafeCast.toInt256(benchEnd);
        if (benchEnd == 0) return (0, 0, 0, diff, 0); // dust vault: nothing to measure against
        band = FullMath.mulDiv(benchEnd, bandBps, BPS);

        if (diff < -SafeCast.toInt256(band)) {
            // Shortfall beyond the band: the bond covers it, up to the bond. Here −d = B_E − NAV_E > band.
            uint256 excessShortfall = benchEnd - navEnd - band;
            payout = excessShortfall < bond ? excessShortfall : bond;
        } else if (diff > SafeCast.toInt256(band)) {
            // Outperformance beyond the band: the curator earns a share of the excess. Here d = NAV_E − B_E > band.
            fee = FullMath.mulDiv(navEnd - benchEnd - band, perfFeeBps, BPS);
        }

        if (fee != 0) {
            // fee ≤ (d − band)·perfFeeBps/10,000 ≤ d < NAV_E since B_E > 0 and perfFeeBps ≤ 10,000 (the factory
            // caps it at 5,000). Asserted anyway (MATH.md §9.2).
            assert(fee < navEnd);
            feeShares = FullMath.mulDiv(supply, fee, navEnd - fee);
        }
    }
}
