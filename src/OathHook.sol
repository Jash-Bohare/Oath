// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IOathHook} from "./interfaces/IOathHook.sol";

/// @title OathHook
/// @notice The Oath pool's referee. It holds no funds and never changes swap amounts or fees. Pools with this
///         hook can only be created by `OathFactory`, which registers exactly one vault per pool.
/// @dev Permissions are the five `before*` hooks only (address flags `0x2AA0`); no hook returns a delta.
contract OathHook is BaseHook, IOathHook {
    using StateLibrary for IPoolManager;

    /// @notice The only address allowed to register vaults and initialize pools with this hook.
    /// @dev Lower-case because it implements `IOathHook.factory()`.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable factory;

    /// @notice Per-pool TWAP accumulator state (MATH.md §4).
    mapping(PoolId => IOathHook.Oracle) public oracles;
    /// @notice Per-pool epoch checkpoints and boundary snapshot (MATH.md §5, §8). Read with `epochData`.
    mapping(PoolId => IOathHook.Epoch) internal epochs;
    /// @notice Per-pool registered vault, guard threshold and vault range.
    mapping(PoolId => IOathHook.PoolConfig) public configs;

    /// @param manager The Uniswap v4 PoolManager.
    /// @param factory_ The OathFactory, the only address allowed to register vaults and create pools.
    /// @dev `BaseHook` reverts unless this contract's address carries exactly the permission flags below.
    ///      No zero check on `factory_`: a hook with a zero factory can never register a vault, so it can
    ///      never get a pool, and the factory's constructor checks `hook.factory() == address(this)`.
    // Slither: no zero check, as explained in the @dev above.
    // slither-disable-start missing-zero-check
    // forge-lint: disable-next-line(missing-zero-check)
    constructor(IPoolManager manager, address factory_) BaseHook(manager) {
        factory = factory_;
    }

    // slither-disable-end missing-zero-check

    /// @notice The hook's permissions: beforeInitialize, beforeAddLiquidity, beforeRemoveLiquidity,
    ///         beforeSwap and beforeDonate. Everything else, including every `*ReturnsDelta`, is false.
    /// @return permissions The permission set matching the address flags `0x2AA0`.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeAddLiquidity = true;
        permissions.beforeRemoveLiquidity = true;
        permissions.beforeSwap = true;
        permissions.beforeDonate = true;
    }

    /// @notice Registers the single vault of a pool. Factory only, once per pool id, before the pool is
    ///         initialized.
    /// @dev Reverts, in this order: `OnlyFactory()`; `WrongHook()` if `key.hooks != this`; `ZeroVault()`;
    ///      `AlreadyRegistered()`. `maxIntraBlockTicks` is not bounded here: the factory validates every
    ///      vault parameter, and the hook trusts only the factory.
    /// @param key The pool key; `key.hooks` must be this hook.
    /// @param vault The vault allowed to open and close epochs, and subject to the guard.
    /// @param maxIntraBlockTicks Guard threshold for the vault's liquidity changes.
    function registerVault(PoolKey calldata key, address vault, int24 maxIntraBlockTicks) external {
        if (msg.sender != factory) revert IOathHook.OnlyFactory();
        if (address(key.hooks) != address(this)) revert IOathHook.WrongHook();
        if (vault == address(0)) revert IOathHook.ZeroVault();
        PoolId id = key.toId();
        IOathHook.PoolConfig storage cfg = configs[id];
        if (cfg.vault != address(0)) revert IOathHook.AlreadyRegistered();
        // forge-lint: disable-next-line(missing-events-access-control)
        cfg.vault = vault; // VaultRegistered is emitted below
        cfg.maxIntraBlockTicks = maxIntraBlockTicks;
        emit IOathHook.VaultRegistered(id, vault);
    }

    /// @notice Opens an epoch ending at `epochEnd` and schedules its two checkpoints: `E − W`, the start of
    ///         the end-of-epoch TWAP window, and `E` itself (MATH.md §5). Registered vault only.
    /// @dev Advances the accumulator first, so `lastTimestamp = now` and both checkpoints, being strictly in
    ///      the future, are recorded exactly the first time the hook runs at or after them (MATH.md §4).
    ///      Resets every field of the previous epoch.
    ///      Reverts `OnlyVault()`, `EpochAlreadyActive()`, or `BadWindow()` unless `epochEnd − twapWindow > now`.
    /// @param key The pool key.
    /// @param epochEnd Epoch end `E` (unix seconds).
    /// @param twapWindow End-of-epoch TWAP window `W` (seconds).
    function openEpoch(PoolKey calldata key, uint32 epochEnd, uint32 twapWindow) external {
        PoolId id = _onlyVault(key);
        _advance(key);
        if (epochs[id].active) revert IOathHook.EpochAlreadyActive();
        // Written as a sum so `epochEnd < twapWindow` cannot underflow. Epochs are time-based by design;
        // validator timestamp skew of seconds is irrelevant at epoch scale.
        // forge-lint: disable-next-line(block-timestamp)
        if (uint256(epochEnd) <= block.timestamp + twapWindow) revert IOathHook.BadWindow();

        uint32 checkpointA = epochEnd - twapWindow;
        epochs[id] = IOathHook.Epoch({
            checkpointA: checkpointA,
            checkpointB: epochEnd,
            doneA: false,
            doneB: false,
            snapTaken: false,
            active: true,
            cumA: 0,
            cumB: 0,
            G0: 0,
            G1: 0,
            fgIn0: 0,
            fgIn1: 0
        });
        emit IOathHook.EpochOpened(id, checkpointA, epochEnd);
    }

    /// @notice Closes a settled epoch so the next one can open. Registered vault only, at the end of `settle`.
    /// @dev Reverts `OnlyVault()`, and `EpochNotReady()` unless both checkpoints and the boundary snapshot
    ///      have been recorded.
    /// @param key The pool key.
    function closeEpoch(PoolKey calldata key) external {
        PoolId id = _onlyVault(key);
        IOathHook.Epoch storage e = epochs[id];
        if (!(e.snapTaken && e.doneA && e.doneB)) revert IOathHook.EpochNotReady();
        e.active = false;
        emit IOathHook.EpochClosed(id);
    }

    /// @notice Advances the accumulator to now and records any checkpoint and the epoch-boundary snapshot that
    ///         have come due (MATH.md §4, §8). Anyone, any time: it only records what the pool already did, so
    ///         it cannot change any result.
    /// @param key The pool key.
    function poke(PoolKey calldata key) external {
        _advance(key);
    }

    /// @notice The tick cumulative at the current block time (MATH.md §4):
    ///         `tickCumulative + tick·(now − lastTimestamp)`. Exact, because the tick only changes in swaps and
    ///         every swap advances the accumulator first.
    /// @param key The pool key.
    /// @return The cumulative Σ tick·dt up to `block.timestamp`.
    // Slither: only the tick is needed from `getSlot0`.
    // slither-disable-next-line unused-return
    function cumulativeNow(PoolKey calldata key) external view returns (int256) {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);
        IOathHook.Oracle storage o = oracles[id];
        return _cumulativeAt(o.tickCumulative, o.lastTimestamp, tick, _now());
    }

    /// @notice The pool's current epoch record (checkpoints and snapshot).
    /// @param key The pool key.
    /// @return The `Epoch` struct.
    function epochData(PoolKey calldata key) external view returns (IOathHook.Epoch memory) {
        return epochs[key.toId()];
    }

    /// @dev Reverts `OnlyVault()` unless the caller is the pool's registered vault; returns the pool id.
    function _onlyVault(PoolKey calldata key) private view returns (PoolId id) {
        id = key.toId();
        if (msg.sender != configs[id].vault) revert IOathHook.OnlyVault();
    }

    /// @dev Only the factory can create a pool with this hook, and only after registering its vault, so every
    ///      Oath pool has exactly one vault. Starts the TWAP accumulator at the pool's creation time
    ///      (`tickCumulative = 0`, MATH.md §4). Reverts `OnlyFactory()` or `VaultNotRegistered()`.
    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (sender != factory) revert IOathHook.OnlyFactory();
        PoolId id = key.toId();
        if (configs[id].vault == address(0)) revert IOathHook.VaultNotRegistered();
        oracles[id].lastTimestamp = _now();
        return IHooks.beforeInitialize.selector;
    }

    /// @dev Observes swaps without changing them: no delta, no fee override. Runs before the price moves, so
    ///      the accumulator is advanced with the tick that held since the last update (MATH.md §4). The first
    ///      swap of each block also records the tick the block started at, which the guard on the vault's
    ///      liquidity changes compares against.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (PoolId id, int24 tick) = _advance(key);
        IOathHook.Oracle storage o = oracles[id];
        if (o.lastSwapBlock != block.number) {
            o.blockStartTick = tick;
            // forge-lint: disable-next-line(unsafe-typecast)
            o.lastSwapBlock = uint64(block.number); // a block number never reaches 2^64
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Observes donations without changing them; advances the accumulator. Runs before the donation
    ///      raises fee growth, so a snapshot taken here excludes it (MATH.md §8).
    function _beforeDonate(address, PoolKey calldata key, uint256, uint256, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        _advance(key);
        return IHooks.beforeDonate.selector;
    }

    /// @dev Other LPs are never restricted. When the pool's vault adds liquidity: the intra-block guard, then
    ///      the range is recorded, so the boundary snapshot reads fee growth inside the vault's range.
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId id = key.toId();
        IOathHook.PoolConfig storage cfg = configs[id];
        if (sender == cfg.vault) {
            _guard(id, cfg.maxIntraBlockTicks);
            cfg.vaultLower = params.tickLower;
            cfg.vaultUpper = params.tickUpper;
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @dev Other LPs are never restricted. When the pool's vault removes liquidity (or modifies it by zero):
    ///      the intra-block guard.
    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        PoolId id = key.toId();
        IOathHook.PoolConfig storage cfg = configs[id];
        if (sender == cfg.vault) _guard(id, cfg.maxIntraBlockTicks);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @dev The intra-block manipulation guard on the vault's liquidity changes: reverts
    ///      `PriceMovedThisBlock(current, blockStart)` if a swap earlier in this block moved the tick more than
    ///      `maxIntraBlockTicks` away from where the block started. If no swap has happened in this block, the
    ///      current tick is the block-start tick (only swaps move the price) and the check passes. This blocks a
    ///      sandwich of the vault's reposition or unwind within one block, and bounds the price impact of the
    ///      curator's own rebalance swap.
    // Slither: only the tick is needed from `getSlot0`.
    // slither-disable-next-line unused-return
    function _guard(PoolId id, int24 maxIntraBlockTicks) private view {
        IOathHook.Oracle storage o = oracles[id];
        if (o.lastSwapBlock != block.number) return;
        (, int24 tick,,) = poolManager.getSlot0(id);
        int24 blockStart = o.blockStartTick;
        int256 moved = int256(tick) - int256(blockStart);
        if (moved > maxIntraBlockTicks || moved < -int256(maxIntraBlockTicks)) {
            revert IOathHook.PriceMovedThisBlock(tick, blockStart);
        }
    }

    /// @dev Records the epoch's due checkpoints and boundary snapshot, then advances the pool's accumulator to
    ///      now (MATH.md §4, §8):
    ///      `tickCumulative += tick·(now − lastTimestamp)`, `lastTimestamp = now`.
    ///      Exact: the tick only changes inside swaps, and every swap calls this before the price moves, so
    ///      the current tick held throughout `(lastTimestamp, now]`. A checkpoint `t*` in that interval is
    ///      therefore recorded exactly, not interpolated, and before the accumulator moves past it.
    /// @return id The pool id.
    /// @return tick The current tick, which held since `lastTimestamp`.
    // Slither: only the tick is needed from `getSlot0`.
    // slither-disable-next-line unused-return
    function _advance(PoolKey calldata key) private returns (PoolId id, int24 tick) {
        id = key.toId();
        (, tick,,) = poolManager.getSlot0(id);
        IOathHook.Oracle storage o = oracles[id];
        uint32 nowTs = _now();

        IOathHook.Epoch storage e = epochs[id];
        if (e.active) {
            // Timestamp skew can only change which transaction records a checkpoint, never its value.
            // forge-lint: disable-next-line(block-timestamp)
            if (!e.doneA && e.checkpointA <= nowTs) {
                e.cumA = _checkpoint(id, o, tick, e.checkpointA);
                e.doneA = true;
            }
            // forge-lint: disable-next-line(block-timestamp)
            if (!e.doneB && e.checkpointB <= nowTs) {
                e.cumB = _checkpoint(id, o, tick, e.checkpointB);
                e.doneB = true;
            }
            // forge-lint: disable-next-line(block-timestamp)
            if (!e.snapTaken && e.checkpointB <= nowTs) _snapshot(id, e);
        }

        o.tickCumulative = _cumulativeAt(o.tickCumulative, o.lastTimestamp, tick, nowTs);
        o.lastTimestamp = nowTs;
    }

    /// @dev The keeperless boundary snapshot (MATH.md §8): global fee growth and the fee growth inside the
    ///      vault's last range, read by the first advance at or after `E`. Exact: fee growth only changes in
    ///      swaps and donations (and inside a range also through tick crossings, which happen only in swaps),
    ///      and their `before*` callbacks run this before they change anything, so the current values are
    ///      the values at `E`.
    function _snapshot(PoolId id, IOathHook.Epoch storage e) private {
        (uint256 g0, uint256 g1) = poolManager.getFeeGrowthGlobals(id);
        IOathHook.PoolConfig storage cfg = configs[id];
        (uint256 in0, uint256 in1) = poolManager.getFeeGrowthInside(id, cfg.vaultLower, cfg.vaultUpper);
        e.G0 = g0;
        e.G1 = g1;
        e.fgIn0 = in0;
        e.fgIn1 = in1;
        e.snapTaken = true;
        emit IOathHook.EpochSnapshot(id, g0, g1, in0, in1);
    }

    /// @dev The cumulative at checkpoint `t` (MATH.md §4): `tick` held throughout `(lastTimestamp, now]` and
    ///      `lastTimestamp < t ≤ now`, so it is `tickCumulative + tick·(t − lastTimestamp)` exactly.
    ///      `lastTimestamp < t` always holds: `openEpoch` schedules checkpoints strictly after the time it
    ///      advances to, and a checkpoint is recorded by the first advance at or after it. Checked anyway.
    function _checkpoint(PoolId id, IOathHook.Oracle storage o, int24 tick, uint32 t)
        private
        returns (int256 cumulative)
    {
        if (t <= o.lastTimestamp) revert IOathHook.CheckpointInPast();
        cumulative = _cumulativeAt(o.tickCumulative, o.lastTimestamp, tick, t);
        emit IOathHook.CheckpointRecorded(id, t, cumulative);
    }

    /// @dev The cumulative at time `t ≥ lastTimestamp` when `tick` held throughout `(lastTimestamp, t]`
    ///      (MATH.md §4): `cumulative + tick·(t − lastTimestamp)`. Cannot overflow: `|tick| < 2^20` and
    ///      `t − lastTimestamp < 2^32`.
    function _cumulativeAt(int256 cumulative, uint32 lastTimestamp, int24 tick, uint32 t)
        private
        pure
        returns (int256)
    {
        return cumulative + int256(tick) * int256(uint256(t - lastTimestamp));
    }

    /// @dev `block.timestamp` as `uint32`, the width every Oath timestamp uses; fits until 2106.
    function _now() private view returns (uint32) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(block.timestamp);
    }
}
