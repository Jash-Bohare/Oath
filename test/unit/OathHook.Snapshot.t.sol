// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IOathHook} from "../../src/interfaces/IOathHook.sol";
import {ValuationLib} from "../../src/libraries/ValuationLib.sol";
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

    /// @dev Fees earned in the final TWAP window `[E − W, E)`, after checkpoint A is recorded, are in the
    ///      snapshot: it is taken at `E`, not at `E − W`.
    function test_snapshot_includesFeesUpToE() public {
        _tradeDuringEpoch();
        vm.warp(epochEnd - 10 minutes);
        _moveToTick(START_TICK + 1_500);
        assertTrue(hook.epochData(key).doneA, "checkpoint A recorded");
        vm.warp(epochEnd - 1);
        _moveToTick(START_TICK - 1_500);
        Growth memory atE = _growthNow();

        vm.warp(epochEnd + 1);
        hook.poke(key);
        _assertSnapshot(hook.epochData(key), atE);
    }

    // ---------------------------------------------------------------- exactness across paths

    /// @dev From the same state after `E`, a swap, a donation and a poke store the identical epoch record, equal
    ///      to the fee growth at `E`.
    function test_snapshot_identicalViaSwapDonateAndPoke() public {
        _tradeDuringEpoch();
        vm.warp(epochEnd + 1 hours);
        Growth memory atE = _growthNow();
        uint256 snap = vm.snapshotState();

        hook.poke(key);
        bytes memory viaPoke = abi.encode(hook.epochData(key));

        vm.revertToState(snap);
        donateRouter.donate(key, 1e15, 1e12, ZERO_BYTES);
        bytes memory viaDonate = abi.encode(hook.epochData(key));

        vm.revertToState(snap);
        _moveToTick(START_TICK + 2_000);
        bytes memory viaSwap = abi.encode(hook.epochData(key));

        assertEq(viaDonate, viaPoke, "donate == poke");
        assertEq(viaSwap, viaPoke, "swap == poke");
        _assertSnapshot(abi.decode(viaPoke, (IOathHook.Epoch)), atE);
    }

    /// @dev The first swap after `E` earns fees, but the snapshot is taken before it trades.
    function test_snapshot_excludesFirstPostESwapFees() public {
        _tradeDuringEpoch();
        vm.warp(epochEnd + 1);
        Growth memory atE = _growthNow();

        _moveToTick(START_TICK + 2_000); // zeroForOne = false: currency1 fees
        _moveToTick(START_TICK - 2_000); // same block, other way: currency0 fees
        IOathHook.Epoch memory e = hook.epochData(key);
        _assertSnapshot(e, atE);
        Growth memory after_ = _growthNow();
        assertGt(after_.g0, e.G0, "post-E currency0 fees excluded");
        assertGt(after_.g1, e.G1, "post-E currency1 fees excluded");
    }

    /// @dev A donation as the first action after `E` is excluded: `beforeDonate` snapshots before it lands.
    function test_snapshot_excludesPostEDonation() public {
        _tradeDuringEpoch();
        vm.warp(epochEnd + 1);
        Growth memory atE = _growthNow();

        donateRouter.donate(key, 1e18, 1e18, ZERO_BYTES);
        IOathHook.Epoch memory e = hook.epochData(key);
        _assertSnapshot(e, atE);
        Growth memory after_ = _growthNow();
        assertGt(after_.g0, e.G0, "donation excluded (currency0)");
        assertGt(after_.g1, e.G1, "donation excluded (currency1)");
    }

    /// @dev The whole epoch record (both checkpoints and the snapshot) is the same whether or not anything
    ///      happens between `E` and the record being read.
    function test_snapshot_sameWithOrWithoutPostEActivity() public {
        _tradeDuringEpoch();
        uint256 snap = vm.snapshotState();

        vm.warp(epochEnd + 3 hours);
        hook.poke(key);
        bytes memory quiet = abi.encode(hook.epochData(key));

        vm.revertToState(snap);
        vm.warp(epochEnd);
        _moveToTick(START_TICK + 5_000);
        _nextBlock(1 hours);
        donateRouter.donate(key, 1e18, 1e18, ZERO_BYTES);
        _nextBlock(1 hours);
        _moveToTick(START_TICK - 5_000);
        _nextBlock(1 hours);
        hook.poke(key);
        bytes memory busy = abi.encode(hook.epochData(key));

        assertEq(busy, quiet, "post-E activity changes nothing");
    }

    /// @dev For any history of swaps, donations and liquidity changes during the epoch, a snapshot taken by any
    ///      path at any time after `E` equals the fee growth read directly after the last action before `E`.
    function testFuzz_snapshot_equalsGrowthAtE(uint256 seed) public {
        for (uint256 i; i < 12; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            _nextBlock(1 + (r >> 8) % 2 hours); // 12 steps of at most 2 h stay inside the 1-day epoch
            uint256 action = (r >> 64) % 4;
            if (action <= 1) {
                _moveToTick(START_TICK + int24(int256((r >> 96) % 10_001)) - 5_000);
            } else if (action == 2) {
                donateRouter.donate(key, 1 + (r >> 96) % 1e15, 1 + (r >> 160) % 1e12, ZERO_BYTES);
            } else {
                modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
                modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
            }
        }
        assertLt(_time(), epochEnd, "history stayed before E");
        // A last trade one second before E, inside the final window.
        vm.warp(epochEnd - 1);
        _moveToTick(START_TICK + int24(int256(seed % 4_001)) - 2_000);
        Growth memory atE = _growthNow();

        vm.warp(epochEnd + seed % 2 days);
        uint256 path = (seed >> 128) % 3;
        if (path == 0) _moveToTick(START_TICK + 7_000);
        else if (path == 1) donateRouter.donate(key, 1e15, 1e12, ZERO_BYTES);
        else hook.poke(key);

        _assertSnapshot(hook.epochData(key), atE);
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

/// @notice The snapshot with a real vault position: fee growth inside the range the vault recorded, so the vault's
///         uncollected fees at `E` (MATH.md §7) are exactly what a withdrawal at `E` pays.
contract OathHookSnapshotVaultRangeTest is OathHookTestBase {
    using StateLibrary for IPoolManager;

    int24 internal constant LOWER = -199400;
    int24 internal constant UPPER = -199000;

    uint32 internal epochEnd;

    function setUp() public override {
        super.setUp();
        _useVaultRouter();
        _createPool(START_TICK);
        epochEnd = uint32(_time() + 1 days);
        _openEpoch(epochEnd, 30 minutes);
    }

    /// @dev The vault's position earns fees through swaps inside, across and outside its range and a donation.
    ///      At `E` the snapshot's fee growth inside the vault's range, with the position's last marks, gives fees
    ///      that, with the principal at the end price, equal a real withdrawal to the wei.
    function test_snapshot_vaultFeesAtEMatchRealWithdrawal() public {
        _vaultModify(LOWER, UPPER, 1e20);
        _nextBlock(1 hours);
        _moveToTick(START_TICK + 150); // inside the range
        _nextBlock(1 hours);
        _moveToTick(START_TICK - 350); // below the range: crosses its lower tick
        _nextBlock(1 hours);
        _moveToTick(START_TICK + 100); // back inside
        donateRouter.donate(key, 1e12, 1e9, ZERO_BYTES);

        vm.warp(epochEnd + 1);
        vm.roll(_block() + 1);
        hook.poke(key);
        IOathHook.Epoch memory e = hook.epochData(key);

        (,, int24 vaultLower, int24 vaultUpper) = hook.configs(id);
        assertEq(vaultLower, LOWER, "recorded lower");
        assertEq(vaultUpper, UPPER, "recorded upper");
        (uint256 in0, uint256 in1) = manager.getFeeGrowthInside(id, LOWER, UPPER);
        assertEq(e.fgIn0, in0, "fgIn0 is the vault range's");
        assertEq(e.fgIn1, in1, "fgIn1 is the vault range's");

        (uint128 liquidity, uint256 last0, uint256 last1) =
            manager.getPositionInfo(id, address(vaultRouter), LOWER, UPPER, bytes32(0));
        uint256 fees0 = ValuationLib.feesOwed(liquidity, last0, e.fgIn0);
        uint256 fees1 = ValuationLib.feesOwed(liquidity, last1, e.fgIn1);
        assertGt(fees0, 0, "currency0 fees");
        assertGt(fees1, 0, "currency1 fees");
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(id);
        (uint256 p0, uint256 p1) = ValuationLib.principal(liquidity, LOWER, UPPER, sqrtPriceX96);

        BalanceDelta out = _vaultModify(LOWER, UPPER, -int256(uint256(liquidity)));
        assertEq(uint256(int256(out.amount0())), p0 + fees0, "currency0: principal + fees, to the wei");
        assertEq(uint256(int256(out.amount1())), p1 + fees1, "currency1: principal + fees, to the wei");
    }
}
