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

        vm.warp(block.timestamp + 100);
        assertEq(hook.cumulativeNow(key), int256(START_TICK) * 100, "start tick held for 100 s");
        _assertOracle(0, createdAt); // a view never writes
    }

    /// @dev A poke on a registered pool before it exists reads tick 0 and adds 0; creation then restarts the
    ///      clock, so the accumulator still counts only from creation.
    function test_oracle_pokeBeforeInitializeIsHarmless() public {
        vm.prank(factory);
        hook.registerVault(key, vault, 50);
        vm.warp(block.timestamp + 1_000);
        hook.poke(key);

        vm.warp(block.timestamp + 1_000);
        _initializeAt(START_TICK);
        vm.warp(block.timestamp + 60);
        assertEq(hook.cumulativeNow(key), int256(START_TICK) * 60);
    }

    // ---------------------------------------------------------------- swaps

    /// @dev `beforeSwap` runs before the price moves: it books the old tick up to now, and the new tick
    ///      counts only from now on.
    function test_oracle_swapAdvancesWithTickBeforeSwap() public {
        _createPool(START_TICK);
        vm.warp(block.timestamp + 100);
        _moveToTick(START_TICK + 1_234);
        int24 t1 = _tick();
        assertTrue(t1 != START_TICK, "price moved");
        _assertOracle(int256(START_TICK) * 100, createdAt + 100);

        vm.warp(block.timestamp + 50);
        assertEq(hook.cumulativeNow(key), int256(START_TICK) * 100 + int256(t1) * 50);
    }

    /// @dev Swaps in the same block add nothing; only the tick left by the block's last swap counts afterwards.
    function test_oracle_sameBlockSwapsAddNothing() public {
        _createPool(START_TICK);
        vm.warp(block.timestamp + 100);
        _moveToTick(START_TICK - 500);
        _moveToTick(START_TICK + 700);
        _moveToTick(START_TICK + 300);
        int24 last = _tick();
        _assertOracle(int256(START_TICK) * 100, createdAt + 100);

        vm.warp(block.timestamp + 10);
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
            vm.warp(block.timestamp + waits[i]);
            vm.roll(block.number + 1);
            _moveToTick(targets[i]);
            assertEq(hook.cumulativeNow(key), expected, "after swap");
        }
        expected += int256(_tick()) * 77;
        vm.warp(block.timestamp + 77);
        assertEq(hook.cumulativeNow(key), expected, "end");
    }

    // ---------------------------------------------------------------- other paths

    function test_oracle_pokeAdvances() public {
        _createPool(START_TICK);
        vm.warp(block.timestamp + 321);
        int256 before = hook.cumulativeNow(key);
        vm.prank(alice);
        hook.poke(key);
        _assertOracle(before, uint32(block.timestamp));
        assertEq(hook.cumulativeNow(key), before, "nothing double-counted");
    }

    function test_oracle_donateAdvances() public {
        _createPool(START_TICK);
        vm.warp(block.timestamp + 321);
        int256 before = hook.cumulativeNow(key);
        donateRouter.donate(key, 1e9, 1e9, ZERO_BYTES);
        _assertOracle(before, uint32(block.timestamp));
    }

    /// @dev From the same state, a poke, a donation and a swap leave the accumulator identical: the swap
    ///      advances before it moves the price.
    function test_oracle_pokeDonateAndSwapPathsAgree() public {
        _createPool(START_TICK);
        vm.warp(block.timestamp + 1 hours);
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
        vm.warp(block.timestamp + 45 minutes);
        vm.prank(vault);
        hook.openEpoch(key, uint32(block.timestamp + 7 days), 30 minutes);
        _assertOracle(int256(START_TICK) * 45 minutes, uint32(block.timestamp));
    }

    /// @dev Liquidity changes cannot move the tick, so they leave the accumulator alone and it stays exact.
    function test_oracle_liquidityChangesDoNotAdvance() public {
        _createPool(START_TICK);
        vm.warp(block.timestamp + 500);
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        _assertOracle(0, createdAt);
        assertEq(hook.cumulativeNow(key), int256(START_TICK) * 500);
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

    function _initializeAt(int24 tick) internal {
        vm.prank(factory);
        manager.initialize(key, TickMath.getSqrtPriceAtTick(tick));
        createdAt = uint32(block.timestamp);
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
}
