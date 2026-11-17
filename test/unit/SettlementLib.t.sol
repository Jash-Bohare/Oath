// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SettlementLib} from "../../src/libraries/SettlementLib.sol";
import {BenchmarkLib} from "../../src/libraries/BenchmarkLib.sol";
import {ValuationLib} from "../../src/libraries/ValuationLib.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";

/// @notice Tests for SettlementLib (MATH.md §9).
contract SettlementLibTest is Test {
    uint16 internal constant BAND = 35;
    uint16 internal constant PERF = 2_000;
    uint256 internal constant ONE_CENT = 10_000; // $0.01 in raw USDC units

    // MATH.md §9.1 common inputs (real data where available).
    int24 internal constant START_TICK = -199196;
    uint256 internal constant NAV_START = 30_000e6;
    uint256 internal constant BOND = 3_000e6;
    uint256 internal constant SUPPLY = 30_000e18;
    int24 internal constant RANGE_LO = -199400;
    int24 internal constant RANGE_HI = -199000;
    uint256 internal constant DG0 = 5685705715728585446726598611346846337347; // MATH.md §13, F2
    uint256 internal constant DG1 = 10323568296605520673412669325024;

    // ---------------------------------------------------------------- MATH.md §9.1 worked examples

    /// @dev Loss (real Nov 8–15 move, end $1,816.25): NAV $24,515.96, B_E $27,057.50, d −$2,541.54,
    ///      band $94.70 → bond pays $2,446.84 of $3,000.
    function test_settle_workedExampleLoss() public pure {
        (uint256 nav, uint256 bench) = _example(-201275, 0.006e18, 11.25e6);
        assertApproxEqAbs(nav, 24_515_959_735, ONE_CENT, "NAV_E");
        assertApproxEqAbs(bench, 27_057_502_004, ONE_CENT, "B_E");
        (uint256 payout, uint256 fee, uint256 feeShares, int256 diff, uint256 band) =
            SettlementLib.settle(nav, bench, BOND, SUPPLY, BAND, PERF);
        assertApproxEqAbs(diff, -2_541_542_269, ONE_CENT, "d");
        assertApproxEqAbs(band, 94_701_257, ONE_CENT, "band");
        assertApproxEqAbs(payout, 2_446_841_012, ONE_CENT, "payout");
        assertEq(fee, 0);
        assertEq(feeShares, 0);
    }

    /// @dev Win (end $2,246.25): NAV $30,267.40, B_E $30,090.61, d +$176.79, band $105.32 → fee $14.30,
    ///      14.1758 shares.
    function test_settle_workedExampleWin() public pure {
        (uint256 nav, uint256 bench) = _example(-199150, 0.045e18, 105e6);
        assertApproxEqAbs(nav, 30_267_399_895, ONE_CENT, "NAV_E");
        assertApproxEqAbs(bench, 30_090_605_810, ONE_CENT, "B_E");
        (uint256 payout, uint256 fee, uint256 feeShares, int256 diff, uint256 band) =
            SettlementLib.settle(nav, bench, BOND, SUPPLY, BAND, PERF);
        assertApproxEqAbs(diff, 176_794_085, ONE_CENT, "d");
        assertApproxEqAbs(band, 105_317_120, ONE_CENT, "band");
        assertEq(payout, 0);
        assertApproxEqAbs(fee, 14_295_393, ONE_CENT, "fee");
        // A fee within $0.01 moves the shares by at most 0.01 · supply / NAV ≈ 0.00001 shares.
        assertApproxEqAbs(feeShares, 14_175_794_493_929_733_890, 0.0001e18, "feeShares");
    }

    /// @dev Flat (end $2,235.94): NAV $30,001.59, B_E $30,021.48, d −$19.89 inside the $105.08 band → nothing.
    function test_settle_workedExampleFlat() public pure {
        (uint256 nav, uint256 bench) = _example(-199196, 0.000375e18, 0.75e6);
        assertApproxEqAbs(nav, 30_001_588_477, ONE_CENT, "NAV_E");
        assertApproxEqAbs(bench, 30_021_475_217, ONE_CENT, "B_E");
        (uint256 payout, uint256 fee, uint256 feeShares, int256 diff, uint256 band) =
            SettlementLib.settle(nav, bench, BOND, SUPPLY, BAND, PERF);
        assertApproxEqAbs(diff, -19_886_740, ONE_CENT, "d");
        assertApproxEqAbs(band, 105_075_163, ONE_CENT, "band");
        assertEq(payout, 0);
        assertEq(fee, 0);
        assertEq(feeShares, 0);
    }

    /// @dev The §9.1 vault: deposits the benchmark's 50/50 split, puts the most it can into the curator's
    ///      range [−199400, −199000) at the start price (L_v ≈ 3.126e16, 0.261795 ETH idle), and earns the
    ///      stated illustrative fees. Returns NAV_E and B_E at the end tick.
    function _example(int24 endTick, uint256 vaultFees0, uint256 vaultFees1)
        internal
        pure
        returns (uint256 nav, uint256 bench)
    {
        uint160 sqrtS = TickMath.getSqrtPriceAtTick(START_TICK);
        uint160 sqrtE = TickMath.getSqrtPriceAtTick(endTick);
        (uint256 x, uint256 y) = BenchmarkLib.split(NAV_START, sqrtS);

        uint128 lv = LiquidityAmounts.getLiquidityForAmounts(
            sqrtS, TickMath.getSqrtPriceAtTick(RANGE_LO), TickMath.getSqrtPriceAtTick(RANGE_HI), x, y
        );
        assertApproxEqRel(lv, 31_260_479_169_593_017, 1e9, "L_v");
        (uint256 v0, uint256 v1) = ValuationLib.principal(lv, RANGE_LO, RANGE_HI, sqrtS);
        uint256 idle0 = x - v0;
        uint256 idle1 = y - v1;
        assertApproxEqRel(idle0, 261_794_853_318_716_059, 1e9, "idle0");

        (uint256 p0, uint256 p1) = ValuationLib.principal(lv, RANGE_LO, RANGE_HI, sqrtE);
        nav = ValuationLib.value(idle0 + p0 + vaultFees0, idle1 + p1 + vaultFees1, sqrtE);

        IOathVault.Benchmark memory b;
        (b.L, b.r0, b.r1) = BenchmarkLib.create(NAV_START, sqrtS, 10);
        (bench,,) = BenchmarkLib.valueAt(b, DG0, DG1, sqrtE, 10);
    }

    // ---------------------------------------------------------------- band edges (MATH.md §9.2)

    // B_E = $10 → band = 35,000 raw units exactly.
    uint256 internal constant B = 10_000_000;
    uint256 internal constant EDGE = 35_000;

    function test_settle_atMinusBandNothing() public pure {
        (uint256 payout, uint256 fee, uint256 shares, int256 diff, uint256 band) =
            SettlementLib.settle(B - EDGE, B, BOND, SUPPLY, BAND, PERF);
        assertEq(band, EDGE);
        assertEq(diff, -int256(EDGE));
        assertEq(payout + fee + shares, 0);
    }

    function test_settle_atPlusBandNothing() public pure {
        (uint256 payout, uint256 fee, uint256 shares, int256 diff,) =
            SettlementLib.settle(B + EDGE, B, BOND, SUPPLY, BAND, PERF);
        assertEq(diff, int256(EDGE));
        assertEq(payout + fee + shares, 0);
    }

    function test_settle_oneBelowBandPaysOne() public pure {
        (uint256 payout, uint256 fee, uint256 shares,,) =
            SettlementLib.settle(B - EDGE - 1, B, BOND, SUPPLY, BAND, PERF);
        assertEq(payout, 1);
        assertEq(fee + shares, 0);
    }

    /// @dev d = band + 1 → fee = floor(1 · 20%) = 0, so no shares either.
    function test_settle_oneAboveBandFeeRoundsToZero() public pure {
        (uint256 payout, uint256 fee, uint256 shares,,) =
            SettlementLib.settle(B + EDGE + 1, B, BOND, SUPPLY, BAND, PERF);
        assertEq(payout, 0);
        assertEq(fee, 0);
        assertEq(shares, 0);
    }

    function test_settle_fiveAboveBandFeeIsOne() public pure {
        (, uint256 fee, uint256 shares,,) = SettlementLib.settle(B + EDGE + 5, B, BOND, SUPPLY, BAND, PERF);
        assertEq(fee, 1);
        assertEq(shares, FullMath.mulDiv(SUPPLY, 1, B + EDGE + 5 - 1));
    }

    function test_settle_exactMatchNothing() public pure {
        (uint256 payout, uint256 fee, uint256 shares, int256 diff,) =
            SettlementLib.settle(B, B, BOND, SUPPLY, BAND, PERF);
        assertEq(diff, 0);
        assertEq(payout + fee + shares, 0);
    }

    // ---------------------------------------------------------------- payout cap, zero benchmark

    /// @dev Shortfall larger than the bond: the payout is the whole bond; the rest stays with depositors.
    function test_settle_payoutCappedAtBond() public pure {
        (uint256 payout,,,,) = SettlementLib.settle(5_000e6, 10_000e6, 1_000e6, SUPPLY, BAND, PERF);
        assertEq(payout, 1_000e6);
    }

    function test_settle_noBondNoPayout() public pure {
        (uint256 payout,,,,) = SettlementLib.settle(5_000e6, 10_000e6, 0, SUPPLY, BAND, PERF);
        assertEq(payout, 0);
    }

    /// @dev A zero benchmark (only possible for a dust vault, MATH.md §9.2) gives no verdict instead of reverting,
    ///      so settlement always completes: no payout, no fee, `band = 0`, `d = NAV_E`.
    function testFuzz_settle_zeroBenchmarkNoVerdict(uint256 nav, uint256 bond) public pure {
        nav = bound(nav, 0, 1e30);
        (uint256 payout, uint256 fee, uint256 feeShares, int256 diff, uint256 band) =
            SettlementLib.settle(nav, 0, bond, SUPPLY, BAND, PERF);
        assertEq(payout, 0);
        assertEq(fee, 0);
        assertEq(feeShares, 0);
        assertEq(diff, int256(nav));
        assertEq(band, 0);
    }

    /// @dev A zero NAV against a positive benchmark is a full shortfall, not a revert.
    function test_settle_zeroNavIsFullShortfall() public pure {
        (uint256 payout,,,,) = SettlementLib.settle(0, 10_000e6, 100_000e6, SUPPLY, BAND, PERF);
        assertEq(payout, 10_000e6 - 35e6);
    }

    // ---------------------------------------------------------------- properties (fuzz)

    /// @dev Exactly one of three outcomes, each matching MATH.md §9 by formula.
    function testFuzz_settle_matchesFormula(
        uint256 nav,
        uint256 bench,
        uint256 bond,
        uint256 supply,
        uint16 bandBps,
        uint16 perfBps
    ) public pure {
        nav = bound(nav, 0, 1e30);
        bench = bound(bench, 1, 1e30);
        bond = bound(bond, 0, 1e30);
        supply = bound(supply, 1, 1e40);
        bandBps = uint16(bound(bandBps, 0, 500)); // factory bounds (MATH.md §12)
        perfBps = uint16(bound(perfBps, 0, 5_000));

        (uint256 payout, uint256 fee, uint256 shares, int256 diff, uint256 band) =
            SettlementLib.settle(nav, bench, bond, supply, bandBps, perfBps);

        assertEq(diff, int256(nav) - int256(bench), "diff");
        assertEq(band, bench * bandBps / 10_000, "band");
        if (diff < -int256(band)) {
            uint256 excess = uint256(-diff) - band;
            assertEq(payout, excess < bond ? excess : bond, "payout");
            assertEq(fee + shares, 0, "no fee on a shortfall");
        } else if (diff > int256(band)) {
            assertEq(payout, 0, "no payout on outperformance");
            assertEq(fee, (uint256(diff) - band) * perfBps / 10_000, "fee");
            assertEq(shares, fee == 0 ? 0 : FullMath.mulDiv(supply, fee, nav - fee), "feeShares");
        } else {
            assertEq(payout + fee + shares, 0, "inside the band");
        }
    }

    /// @dev Fee-share dilution: after minting, the curator's shares are worth `fee` of
    ///      NAV_E, within 1 raw unit. Holds while a share is worth at most 1 raw unit of currency1, which
    ///      the vault's shares are (18 decimals against USDC's 6).
    function testFuzz_settle_feeSharesWorthFee(uint256 nav, uint256 excess, uint256 supply) public pure {
        nav = bound(nav, 1e6, 1e18);
        supply = bound(supply, nav, 1e40);
        // Outperformance up to 1.5x the benchmark (MATH.md: fee ≤ 0.5·(d − band) < NAV_E).
        uint256 bench = nav - bound(excess, 0, nav / 3);
        (, uint256 fee, uint256 shares,,) = SettlementLib.settle(nav, bench, 0, supply, BAND, PERF);
        uint256 curatorValue = FullMath.mulDiv(nav, shares, supply + shares);
        assertApproxEqAbs(curatorValue, fee, 1, "curator owns fee / NAV_E");
        assertLe(curatorValue, fee, "never more than the fee");
    }
}
