// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IOathHook} from "../../src/interfaces/IOathHook.sol";
import {OathHookTestBase} from "../utils/OathHookTestBase.sol";

/// @notice OathHook's keeperless epoch-boundary snapshot (MATH.md §8) on the real PoolManager: global fee growth
///         and the fee growth inside the vault's range, exactly as they stood at the epoch end `E`.
contract OathHookSnapshotTest is OathHookTestBase {
    using StateLibrary for IPoolManager;

    uint32 internal epochEnd;

    /// @dev Fee growth as the test reads it directly from the PoolManager.
    struct Growth {
        uint256 g0;
        uint256 g1;
        uint256 in0;
        uint256 in1;
    }

    function setUp() public override {
        super.setUp();
        _createPool(START_TICK);
        epochEnd = uint32(_time() + 1 days);
        _openEpoch(epochEnd, 30 minutes);
    }

    // ---------------------------------------------------------------- taking the snapshot

    /// @dev The first action at or after `E` stores the fee growth that stood at `E` and emits it.
    function test_snapshot_takenByFirstActionAtOrAfterE() public {
        _tradeDuringEpoch();
        vm.warp(epochEnd + 2 hours);
        Growth memory atE = _growthNow(); // nothing has touched the pool since before E

        vm.expectEmit(true, false, false, true, address(hook));
        emit IOathHook.EpochSnapshot(id, atE.g0, atE.g1, atE.in0, atE.in1);
        hook.poke(key);

        IOathHook.Epoch memory e = hook.epochData(key);
        assertTrue(e.snapTaken, "snapTaken");
        _assertSnapshot(e, atE);
        assertGt(e.G0, 0, "pool earned currency0 fees");
        assertGt(e.G1, 0, "pool earned currency1 fees");
    }

    /// @dev Due at `E` itself (`E ≤ now`), not one second earlier.
    function test_snapshot_dueAtEItself() public {
        _tradeDuringEpoch();
        vm.warp(epochEnd - 1);
        hook.poke(key);
        assertFalse(hook.epochData(key).snapTaken, "not at E - 1");

        vm.warp(epochEnd);
        hook.poke(key);
        assertTrue(hook.epochData(key).snapTaken, "at E");
    }

    /// @dev Taken once: later swaps and donations raise fee growth but never move the stored snapshot.
    function test_snapshot_takenOnlyOnce() public {
        _tradeDuringEpoch();
        vm.warp(epochEnd + 1);
        hook.poke(key);
        IOathHook.Epoch memory first = hook.epochData(key);

        _nextBlock(1 hours);
        _moveToTick(START_TICK + 3_000);
        donateRouter.donate(key, 1e15, 1e15, ZERO_BYTES);
        _nextBlock(1 hours);
        hook.poke(key);
        assertEq(abi.encode(hook.epochData(key)), abi.encode(first), "unchanged");
        (uint256 g0Now,) = manager.getFeeGrowthGlobals(id);
        assertGt(g0Now, first.G0, "fee growth moved on");
    }

    // ---------------------------------------------------------------- closing and reopening

    /// @dev Once both checkpoints and the snapshot are in, the vault can close the epoch; after that nothing is
    ///      recorded until the next epoch, which starts from a clean record.
    function test_snapshot_closeThenReopen() public {
        _tradeDuringEpoch();
        vm.warp(epochEnd + 1);
        hook.poke(key);

        vm.expectEmit(true, false, false, false, address(hook));
        emit IOathHook.EpochClosed(id);
        vm.prank(vault);
        hook.closeEpoch(key);
        IOathHook.Epoch memory closed = hook.epochData(key);
        assertFalse(closed.active, "inactive");

        _nextBlock(2 days);
        _moveToTick(START_TICK + 50);
        assertEq(abi.encode(hook.epochData(key)), abi.encode(closed), "nothing recorded while closed");

        uint32 nextEnd = uint32(_time() + 1 days);
        _openEpoch(nextEnd, 30 minutes);
        IOathHook.Epoch memory e = hook.epochData(key);
        assertEq(
            abi.encode(e),
            abi.encode(IOathHook.Epoch(nextEnd - 30 minutes, nextEnd, false, false, false, true, 0, 0, 0, 0, 0, 0)),
            "clean record"
        );
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Swaps both ways and a donation during the epoch, so fee growth is non-zero in both currencies.
    function _tradeDuringEpoch() internal {
        _nextBlock(2 hours);
        _moveToTick(START_TICK + 600);
        _nextBlock(2 hours);
        _moveToTick(START_TICK - 400);
        donateRouter.donate(key, 1e12, 1e9, ZERO_BYTES);
    }

    /// @dev Current global fee growth and fee growth inside the vault's recorded range.
    function _growthNow() internal view returns (Growth memory g) {
        (g.g0, g.g1) = manager.getFeeGrowthGlobals(id);
        (,, int24 lower, int24 upper) = hook.configs(id);
        (g.in0, g.in1) = manager.getFeeGrowthInside(id, lower, upper);
    }

    function _assertSnapshot(IOathHook.Epoch memory e, Growth memory g) internal pure {
        assertEq(e.G0, g.g0, "G0");
        assertEq(e.G1, g.g1, "G1");
        assertEq(e.fgIn0, g.in0, "fgIn0");
        assertEq(e.fgIn1, g.in1, "fgIn1");
    }
}
