// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IOathHook
/// @notice The Oath pool's referee. It keeps an exact TWAP accumulator, records epoch checkpoints and the
///         epoch-boundary fee-growth snapshot without a keeper, guards every vault liquidity change against
///         intra-block price manipulation, and only lets `OathFactory` create pools. It holds no funds and
///         never changes swap amounts or fees.
interface IOathHook {
    /// @notice Per-pool TWAP accumulator and block-start tracking (MATH.md §4).
    /// @param lastTimestamp Last time `tickCumulative` was advanced.
    /// @param lastSwapBlock Block number of the last `beforeSwap`.
    /// @param blockStartTick Tick before the first swap of `lastSwapBlock`.
    /// @param tickCumulative Σ tick·dt up to `lastTimestamp`.
    struct Oracle {
        uint32 lastTimestamp;
        uint64 lastSwapBlock;
        int24 blockStartTick;
        int256 tickCumulative;
    }

    /// @notice Per-pool epoch checkpoints and boundary snapshot (MATH.md §5, §8).
    /// @param checkpointA `E − W`, the start of the end-of-epoch TWAP window.
    /// @param checkpointB `E`, the epoch end.
    /// @param doneA Whether `cumA` has been recorded.
    /// @param doneB Whether `cumB` has been recorded.
    /// @param snapTaken Whether the fee-growth snapshot at `E` has been taken.
    /// @param active Whether an epoch is open for this pool.
    /// @param cumA Tick cumulative at exactly `E − W`.
    /// @param cumB Tick cumulative at exactly `E`.
    /// @param G0 Global fee growth of currency0 at `E` (Q128).
    /// @param G1 Global fee growth of currency1 at `E` (Q128).
    /// @param fgIn0 Fee growth inside the vault's range for currency0 at `E` (Q128).
    /// @param fgIn1 Fee growth inside the vault's range for currency1 at `E` (Q128).
    struct Epoch {
        uint32 checkpointA;
        uint32 checkpointB;
        bool doneA;
        bool doneB;
        bool snapTaken;
        bool active;
        int256 cumA;
        int256 cumB;
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 G0; // MATH.md notation
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 G1;
        uint256 fgIn0;
        uint256 fgIn1;
    }

    /// @notice Per-pool registration and vault range tracking.
    /// @param vault The pool's single registered `OathVault`.
    /// @param maxIntraBlockTicks Guard threshold for vault liquidity changes.
    /// @param vaultLower Lower tick of the last range the vault added liquidity to.
    /// @param vaultUpper Upper tick of the last range the vault added liquidity to.
    struct PoolConfig {
        address vault;
        int24 maxIntraBlockTicks;
        int24 vaultLower;
        int24 vaultUpper;
    }

    /// @notice Emitted when the factory registers a pool's vault.
    event VaultRegistered(PoolId indexed id, address vault);
    /// @notice Emitted when the vault opens an epoch and the two checkpoints are scheduled.
    event EpochOpened(PoolId indexed id, uint32 checkpointA, uint32 epochEnd);
    /// @notice Emitted when a scheduled checkpoint is recorded exactly at `timestamp`.
    event CheckpointRecorded(PoolId indexed id, uint32 timestamp, int256 cumulative);
    /// @notice Emitted when the keeperless fee-growth snapshot at the epoch boundary is taken.
    // forge-lint: disable-next-line(mixed-case-variable)
    event EpochSnapshot(PoolId indexed id, uint256 G0, uint256 G1, uint256 fgIn0, uint256 fgIn1);
    /// @notice Emitted when the vault closes a settled epoch.
    event EpochClosed(PoolId indexed id);

    /// @notice Caller is not the factory (`registerVault`, or `beforeInitialize` from another sender).
    error OnlyFactory();
    /// @notice Caller is not the pool's registered vault.
    error OnlyVault();
    /// @notice A pool is being initialized before the factory registered its vault.
    error VaultNotRegistered();
    /// @notice The pool already has a registered vault.
    error AlreadyRegistered();
    /// @notice `openEpoch` called while an epoch is active.
    error EpochAlreadyActive();
    /// @notice `closeEpoch` called before both checkpoints and the snapshot were recorded.
    error EpochNotReady();
    /// @notice `openEpoch` called with `epochEnd − twapWindow ≤ now`.
    error BadWindow();
    /// @notice A checkpoint would be recorded at or before `lastTimestamp` (internal consistency check).
    error CheckpointInPast();
    /// @notice A vault liquidity change was attempted after the tick moved more than `maxIntraBlockTicks`
    ///         within the current block.
    error PriceMovedThisBlock(int24 current, int24 blockStart);
    /// @notice `registerVault` called with a pool key whose `hooks` is not this hook.
    error WrongHook();
    /// @notice `registerVault` called with the zero address as the vault.
    error ZeroVault();

    /// @notice The only address allowed to register vaults and initialize pools with this hook.
    /// @return The factory.
    function factory() external view returns (address);

    /// @notice The TWAP accumulator state of a pool (see `Oracle`).
    /// @param id The pool id.
    /// @return lastTimestamp Last time `tickCumulative` was advanced.
    /// @return lastSwapBlock Block number of the last `beforeSwap`.
    /// @return blockStartTick Tick before the first swap of `lastSwapBlock`.
    /// @return tickCumulative Σ tick·dt up to `lastTimestamp`.
    function oracles(PoolId id)
        external
        view
        returns (uint32 lastTimestamp, uint64 lastSwapBlock, int24 blockStartTick, int256 tickCumulative);

    /// @notice The registration and vault range of a pool (see `PoolConfig`).
    /// @param id The pool id.
    /// @return vault The pool's registered vault.
    /// @return maxIntraBlockTicks Guard threshold for vault liquidity changes.
    /// @return vaultLower Lower tick of the last range the vault added liquidity to.
    /// @return vaultUpper Upper tick of the last range the vault added liquidity to.
    function configs(PoolId id)
        external
        view
        returns (address vault, int24 maxIntraBlockTicks, int24 vaultLower, int24 vaultUpper);

    /// @notice Registers the single vault of a pool. Factory only, once per pool id.
    /// @dev Reverts, in this order: `OnlyFactory()`; `WrongHook()` if `key.hooks != this`; `ZeroVault()` if
    ///      `vault == address(0)`; `AlreadyRegistered()`. Parameter bounds are the factory's job.
    /// @param key The pool key; `key.hooks` must be this hook.
    /// @param vault The vault allowed to call `openEpoch`/`closeEpoch` and subject to the guard.
    /// @param maxIntraBlockTicks Guard threshold for the vault's liquidity changes.
    function registerVault(PoolKey calldata key, address vault, int24 maxIntraBlockTicks) external;

    /// @notice Opens an epoch ending at `epochEnd` and schedules checkpoints at `epochEnd − twapWindow` and
    ///         `epochEnd`. Registered vault only.
    /// @dev Advances the accumulator first. Reverts `OnlyVault()`, `EpochAlreadyActive()`, and `BadWindow()`
    ///      unless `epochEnd − twapWindow > now`.
    /// @param key The pool key.
    /// @param epochEnd Epoch end `E` (unix seconds).
    /// @param twapWindow End-of-epoch TWAP window `W` (seconds).
    function openEpoch(PoolKey calldata key, uint32 epochEnd, uint32 twapWindow) external;

    /// @notice Closes a settled epoch. Registered vault only, at the end of `settle`.
    /// @dev Reverts `OnlyVault()`, and `EpochNotReady()` unless `snapTaken && doneA && doneB`.
    /// @param key The pool key.
    function closeEpoch(PoolKey calldata key) external;

    /// @notice Advances the accumulator and records any due checkpoints and the boundary snapshot.
    ///         Anyone may call.
    /// @param key The pool key.
    function poke(PoolKey calldata key) external;

    /// @notice The tick cumulative at the current block time:
    ///         `tickCumulative + tick·(now − lastTimestamp)` (MATH.md §4).
    /// @param key The pool key.
    /// @return The cumulative Σ tick·dt up to `block.timestamp`.
    function cumulativeNow(PoolKey calldata key) external view returns (int256);

    /// @notice The pool's current epoch record (checkpoints and snapshot). The vault requires
    ///         `snapTaken && doneA && doneB` before using it at settlement.
    /// @param key The pool key.
    /// @return The `Epoch` record.
    function epochData(PoolKey calldata key) external view returns (Epoch memory);
}
