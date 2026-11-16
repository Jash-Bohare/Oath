// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IOathHook} from "../../src/interfaces/IOathHook.sol";
import {OathHookTestBase} from "../utils/OathHookTestBase.sol";

/// @notice OathHook's intra-block manipulation guard on the vault's liquidity changes, and the vault range it
///         records, on the real PoolManager. The vault is a liquidity router registered as the pool's vault.
contract OathHookGuardTest is OathHookTestBase {
    /// @dev The curator range of the worked examples (MATH.md §9.1), around the start tick.
    int24 internal constant LOWER = -199400;
    int24 internal constant UPPER = -199000;
    int256 internal constant L = 1e18;

    function setUp() public override {
        super.setUp();
        _useVaultRouter();
    }

    // ---------------------------------------------------------------- guard: passes

    /// @dev With no swap yet in this block the current tick is the block-start tick, so the vault may act,
    ///      however far the price moved in earlier blocks.
    function test_guard_passesWithNoSwapThisBlock() public {
        _createPool(START_TICK);
        _vaultModify(LOWER, UPPER, L); // creation block, no swap

        _nextBlock(12);
        _moveToTick(START_TICK + 5_000);
        _nextBlock(12);
        _vaultModify(LOWER, UPPER, L);
        _vaultModify(LOWER, UPPER, -L);
    }

    /// @dev A move of exactly `maxIntraBlockTicks` within the block is allowed, up and down, for add and remove.
    function test_guard_passesAtExactlyMax() public {
        _createPool(START_TICK);
        _vaultModify(LOWER, UPPER, L);
        _nextBlock(12);
        uint256 snap = vm.snapshotState();

        _moveToTick(START_TICK + maxIntraBlockTicks);
        assertEq(_tick(), START_TICK + maxIntraBlockTicks, "moved up by max");
        _vaultModify(LOWER, UPPER, L);
        _vaultModify(LOWER, UPPER, -L);

        vm.revertToState(snap);
        _moveToTick(START_TICK - maxIntraBlockTicks);
        assertEq(_tick(), START_TICK - maxIntraBlockTicks, "moved down by max");
        _vaultModify(LOWER, UPPER, L);
        _vaultModify(LOWER, UPPER, -L);
    }

    // ---------------------------------------------------------------- guard: reverts

    /// @dev One tick beyond `maxIntraBlockTicks`, up or down, reverts the vault's add and remove with the
    ///      current and block-start ticks.
    function test_guard_revertsBeyondMax() public {
        _createPool(START_TICK);
        _vaultModify(LOWER, UPPER, L);
        _nextBlock(12);
        uint256 snap = vm.snapshotState();

        int24 up = START_TICK + maxIntraBlockTicks + 1;
        _moveToTick(up);
        assertEq(_tick(), up, "moved up by max + 1");
        _expectGuardRevert(IHooks.beforeAddLiquidity.selector, up);
        _vaultModify(LOWER, UPPER, L);
        _expectGuardRevert(IHooks.beforeRemoveLiquidity.selector, up);
        _vaultModify(LOWER, UPPER, -L);

        vm.revertToState(snap);
        int24 down = START_TICK - maxIntraBlockTicks - 1;
        _moveToTick(down);
        assertEq(_tick(), down, "moved down by max + 1");
        _expectGuardRevert(IHooks.beforeAddLiquidity.selector, down);
        _vaultModify(LOWER, UPPER, L);
        _expectGuardRevert(IHooks.beforeRemoveLiquidity.selector, down);
        _vaultModify(LOWER, UPPER, -L);
    }

    /// @dev A zero-delta modification (which v4 routes to `beforeRemoveLiquidity`) is guarded too.
    function test_guard_coversZeroDeltaModify() public {
        _createPool(START_TICK);
        _vaultModify(LOWER, UPPER, L);
        _nextBlock(12);
        int24 moved = START_TICK + 500;
        _moveToTick(moved);
        _expectGuardRevert(IHooks.beforeRemoveLiquidity.selector, moved);
        _vaultModify(LOWER, UPPER, 0);
    }

    /// @dev The sandwich shape: an attacker moves the price, then the vault tries to act in the same block.
    ///      The block's later swaps do not change where the block started.
    function test_guard_blocksSandwichAfterSeveralSwaps() public {
        _createPool(START_TICK);
        _vaultModify(LOWER, UPPER, L);
        _nextBlock(12);
        _moveToTick(START_TICK + 30);
        _moveToTick(START_TICK - 20);
        int24 pushed = START_TICK + 400;
        _moveToTick(pushed);
        _expectGuardRevert(IHooks.beforeRemoveLiquidity.selector, pushed);
        _vaultModify(LOWER, UPPER, -L);
    }

    /// @dev The guard compares the current tick with the block start, so a move that is reversed within the
    ///      block, back to within `maxIntraBlockTicks`, lets the vault act at a near-start price.
    function test_guard_netMoveIsWhatCounts() public {
        _createPool(START_TICK);
        _vaultModify(LOWER, UPPER, L);
        _nextBlock(12);
        _moveToTick(START_TICK + 800);
        _moveToTick(START_TICK + 10);
        _vaultModify(LOWER, UPPER, -L);
    }

    /// @dev A block in which the price moved too far blocks the vault only in that block.
    function test_guard_clearsInTheNextBlock() public {
        _createPool(START_TICK);
        _vaultModify(LOWER, UPPER, L);
        _nextBlock(12);
        int24 moved = START_TICK + 200;
        _moveToTick(moved);
        _expectGuardRevert(IHooks.beforeRemoveLiquidity.selector, moved);
        _vaultModify(LOWER, UPPER, -L);

        _nextBlock(12);
        _vaultModify(LOWER, UPPER, -L);
    }

    /// @dev For any threshold in the factory's range and any move within the block, the vault's change reverts
    ///      exactly when `|current − blockStart| > maxIntraBlockTicks`.
    function testFuzz_guard_threshold(int24 threshold, int24 offset) public {
        maxIntraBlockTicks = int24(bound(threshold, 1, 1_000));
        offset = int24(bound(offset, -2_000, 2_000));
        _createPool(START_TICK);
        _vaultModify(LOWER, UPPER, L);
        _nextBlock(12);

        _moveToTick(START_TICK + offset);
        int24 current = _tick();
        int256 moved = int256(current) - int256(START_TICK);
        if (moved > maxIntraBlockTicks || moved < -int256(maxIntraBlockTicks)) {
            _expectGuardRevert(IHooks.beforeAddLiquidity.selector, current);
        }
        _vaultModify(LOWER, UPPER, L);
    }

    // ---------------------------------------------------------------- others are never blocked

    /// @dev After a large move within the block, other LPs, swappers and donors still act freely.
    function test_guard_otherUsersNeverBlocked() public {
        _createPool(START_TICK);
        _nextBlock(12);
        _moveToTick(START_TICK + 5_000);

        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        _moveToTick(START_TICK - 5_000);
        donateRouter.donate(key, 1e9, 1e9, ZERO_BYTES);
    }

    // ---------------------------------------------------------------- vault range

    /// @dev Each vault add records its range; the latest add wins.
    function test_range_recordedOnVaultAdd() public {
        _createPool(START_TICK);
        _assertRange(0, 0);
        _vaultModify(LOWER, UPPER, L);
        _assertRange(LOWER, UPPER);
        _vaultModify(-199300, -199100, L);
        _assertRange(-199300, -199100);
    }

    /// @dev Removals, zero-delta modifications and other LPs' adds never change the recorded range.
    function test_range_unchangedByRemovalsAndOthers() public {
        _createPool(START_TICK);
        _vaultModify(LOWER, UPPER, L);

        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        _vaultModify(LOWER, UPPER, 0);
        _vaultModify(LOWER, UPPER, -L / 2);
        _assertRange(LOWER, UPPER);
    }

    /// @dev A guarded-out add records nothing.
    function test_range_notRecordedWhenGuardReverts() public {
        _createPool(START_TICK);
        _vaultModify(LOWER, UPPER, L);
        _nextBlock(12);
        int24 moved = START_TICK + 500;
        _moveToTick(moved);
        _expectGuardRevert(IHooks.beforeAddLiquidity.selector, moved);
        _vaultModify(-199300, -199100, L);
        _assertRange(LOWER, UPPER);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Expects the guard's revert from `callback`, wrapped by the PoolManager, with the block-start tick
    ///      `START_TICK` (every test's block starts there).
    function _expectGuardRevert(bytes4 callback, int24 current) internal {
        vm.expectRevert(
            _hookError(callback, abi.encodeWithSelector(IOathHook.PriceMovedThisBlock.selector, current, START_TICK))
        );
    }

    function _assertRange(int24 lower, int24 upper) internal view {
        (,, int24 vaultLower, int24 vaultUpper) = hook.configs(id);
        assertEq(vaultLower, lower, "vaultLower");
        assertEq(vaultUpper, upper, "vaultUpper");
    }
}
