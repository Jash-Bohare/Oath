// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IOathHook} from "./interfaces/IOathHook.sol";

/// @title OathHook
/// @notice The Oath pool's referee. It holds no funds and never changes swap amounts or fees. Pools with this
///         hook can only be created by `OathFactory`, which registers exactly one vault per pool.
/// @dev Permissions are the five `before*` hooks only (address flags `0x2AA0`); no hook returns a delta.
contract OathHook is BaseHook, IOathHook {
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
    // forge-lint: disable-next-line(missing-zero-check)
    constructor(IPoolManager manager, address factory_) BaseHook(manager) {
        factory = factory_;
    }

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
    /// @dev Both checkpoints are strictly in the future, so each is recorded exactly the first time the hook
    ///      runs at or after it (MATH.md §4). Resets every field of the previous epoch.
    ///      Reverts `OnlyVault()`, `EpochAlreadyActive()`, or `BadWindow()` unless `epochEnd − twapWindow > now`.
    /// @param key The pool key.
    /// @param epochEnd Epoch end `E` (unix seconds).
    /// @param twapWindow End-of-epoch TWAP window `W` (seconds).
    function openEpoch(PoolKey calldata key, uint32 epochEnd, uint32 twapWindow) external {
        PoolId id = _onlyVault(key);
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

    /// @notice Advances the accumulator and records any due checkpoints and the boundary snapshot. Anyone.
    /// @dev The accumulator is not wired in yet, so for now this does nothing.
    // forge-lint: disable-next-line(empty-block)
    function poke(PoolKey calldata) external pure {}

    /// @notice The tick cumulative at the current block time (MATH.md §4).
    /// @dev The accumulator is not wired in yet, so for now this returns the stored `tickCumulative`.
    /// @param key The pool key.
    /// @return The cumulative Σ tick·dt.
    function cumulativeNow(PoolKey calldata key) external view returns (int256) {
        return oracles[key.toId()].tickCumulative;
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
        // forge-lint: disable-next-line(unsafe-typecast)
        oracles[id].lastTimestamp = uint32(block.timestamp); // fits until 2106
        return IHooks.beforeInitialize.selector;
    }

    /// @dev Observes swaps without changing them: no delta, no fee override. The accumulator update and
    ///      block-start tracking are not wired in yet, so for now this only returns its selector.
    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Observes donations without changing them. The accumulator update is not wired in yet, so for now
    ///      this only returns its selector.
    function _beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    /// @dev Other LPs are never restricted. The guard and vault range tracking are not wired in yet, so for
    ///      now this only returns its selector.
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @dev Other LPs are never restricted. The guard is not wired in yet, so for now this only returns its
    ///      selector.
    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }
}
