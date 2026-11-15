// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {OathHook} from "../../src/OathHook.sol";
import {OathTestBase} from "../utils/OathTestBase.sol";

/// @notice OathHook's exact TWAP accumulator (MATH.md §4) on the real PoolManager.
contract OathHookOracleTest is OathTestBase {
    using StateLibrary for IPoolManager;

    /// @dev The demo pool's start tick on the Nov 8 mainnet fork ($2,235.94 per ETH, MATH.md §9.1).
    int24 internal constant START_TICK = -199196;
    /// @dev Full-range liquidity deep enough to move the price anywhere the tests need.
    uint256 internal constant DEPTH = 1e24;

    address internal factory = makeAddr("factory");
    address internal vault = makeAddr("vault");

    OathHook internal hook;
    PoolId internal id;
    uint32 internal createdAt;

    function setUp() public override {
        super.setUp();
        hook = OathHook(address(_deployOathHook(factory)));
        key = _oathKey(currency0, currency1);
        id = key.toId();
    }

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
    function _bruteForce() internal view returns (int256 sum) {
        uint256 n = segTicks.length;
        for (uint256 i; i < n; i++) {
            uint256 end = i + 1 < n ? segTimes[i + 1] : _time();
            sum += int256(segTicks[i]) * int256(end - segTimes[i]);
        }
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Registers the vault, creates the pool through the factory at `tick`, and adds deep full-range
    ///      liquidity.
    function _createPool(int24 tick) internal {
        vm.prank(factory);
        hook.registerVault(key, vault, 50);
        _initializeAt(tick);
        (int24 tickMin, int24 tickMax) = _fullRange();
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickMin, tickUpper: tickMax, liquidityDelta: int256(DEPTH), salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    /// @dev Live block values. Under via_ir the optimizer may treat `block.timestamp` and `block.number` as
    ///      constant within the test's transaction, so after `vm.warp`/`vm.roll` read them through the cheatcodes.
    function _time() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _block() internal view returns (uint256) {
        return vm.getBlockNumber();
    }

    function _wait(uint256 dt) internal {
        vm.warp(_time() + dt);
    }

    function _nextBlock(uint256 dt) internal {
        vm.roll(_block() + 1);
        vm.warp(_time() + dt);
    }

    function _initializeAt(int24 tick) internal {
        vm.prank(factory);
        manager.initialize(key, TickMath.getSqrtPriceAtTick(tick));
        createdAt = uint32(_time());
        assertEq(_tick(), tick, "created at tick");
    }

    function _moveToTick(int24 tick) internal {
        _moveTo(key, TickMath.getSqrtPriceAtTick(tick));
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(id);
    }

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
