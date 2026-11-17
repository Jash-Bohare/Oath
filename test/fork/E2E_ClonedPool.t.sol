// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IOathHook} from "../../src/interfaces/IOathHook.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {BenchmarkLib} from "../../src/libraries/BenchmarkLib.sol";
import {SettlementLib} from "../../src/libraries/SettlementLib.sol";
import {ValuationLib} from "../../src/libraries/ValuationLib.sol";
import {OathForkBase} from "./OathForkBase.sol";

/// @notice One full Oath epoch on mainnet: an Oath pool at B0 with the real ETH/USDC pool's liquidity curve, the
///         real swaps of Nov 8–9 2026 replayed price-anchored at their real blocks and times, a $30,000 vault with a
///         ±200-tick curator and a $3,000 bond, a 1-day epoch after a 30-minute open window, and settlement.
///         Everything the settlement used is recomputed independently: start and end ticks from a brute-force
///         Σ tick·dt of the replayed path, NAV_E and B_E from raw pool reads and the hook's snapshot. The
///         `Settled` event must carry exactly the stored result.
/// @dev Liquidity changes in the real pool after B0 (ModifyLiquidity events) are not replayed: the cloned curve
///      is the real one at B0.
contract E2EClonedPoolForkTest is OathForkBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setUpOath(TWAP_WINDOW + 1 days);
    }

    function test_e2e_epochOnClonedMainnetPool() public {
        // Open window: 30 minutes of real flow, then the curator starts at the open-window TWAP.
        uint256 start = createdAt + TWAP_WINDOW;
        _replayUntil(start);
        int256 cumulativeStart = _actAt(start);
        assertEq(hook.cumulativeNow(key), cumulativeStart, "hook cumulative = brute force at S");
        assertEq(vault.cumAtOpen(), 0, "pool created at B0 with cumulative 0");
        int24 startTick = _floorDiv(cumulativeStart, TWAP_WINDOW);
        int24 center = startTick / SPACING * SPACING;
        if (startTick < 0 && startTick % SPACING != 0) center -= SPACING;
        (int24 lower, int24 upper) = (center - 200, center + 200);
        vm.prank(curator);
        vault.startEpoch(lower, upper, IOathVault.SwapIntent(false, 0, 0));

        (,,,,, uint256 navStart, int24 benchStartTick) = vault.benchmark();
        assertEq(benchStartTick, startTick, "start tick = brute-force open-window TWAP");
        uint256 swapsInWindow = cursor;

        // The epoch: one day of real flow. The end TWAP covers [E − W, E].
        uint256 end = vault.epochEnd();
        assertEq(end, start + 1 days);
        _replayUntil(end - TWAP_WINDOW);
        int256 cumulativeA = _bruteCumulativeAt(end - TWAP_WINDOW);
        _replayUntil(end);
        int256 cumulativeB = _bruteCumulativeAt(end);
        int24 endTick = _floorDiv(cumulativeB - cumulativeA, TWAP_WINDOW);
        assertEq(priceMisses, 0, "every recorded price reached");
        assertGt(cursor - swapsInWindow, 1_000, "over a thousand real swaps in the epoch");

        // Settlement at E, in the block after the last swap of the epoch.
        _actAt(end);
        IOathVault.EpochResult memory expected = _expected(endTick);
        IOathHook.Epoch memory e = hook.epochData(key);
        assertEq(e.cumA, cumulativeA, "hook checkpoint at E - W = brute force");
        assertEq(e.cumB, cumulativeB, "hook checkpoint at E = brute force");

        vm.recordLogs();
        vm.prank(keeper);
        vault.settle();
        IOathVault.EpochResult memory emitted = _settledEvent();
        IOathVault.EpochResult memory r = vault.getResult(0);

        assertEq(abi.encode(r), abi.encode(expected), "result = independent recomputation");
        assertEq(abi.encode(emitted), abi.encode(r), "Settled event = stored result");
        assertEq(r.navStart, navStart);
        assertEq(uint8(vault.state()), uint8(IOathVault.State.OPEN), "vault reopened");
        assertEq(_positionLiquidity(lower, upper), 0, "position unwound");

        console2.log("E2E swaps replayed: open window / epoch", swapsInWindow, cursor - swapsInWindow);
        console2.log("E2E start tick / end tick", uint256(int256(-startTick)), uint256(int256(-endTick)));
        console2.log("E2E navStart / navEnd / benchEnd (USDC units)", r.navStart, r.navEnd, r.benchEnd);
        console2.log("E2E band / payout / fee (USDC units)", r.band, r.payout, r.fee);
        console2.log("E2E vault fees ETH wei / USDC", r.vaultFees0, r.vaultFees1);
        console2.log("E2E bench fees ETH wei / USDC", r.benchFees0, r.benchFees1);
    }

    // ---------------------------------------------------------------- independent recomputation

    /// @dev The `EpochResult` from raw state: the end price from the brute-force end tick, the hook's snapshot of fee
    ///      growth at E (after a poke, which anyone may do and `settle` repeats harmlessly), the pool's record of
    ///      the vault's position, idle balances, the stored benchmark, bond and supply, and MATH.md §6.2, §7, §9.
    function _expected(int24 endTick) internal returns (IOathVault.EpochResult memory r) {
        hook.poke(key);
        IOathHook.Epoch memory e = hook.epochData(key);
        assertTrue(e.snapTaken && e.doneA && e.doneB, "hook ready");
        uint160 sqrtEnd = TickMath.getSqrtPriceAtTick(endTick);

        (int24 lower, int24 upper, uint128 liquidity) = vault.positionInfo();
        (, uint256 last0, uint256 last1) = MANAGER.getPositionInfo(id, address(vault), lower, upper, bytes32(0));
        assertEq(_positionLiquidity(lower, upper), liquidity, "pool position = L_v");
        (r.navEnd, r.vaultFees0, r.vaultFees1) = ValuationLib.nav(
            vault.idle0(),
            vault.idle1(),
            ValuationLib.Position(liquidity, lower, upper, last0, last1, e.fgIn0, e.fgIn1),
            sqrtEnd
        );
        IOathVault.Benchmark memory b;
        (b.L, b.r0, b.r1, b.G0, b.G1, b.navStart, b.startTick) = vault.benchmark();
        (r.benchEnd, r.benchFees0, r.benchFees1) = BenchmarkLib.valueAt(b, e.G0, e.G1, sqrtEnd, SPACING);
        (r.payout, r.fee, r.feeShares, r.diff, r.band) =
            SettlementLib.settle(r.navEnd, r.benchEnd, vault.bondBalance(), vault.totalSupply(), 35, 2_000);
        (r.start, r.end, r.startTick, r.endTick) = (vault.epochStart(), vault.epochEnd(), b.startTick, endTick);
        r.navStart = b.navStart;
        r.bondAfter = vault.bondBalance() - r.payout;
    }

    function _settledEvent() internal view returns (IOathVault.EpochResult memory result) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == IOathVault.Settled.selector) {
                assertEq(uint256(logs[i].topics[1]), 0, "epoch index");
                result = abi.decode(logs[i].data, (IOathVault.EpochResult));
                ++found;
            }
        }
        assertEq(found, 1, "one Settled event");
    }

    function _positionLiquidity(int24 lower, int24 upper) internal view returns (uint128 liquidity) {
        (liquidity,,) = MANAGER.getPositionInfo(id, address(vault), lower, upper, bytes32(0));
    }
}
