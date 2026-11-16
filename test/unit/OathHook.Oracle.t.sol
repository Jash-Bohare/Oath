// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IOathHook} from "../../src/interfaces/IOathHook.sol";
import {OathHook} from "../../src/OathHook.sol";
import {OathTestBase} from "../utils/OathTestBase.sol";
import {OathHookTestBase} from "../utils/OathHookTestBase.sol";

/// @notice OathHook's exact TWAP accumulator and epoch checkpoints (MATH.md §4) on the real PoolManager.
contract OathHookOracleTest is OathHookTestBase {
    // ---------------------------------------------------------------- start

    function test_oracle_initializeStartsAccumulator() public {
        _createPool(START_TICK);
        _assertOracle(0, createdAt);
        assertEq(hook.cumulativeNow(key), 0, "zero at creation");

        _wait(100);
        assertEq(hook.cumulativeNow(key), int256(START_TICK) * 100, "start tick held for 100 s");
        _assertOracle(0, createdAt); // a view never writes
    }

    /// @dev A poke on a registered pool before it exists reads tick 0 and adds 0; creation then restarts the
    ///      clock, so the accumulator still counts only from creation.
    function test_oracle_pokeBeforeInitializeIsHarmless() public {
        vm.prank(factory);
        hook.registerVault(key, vault, 50);
        _wait(1_000);
        hook.poke(key);

        _wait(1_000);
        _initializeAt(START_TICK);
        _wait(60);
        assertEq(hook.cumulativeNow(key), int256(START_TICK) * 60);
    }

    // ---------------------------------------------------------------- swaps

    /// @dev `beforeSwap` runs before the price moves: it books the old tick up to now, and the new tick
    ///      counts only from now on.
    function test_oracle_swapAdvancesWithTickBeforeSwap() public {
        _createPool(START_TICK);
        _wait(100);
        _moveToTick(START_TICK + 1_234);
        int24 t1 = _tick();
        assertTrue(t1 != START_TICK, "price moved");
        _assertOracle(int256(START_TICK) * 100, createdAt + 100);

        _wait(50);
        assertEq(hook.cumulativeNow(key), int256(START_TICK) * 100 + int256(t1) * 50);
    }

    /// @dev Swaps in the same block add nothing; only the tick left by the block's last swap counts afterwards.
    function test_oracle_sameBlockSwapsAddNothing() public {
        _createPool(START_TICK);
        _wait(100);
        _moveToTick(START_TICK - 500);
        _moveToTick(START_TICK + 700);
        _moveToTick(START_TICK + 300);
        int24 last = _tick();
        _assertOracle(int256(START_TICK) * 100, createdAt + 100);

        _wait(10);
        assertEq(hook.cumulativeNow(key), int256(START_TICK) * 100 + int256(last) * 10);
    }

    /// @dev Many intervals, both signs of tick, checked against the hand-computed Σ tick·dt.
    function test_oracle_multiStepSum() public {
        _createPool(-5_000);
        int256 expected;
        int24[4] memory targets = [int24(3_000), int24(-12_000), int24(0), int24(45_000)];
        uint32[4] memory waits = [uint32(1), 7 days, 13, 3_600];
        for (uint256 i; i < 4; i++) {
            expected += int256(_tick()) * int256(uint256(waits[i]));
            _wait(waits[i]);
            vm.roll(_block() + 1);
            _moveToTick(targets[i]);
            assertEq(hook.cumulativeNow(key), expected, "after swap");
        }
        expected += int256(_tick()) * 77;
        _wait(77);
        assertEq(hook.cumulativeNow(key), expected, "end");
    }

    // ---------------------------------------------------------------- other paths

    function test_oracle_pokeAdvances() public {
        _createPool(START_TICK);
        _wait(321);
        int256 before = hook.cumulativeNow(key);
        vm.prank(alice);
        hook.poke(key);
        _assertOracle(before, uint32(_time()));
        assertEq(hook.cumulativeNow(key), before, "nothing double-counted");
    }

    function test_oracle_donateAdvances() public {
        _createPool(START_TICK);
        _wait(321);
        int256 before = hook.cumulativeNow(key);
        donateRouter.donate(key, 1e9, 1e9, ZERO_BYTES);
        _assertOracle(before, uint32(_time()));
    }

    /// @dev From the same state, a poke, a donation and a swap leave the accumulator identical: the swap
    ///      advances before it moves the price.
    function test_oracle_pokeDonateAndSwapPathsAgree() public {
        _createPool(START_TICK);
        _wait(1 hours);
        uint256 snap = vm.snapshotState();

        hook.poke(key);
        (uint32 tsPoke,,, int256 cumPoke) = hook.oracles(id);

        vm.revertToState(snap);
        donateRouter.donate(key, 1e9, 1e9, ZERO_BYTES);
        (uint32 tsDonate,,, int256 cumDonate) = hook.oracles(id);

        vm.revertToState(snap);
        _moveToTick(START_TICK + 90);
        (uint32 tsSwap,,, int256 cumSwap) = hook.oracles(id);

        assertEq(cumPoke, int256(START_TICK) * 1 hours);
        assertEq(cumDonate, cumPoke, "donate == poke");
        assertEq(cumSwap, cumPoke, "swap == poke");
        assertEq(tsDonate, tsPoke);
        assertEq(tsSwap, tsPoke);
    }

    /// @dev The vault advances the accumulator when it opens an epoch.
    function test_oracle_openEpochAdvances() public {
        _createPool(START_TICK);
        _wait(45 minutes);
        vm.prank(vault);
        hook.openEpoch(key, uint32(_time() + 7 days), 30 minutes);
        _assertOracle(int256(START_TICK) * 45 minutes, uint32(_time()));
    }

    /// @dev Liquidity changes cannot move the tick, so they leave the accumulator alone and it stays exact.
    function test_oracle_liquidityChangesDoNotAdvance() public {
        _createPool(START_TICK);
        _wait(500);
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        _assertOracle(0, createdAt);
        assertEq(hook.cumulativeNow(key), int256(START_TICK) * 500);
    }

    // ---------------------------------------------------------------- block-start tick

    /// @dev The first swap of a block records the tick before it moves the price; later swaps in the same
    ///      block leave the record alone; the next block's first swap records afresh.
    function test_oracle_firstSwapOfBlockRecordsStartTick() public {
        _createPool(START_TICK);
        _nextBlock(12);
        uint256 blockA = _block();

        _moveToTick(START_TICK + 200);
        _assertBlockStart(blockA, START_TICK);
        _moveToTick(START_TICK + 500);
        _moveToTick(START_TICK - 300);
        _assertBlockStart(blockA, START_TICK);

        _nextBlock(12);
        int24 startOfB = _tick();
        _moveToTick(START_TICK + 40);
        _assertBlockStart(blockA + 1, startOfB);
    }

    /// @dev A swap in the pool's creation block records the creation tick.
    function test_oracle_swapInCreationBlockRecordsCreationTick() public {
        _createPool(START_TICK);
        _moveToTick(START_TICK + 77);
        _assertBlockStart(_block(), START_TICK);
    }

    /// @dev Only swaps move the price, so only swaps touch the block-start record.
    function test_oracle_onlySwapsTrackBlockStart() public {
        _createPool(START_TICK);
        _moveToTick(START_TICK + 10);
        uint256 swapBlock = _block();

        _nextBlock(12);
        hook.poke(key);
        donateRouter.donate(key, 1e9, 1e9, ZERO_BYTES);
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        vm.prank(vault);
        hook.openEpoch(key, uint32(_time() + 7 days), 30 minutes);
        _assertBlockStart(swapBlock, START_TICK);
    }

    // ---------------------------------------------------------------- checkpoints

    /// @dev Checkpoints are exact even when the first action after them comes hours later: A is recorded by a
    ///      swap 3 h after it, B by a poke 4 h after the epoch end, each with the tick that held at its time.
    function test_oracle_checkpointsExactWhenFirstActionIsHoursLater() public {
        _createPool(START_TICK);
        uint32 epochEnd = uint32(_time() + 1 days);
        uint32 checkpointA = epochEnd - 6 hours;
        _openEpoch(epochEnd, 6 hours);

        _wait(2 hours);
        _moveToTick(START_TICK + 400);
        int24 t1 = _tick();
        uint32 s1 = uint32(_time());
        int256 cumS1 = int256(START_TICK) * int256(uint256(s1 - createdAt));

        vm.warp(checkpointA + 3 hours);
        _moveToTick(START_TICK - 250);
        int24 t2 = _tick();
        uint32 s2 = uint32(_time());
        IOathHook.Epoch memory e = hook.epochData(key);
        assertTrue(e.doneA && !e.doneB, "only A due");
        int256 expectedA = cumS1 + int256(t1) * int256(uint256(checkpointA - s1));
        assertEq(e.cumA, expectedA, "cumA exact at E - W");

        vm.warp(epochEnd + 4 hours);
        hook.poke(key);
        e = hook.epochData(key);
        int256 cumS2 = cumS1 + int256(t1) * int256(uint256(s2 - s1));
        assertTrue(e.doneB, "B recorded");
        assertEq(e.cumB, cumS2 + int256(t2) * int256(uint256(epochEnd - s2)), "cumB exact at E");
    }

    /// @dev One action long after the epoch end records both checkpoints, each at its own time.
    function test_oracle_bothCheckpointsByOneLateAction() public {
        _createPool(START_TICK);
        uint32 epochEnd = uint32(_time() + 1 days);
        _openEpoch(epochEnd, 30 minutes);

        vm.warp(epochEnd + 10 hours);
        _moveToTick(START_TICK + 1_000);
        IOathHook.Epoch memory e = hook.epochData(key);
        assertTrue(e.doneA && e.doneB, "both recorded");
        assertEq(e.cumA, int256(START_TICK) * int256(uint256(epochEnd - 30 minutes - createdAt)), "cumA");
        assertEq(e.cumB, int256(START_TICK) * int256(uint256(epochEnd - createdAt)), "cumB");
    }

    /// @dev A checkpoint is due at its own second (`t* ≤ now`), not one second earlier.
    function test_oracle_checkpointDueAtItsOwnSecond() public {
        _createPool(START_TICK);
        uint32 epochEnd = uint32(_time() + 1 days);
        uint32 checkpointA = epochEnd - 30 minutes;
        _openEpoch(epochEnd, 30 minutes);

        vm.warp(checkpointA - 1);
        hook.poke(key);
        assertFalse(hook.epochData(key).doneA, "not due at E - W - 1");

        vm.warp(checkpointA);
        hook.poke(key);
        IOathHook.Epoch memory e = hook.epochData(key);
        assertTrue(e.doneA && !e.doneB, "A due at E - W");
        assertEq(e.cumA, int256(START_TICK) * int256(uint256(checkpointA - createdAt)));

        vm.warp(epochEnd - 1);
        hook.poke(key);
        assertFalse(hook.epochData(key).doneB, "not due at E - 1");
        vm.warp(epochEnd);
        hook.poke(key);
        assertEq(hook.epochData(key).cumB, int256(START_TICK) * int256(uint256(epochEnd - createdAt)), "B at E");
    }

    /// @dev From the same state, a poke, a donation and a swap record the same checkpoint.
    function test_oracle_checkpointPathsAgree() public {
        _createPool(START_TICK);
        uint32 epochEnd = uint32(_time() + 1 days);
        _openEpoch(epochEnd, 6 hours);
        _wait(3 hours);
        _moveToTick(START_TICK + 123);
        vm.warp(epochEnd - 1 hours);
        uint256 snap = vm.snapshotState();

        hook.poke(key);
        int256 viaPoke = hook.epochData(key).cumA;

        vm.revertToState(snap);
        donateRouter.donate(key, 1e9, 1e9, ZERO_BYTES);
        int256 viaDonate = hook.epochData(key).cumA;

        vm.revertToState(snap);
        _moveToTick(START_TICK - 900);
        int256 viaSwap = hook.epochData(key).cumA;

        assertTrue(viaPoke != 0, "recorded");
        assertEq(viaDonate, viaPoke, "donate == poke");
        assertEq(viaSwap, viaPoke, "swap == poke");
    }

    function test_oracle_checkpointEvents() public {
        _createPool(START_TICK);
        uint32 epochEnd = uint32(_time() + 1 days);
        _openEpoch(epochEnd, 30 minutes);
        vm.warp(epochEnd + 1);

        vm.expectEmit(true, false, false, true, address(hook));
        emit IOathHook.CheckpointRecorded(
            id, epochEnd - 30 minutes, int256(START_TICK) * int256(uint256(epochEnd - 30 minutes - createdAt))
        );
        vm.expectEmit(true, false, false, true, address(hook));
        emit IOathHook.CheckpointRecorded(id, epochEnd, int256(START_TICK) * int256(uint256(epochEnd - createdAt)));
        hook.poke(key);
    }

    /// @dev Without an open epoch nothing is recorded, however much time passes.
    function test_oracle_noCheckpointWithoutEpoch() public {
        _createPool(START_TICK);
        _wait(30 days);
        hook.poke(key);
        IOathHook.Epoch memory e = hook.epochData(key);
        assertEq(abi.encode(e), abi.encode(IOathHook.Epoch(0, 0, false, false, false, false, 0, 0, 0, 0, 0, 0)));
    }

    /// @dev The internal consistency check: a checkpoint at or before `lastTimestamp` reverts. Unreachable
    ///      through the hook's own functions, so the oracle's `lastTimestamp` is corrupted with `vm.store`.
    function test_oracle_checkpointInPastReverts() public {
        _createPool(START_TICK);
        uint32 epochEnd = uint32(_time() + 1 days);
        uint32 checkpointA = epochEnd - 30 minutes;
        _openEpoch(epochEnd, 30 minutes);

        bytes32 slot = keccak256(abi.encode(PoolId.unwrap(id), uint256(0))); // oracles[id], first word
        uint256 word = uint256(vm.load(address(hook), slot));
        (uint32 lastTimestamp,,,) = hook.oracles(id);
        assertEq(uint32(word), lastTimestamp, "slot layout");
        vm.store(address(hook), slot, bytes32((word & ~uint256(type(uint32).max)) | checkpointA));

        vm.warp(checkpointA + 10);
        vm.expectRevert(IOathHook.CheckpointInPast.selector);
        hook.poke(key);
    }

    /// @dev Both checkpoints equal the brute-force cumulative at exactly `E − W` and `E`, for any history of
    ///      swaps, donations, pokes and time jumps across the epoch.
    function testFuzz_oracle_checkpointsMatchBruteForce(uint256 seed, uint32 twapWindow) public {
        _createPool(START_TICK);
        _record();
        uint32 epochEnd = uint32(_time() + 1 days);
        twapWindow = uint32(bound(twapWindow, 1, 1 days - 1));
        _openEpoch(epochEnd, twapWindow);

        for (uint256 i; i < 16; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            if (r % 4 != 0) _nextBlock(1 + (r >> 8) % 6 hours);
            uint256 action = (r >> 64) % 4;
            if (action <= 1) {
                _moveToTick(START_TICK + int24(int256((r >> 96) % 20_001)) - 10_000);
            } else if (action == 2) {
                donateRouter.donate(key, 1e6, 1e6, ZERO_BYTES);
            } else {
                hook.poke(key);
            }
            _record();
        }
        if (_time() < epochEnd) vm.warp(epochEnd + seed % 1 days);
        hook.poke(key);

        IOathHook.Epoch memory e = hook.epochData(key);
        assertTrue(e.doneA && e.doneB, "both recorded");
        assertEq(e.cumA, _bruteForceAt(epochEnd - twapWindow), "cumA");
        assertEq(e.cumB, _bruteForceAt(epochEnd), "cumB");
    }

    // ---------------------------------------------------------------- brute force

    /// @dev Every (time, tick) segment the pool has been through since creation.
    uint256[] internal segTimes;
    int24[] internal segTicks;

    /// @dev `cumulativeNow` equals the brute-force Σ tick·dt over the pool's whole history, after any sequence
    ///      of swaps (moving or not, several per block), donations, pokes, liquidity changes and time jumps
    ///      from 0 s to 2 days. The reference re-sums every segment from scratch at each check, sharing nothing
    ///      with the hook's incremental update.
    function testFuzz_oracle_matchesBruteForce(uint256 seed, int24 startTick) public {
        startTick = int24(bound(startTick, -400_000, 400_000));
        _createPool(startTick);
        _record();
        assertEq(hook.cumulativeNow(key), 0, "creation");

        for (uint256 i; i < 24; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            // Half the steps stay in the same block (0 s); the rest jump up to 2 days ahead.
            if (r % 2 == 1) _nextBlock(1 + (r >> 8) % 2 days);

            uint256 action = (r >> 64) % 6;
            if (action <= 1) {
                // Move to a target up to ±50,000 ticks from the start tick.
                _moveToTick(startTick + int24(int256((r >> 96) % 100_001)) - 50_000);
            } else if (action == 2) {
                // A small swap that may not move the tick at all.
                swap(key, (r >> 96) % 2 == 0, -int256(1 + (r >> 128) % 1e12), ZERO_BYTES);
            } else if (action == 3) {
                donateRouter.donate(key, 1e6, 1e6, ZERO_BYTES);
            } else if (action == 4) {
                hook.poke(key);
            } else {
                modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
                modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
            }
            _record();
            assertEq(hook.cumulativeNow(key), _bruteForce(), "after step");
        }

        _wait(seed % 3 days);
        assertEq(hook.cumulativeNow(key), _bruteForce(), "end");
        hook.poke(key);
        (uint32 ts,,, int256 stored) = hook.oracles(id);
        assertEq(stored, _bruteForce(), "stored after poke");
        assertEq(ts, _time(), "lastTimestamp after poke");
    }

    /// @dev Appends the current (time, tick) if the tick changed since the last segment.
    function _record() internal {
        int24 tick = _tick();
        uint256 n = segTicks.length;
        if (n == 0 || segTicks[n - 1] != tick) {
            segTimes.push(_time());
            segTicks.push(tick);
        }
    }

    /// @dev Σ tick_i · (t_{i+1} − t_i) over all segments, the last one running to now.
    function _bruteForce() internal view returns (int256) {
        return _bruteForceAt(_time());
    }

    /// @dev The same sum cut off at time `t` (segments starting at or after `t` add nothing).
    function _bruteForceAt(uint256 t) internal view returns (int256 sum) {
        uint256 n = segTicks.length;
        for (uint256 i; i < n && segTimes[i] < t; i++) {
            uint256 end = i + 1 < n && segTimes[i + 1] < t ? segTimes[i + 1] : t;
            sum += int256(segTicks[i]) * int256(end - segTimes[i]);
        }
    }

    // ---------------------------------------------------------------- helpers

    function _assertOracle(int256 tickCumulative, uint32 lastTimestamp) internal view {
        (uint32 ts,,, int256 cum) = hook.oracles(id);
        assertEq(cum, tickCumulative, "tickCumulative");
        assertEq(ts, lastTimestamp, "lastTimestamp");
    }

    function _assertBlockStart(uint256 blockNumber, int24 tick) internal view {
        (, uint64 lastSwapBlock, int24 blockStartTick,) = hook.oracles(id);
        assertEq(lastSwapBlock, blockNumber, "lastSwapBlock");
        assertEq(blockStartTick, tick, "blockStartTick");
    }
}

/// @notice `beforeSwap` gas on a pool in steady state: created, swapped and advanced in earlier transactions
///         (`setUp`), so the oracle's slots already hold non-zero values, as on a live pool, with an epoch in
///         progress and no checkpoint due.
/// @dev These tests turn test isolation off, so each test is one transaction: with isolation every top-level
///      call would be a separate transaction, always cold and including the 21,000 transaction base cost.
contract OathHookSwapGasTest is OathTestBase {
    address internal factory = makeAddr("factory");

    OathHook internal hook;
    PoolId internal id;

    function setUp() public override {
        super.setUp();
        hook = OathHook(address(_deployOathHook(factory)));
        key = _oathKey(currency0, currency1);
        id = key.toId();
        vm.prank(factory);
        hook.registerVault(key, makeAddr("vault"), 50);
        vm.prank(factory);
        manager.initialize(key, TickMath.getSqrtPriceAtTick(-199196));
        (int24 tickMin, int24 tickMax) = _fullRange();
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: tickMin, tickUpper: tickMax, liquidityDelta: 1e24, salt: 0}), ""
        );
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 60);
        _moveTo(key, TickMath.getSqrtPriceAtTick(-199100));
        vm.prank(makeAddr("vault"));
        hook.openEpoch(key, uint32(vm.getBlockTimestamp() + 7 days), 30 minutes);
        // The tests run in the next block.
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
    }

    /// @dev Bound: at most 15,000 gas warm in steady state with no checkpoint due, both for the first swap of a
    ///      block (which also records the block-start tick) and for a later swap in the same block. Slots are
    ///      warmed by reads only, so their original values are the steady-state ones.
    /// forge-config: default.isolate = false
    function test_gas_beforeSwapWarmSteadyState() public {
        hook.oracles(id);
        hook.cumulativeNow(key);
        hook.epochData(key);

        uint256 firstOfBlock = _beforeSwapGas();
        uint256 sameBlock = _beforeSwapGas();
        emit log_named_uint("beforeSwap gas, warm, first swap of block", firstOfBlock);
        emit log_named_uint("beforeSwap gas, warm, same block", sameBlock);
        assertLe(firstOfBlock, 15_000, "first swap of block");
        assertLe(sameBlock, 15_000, "same block");
    }

    /// @dev Reported, not bounded: the first `beforeSwap` of a transaction pays cold account and storage access.
    /// forge-config: default.isolate = false
    function test_gas_beforeSwapColdReport() public {
        emit log_named_uint("beforeSwap gas, cold, first swap of block", _beforeSwapGas());
    }

    /// @dev Gas of one `beforeSwap` call made as the PoolManager makes it, from pre-encoded calldata. Includes the
    ///      `CALL` itself, so it slightly overstates the hook's own cost.
    function _beforeSwapGas() internal returns (uint256 used) {
        bytes memory data = abi.encodeCall(
            IHooks.beforeSwap,
            (
                address(swapRouter),
                key,
                SwapParams({zeroForOne: true, amountSpecified: -1e6, sqrtPriceLimitX96: 0}),
                ZERO_BYTES
            )
        );
        address target = address(hook);
        vm.prank(address(manager));
        used = gasleft();
        (bool ok,) = target.call(data);
        used -= gasleft();
        assertTrue(ok, "beforeSwap succeeded");
    }
}
