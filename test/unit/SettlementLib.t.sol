// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SettlementLib} from "../../src/libraries/SettlementLib.sol";

/// @notice Tests for SettlementLib (02_MATH §9, 05_SETTLEMENT_SPEC §2, §5).
contract SettlementLibTest is Test {
    uint16 internal constant BAND = 35;
    uint16 internal constant PERF = 2_000;

    uint256 internal constant BOND = 3_000e6;
    uint256 internal constant SUPPLY = 30_000e18;

    /// @dev External wrapper so library reverts can be caught with `expectRevert`.
    function settleExt(uint256 nav, uint256 bench, uint256 bond, uint256 supply, uint16 bandBps, uint16 perfBps)
        external
        pure
        returns (uint256, uint256, uint256, int256, uint256)
    {
        return SettlementLib.settle(nav, bench, bond, supply, bandBps, perfBps);
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

    function test_settle_zeroBenchmarkReverts() public {
        vm.expectRevert(SettlementLib.ZeroBenchmark.selector);
        this.settleExt(1, 0, BOND, SUPPLY, BAND, PERF);
    }

    /// @dev A zero NAV against a positive benchmark is a full shortfall, not a revert.
    function test_settle_zeroNavIsFullShortfall() public pure {
        (uint256 payout,,,,) = SettlementLib.settle(0, 10_000e6, 100_000e6, SUPPLY, BAND, PERF);
        assertEq(payout, 10_000e6 - 35e6);
    }

    // ---------------------------------------------------------------- properties (fuzz)

    /// @dev Exactly one of three outcomes, each matching 02_MATH §9 by formula.
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
        bandBps = uint16(bound(bandBps, 0, 500)); // factory bounds (01_ARCHITECTURE §6)
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

    /// @dev Fee-share dilution (07_TEST_PLAN §2): after minting, the curator's shares are worth `fee` of
    ///      NAV_E, within 1 raw unit. Holds while a share is worth at most 1 raw unit of currency1, which
    ///      the vault's shares are (18 decimals against USDC's 6).
    function testFuzz_settle_feeSharesWorthFee(uint256 nav, uint256 excess, uint256 supply) public pure {
        nav = bound(nav, 1e6, 1e18);
        supply = bound(supply, nav, 1e40);
        // Outperformance up to 1.5x the benchmark (02_MATH: fee ≤ 0.5·(d − band) < NAV_E).
        uint256 bench = nav - bound(excess, 0, nav / 3);
        (, uint256 fee, uint256 shares,,) = SettlementLib.settle(nav, bench, 0, supply, BAND, PERF);
        uint256 curatorValue = FullMath.mulDiv(nav, shares, supply + shares);
        assertApproxEqAbs(curatorValue, fee, 1, "curator owns fee / NAV_E");
        assertLe(curatorValue, fee, "never more than the fee");
    }
}
