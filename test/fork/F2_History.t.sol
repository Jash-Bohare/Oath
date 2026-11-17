// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {BenchmarkLib} from "../../src/libraries/BenchmarkLib.sol";
import {ValuationLib} from "../../src/libraries/ValuationLib.sol";
import {ForkBase} from "./ForkBase.sol";

/// @notice F2: over 7 days of real history (B0 → B1, Nov 8–15 2026), fee growth inside the full range equals the
///         pool's global fee growth exactly, and those deltas are the ones MATH.md §9.1 and §13 use. Also the real
///         number: a benchmark worth one ETH at B0, valued at B1 with `BenchmarkLib.valueAt`, against HODL.
contract F2HistoryForkTest is ForkBase {
    using StateLibrary for IPoolManager;

    /// @dev MATH.md §9.1 / §13 F2: global fee growth of the real pool over B0 → B1 (Q128).
    uint256 internal constant DG0 = 5685705715728585446726598611346846337347;
    uint256 internal constant DG1 = 10323568296605520673412669325024;

    struct Snapshot {
        uint256 g0;
        uint256 g1;
        uint256 in0;
        uint256 in1;
        uint160 sqrtPriceX96;
        uint256 timestamp;
    }

    function setUp() public {
        _fork(B0);
    }

    function test_F2_identityAcrossHistory() public {
        Snapshot memory a = _read(B0);
        Snapshot memory b = _read(B1);
        assertEq(b.timestamp - a.timestamp, 7 days + 30 minutes + 36, "B0 -> B1 spans 7 days 0 h 30 min");

        uint256 dIn0;
        uint256 dIn1;
        unchecked {
            dIn0 = b.in0 - a.in0; // fee growth inside is modular in v4
            dIn1 = b.in1 - a.in1;
        }
        assertEq(dIn0, b.g0 - a.g0, "full-range fee growth inside = global (0)");
        assertEq(dIn1, b.g1 - a.g1, "full-range fee growth inside = global (1)");
        assertEq(b.g0 - a.g0, DG0, "dG0 = MATH.md constant");
        assertEq(b.g1 - a.g1, DG1, "dG1 = MATH.md constant");

        // The real number: a benchmark worth one ETH at B0.
        uint256 navStart = ValuationLib.value(1 ether, 0, a.sqrtPriceX96);
        IOathVault.Benchmark memory bench;
        (bench.L, bench.r0, bench.r1) = BenchmarkLib.create(navStart, a.sqrtPriceX96, SPACING);
        (bench.G0, bench.G1) = (a.g0, a.g1);
        (uint256 benchEnd, uint256 fees0, uint256 fees1) =
            BenchmarkLib.valueAt(bench, b.g0, b.g1, b.sqrtPriceX96, SPACING);
        (uint256 x, uint256 y) = BenchmarkLib.split(navStart, a.sqrtPriceX96);
        uint256 hodlEnd = ValuationLib.value(x, y, b.sqrtPriceX96);

        console2.log("F2 ETH price B0 / B1 (USDC units)", navStart, ValuationLib.value(1 ether, 0, b.sqrtPriceX96));
        console2.log("F2 benchmark fees ETH wei / USDC", fees0, fees1);
        console2.log("F2 fees value at B1 (USDC units)", ValuationLib.value(fees0, fees1, b.sqrtPriceX96));
        console2.log("F2 benchmark at B1 / HODL at B1 (USDC units)", benchEnd, hodlEnd);
        // The feasibility study's numbers: 0.000395057 ETH + 0.717307 USDC of fees ($1.43, 6 bps of a week), and the
        // position at $2,016.80 against HODL at $2,026.26 (trailing by $9.46) while ETH fell from $2,236.09 to
        // $1,816.43.
        assertApproxEqAbs(fees0, 0.000395057e18, 1e9, "fees0 = 0.000395057 ETH");
        assertEq(fees1, 717_307, "fees1 = 0.717307 USDC");
        assertApproxEqAbs(benchEnd, 2_016_800_000, 5_000, "benchmark at B1 = $2,016.80");
        assertApproxEqAbs(hodlEnd, 2_026_260_000, 5_000, "HODL at B1 = $2,026.26");
    }

    function _read(uint256 blockNumber) internal returns (Snapshot memory s) {
        vm.createSelectFork("mainnet", blockNumber);
        (s.g0, s.g1) = MANAGER.getFeeGrowthGlobals(realId);
        (s.in0, s.in1) = MANAGER.getFeeGrowthInside(realId, tickMin, tickMax);
        (s.sqrtPriceX96,,,) = MANAGER.getSlot0(realId);
        s.timestamp = vm.getBlockTimestamp();
    }
}
