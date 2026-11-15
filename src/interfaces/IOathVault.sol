// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IOathHook} from "./IOathHook.sol";

/// @title IOathVault
/// @notice A curated two-token vault in one Oath pool. Depositors receive ERC-20 shares; the curator posts a
///         currency1 bond and manages one concentrated position. Every epoch the vault is settled against an
///         exact on-chain counterfactual (a passive full-range position of the same start value): the curator
///         earns a performance fee on outperformance beyond the band, or the bond pays depositors the
///         shortfall beyond the band. All values are in raw currency1 units (MATH.md §1).
interface IOathVault {
    /// @notice Vault lifecycle. SETTLEABLE is derived: `ACTIVE && now ≥ epochEnd`.
    enum State {
        OPEN,
        ACTIVE
    }

    /// @notice Per-vault parameters, fixed at creation and validated by the factory (MATH.md §12).
    /// @param epochDuration Epoch length `E − S` (seconds). Default 7 days, demo 1 day.
    /// @param twapWindow End-of-epoch TWAP window `W` and minimum open window (seconds). Default 30 min.
    /// @param maxOpen Maximum open window before `startEpoch` (seconds). Default 6 h.
    /// @param rebalanceCooldown Minimum time between repositions (seconds). Default 1 h.
    /// @param maxIntraBlockTicks Hook guard threshold for vault liquidity changes. Default 50.
    /// @param bandBps Tolerance band around the benchmark. Default 35.
    /// @param perfFeeBps Performance fee on excess above the band. Default 2,000.
    /// @param minBondBps Minimum bond as a share of start NAV. Default 1,000.
    /// @param capBps Maximum benchmark liquidity as a share of pool active liquidity. Default 25.
    struct VaultParams {
        uint32 epochDuration;
        uint32 twapWindow;
        uint32 maxOpen;
        uint32 rebalanceCooldown;
        int24 maxIntraBlockTicks;
        uint16 bandBps;
        uint16 perfFeeBps;
        uint16 minBondBps;
        uint16 capBps;
    }

    /// @notice Optional swap executed inside a reposition.
    /// @param zeroForOne Swap direction.
    /// @param amountSpecified `0` for no swap; otherwise must be `< 0` (exact input).
    /// @param sqrtPriceLimitX96 Price limit for the swap.
    struct SwapIntent {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice The epoch's hypothetical full-range benchmark (MATH.md §6.1).
    /// @param L Benchmark liquidity `L_b`.
    /// @param r0 Leftover currency0 held outside the pool.
    /// @param r1 Leftover currency1 held outside the pool.
    /// @param G0 Global fee growth of currency0 at epoch start `S` (Q128).
    /// @param G1 Global fee growth of currency1 at epoch start `S` (Q128).
    /// @param navStart Vault NAV at the start TWAP price `V_S`.
    /// @param startTick Start TWAP tick over the open window.
    struct Benchmark {
        // forge-lint: disable-next-line(mixed-case-variable)
        uint128 L; // MATH.md notation
        uint256 r0;
        uint256 r1;
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 G0;
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 G1;
        uint256 navStart;
        int24 startTick;
    }

    /// @notice The stored outcome of one settled epoch. Every number the frontend
    ///         and the demo show comes from these fields.
    /// @param start Epoch start `S`.
    /// @param end Epoch end `E`.
    /// @param startTick Start TWAP tick.
    /// @param endTick End TWAP tick over `[E − W, E]`.
    /// @param navStart Vault NAV at `S` (= benchmark value at `S`).
    /// @param navEnd Vault NAV at `E`, marked at the end TWAP.
    /// @param benchEnd Benchmark value at `E`, marked at the end TWAP.
    /// @param diff `navEnd − benchEnd`.
    /// @param band `benchEnd · bandBps / 10,000`.
    /// @param payout Currency1 moved from the bond to depositors.
    /// @param fee Performance fee value in currency1 units.
    /// @param feeShares Shares minted to the curator for `fee`.
    /// @param bondAfter Bond balance after the payout.
    /// @param benchFees0 Benchmark fees in currency0 over the epoch.
    /// @param benchFees1 Benchmark fees in currency1 over the epoch.
    /// @param vaultFees0 Vault's uncollected fees in currency0 at `E`.
    /// @param vaultFees1 Vault's uncollected fees in currency1 at `E`.
    struct EpochResult {
        uint32 start;
        uint32 end;
        int24 startTick;
        int24 endTick;
        uint256 navStart;
        uint256 navEnd;
        uint256 benchEnd;
        int256 diff;
        uint256 band;
        uint256 payout;
        uint256 fee;
        uint256 feeShares;
        uint256 bondAfter;
        uint256 benchFees0;
        uint256 benchFees1;
        uint256 vaultFees0;
        uint256 vaultFees1;
    }

    /// @notice Emitted on a deposit: `used0`/`used1` taken from `sender`, `shares` minted to `receiver`.
    event Deposit(address indexed sender, address indexed receiver, uint256 used0, uint256 used1, uint256 shares);
    /// @notice Emitted on a withdrawal: `shares` burned from `sender`, `out0`/`out1` sent to `receiver`.
    event Withdraw(address indexed sender, address indexed receiver, uint256 out0, uint256 out1, uint256 shares);
    /// @notice Emitted when the curator adds `amount` currency1 to the bond.
    event BondPosted(uint256 amount, uint256 bondBalance);
    /// @notice Emitted when the curator withdraws `amount` currency1 from the bond.
    event BondWithdrawn(uint256 amount, uint256 bondBalance);
    /// @notice Emitted when the open window starts (`initOpenWindow`) or restarts (`refreshOpenWindow`).
    event OpenWindowRefreshed(uint32 openSince, int256 cumAtOpen);
    /// @notice Emitted when an epoch starts.
    event EpochStarted(
        uint256 indexed epoch,
        uint32 epochStart,
        uint32 epochEnd,
        int24 startTick,
        uint256 navStart,
        uint128 benchmarkLiquidity,
        int24 tickLower,
        int24 tickUpper
    );
    /// @notice Emitted when the curator moves the position during an epoch.
    event Rebalanced(int24 tickLower, int24 tickUpper, uint128 liquidity);
    /// @notice Emitted when an epoch is settled.
    event Settled(uint256 indexed epoch, EpochResult result);
    /// @notice Emitted when the shortfall beyond the band exceeds the bond; the uncovered part stays with
    ///         depositors (MATH.md §9.2).
    event BondExhausted(uint256 shortfallUncovered);

    /// @notice Action requires the OPEN state.
    error NotOpen();
    /// @notice Action requires the ACTIVE state.
    error NotActive();
    /// @notice Caller is not the curator.
    error NotCurator();
    /// @notice `unlockCallback` or ETH not sent by the PoolManager.
    error OnlyManager();
    /// @notice Shares or amounts below the caller's minimum.
    error Slippage();
    /// @notice The vault holds nothing to price a deposit against, or has zero NAV at `startEpoch`.
    error EmptyVault();
    /// @notice `withdrawBond` amount exceeds the bond.
    error InsufficientBond();
    /// @notice Bond below `minBondBps` of start NAV.
    error BondTooSmall();
    /// @notice Benchmark liquidity above `capBps` of pool active liquidity.
    error VaultTooLarge();
    /// @notice `startEpoch` before the open window reached `twapWindow`.
    error OpenWindowTooShort();
    /// @notice `startEpoch` after the open window exceeded `maxOpen`.
    error OpenWindowExpired();
    /// @notice `rebalance` at or after `epochEnd`.
    error EpochEnded();
    /// @notice `settle` before `epochEnd`.
    error EpochNotEnded();
    /// @notice `rebalance` before `rebalanceCooldown` has passed.
    error Cooldown();
    /// @notice Range not ordered, not on `tickSpacing`, or outside the usable ticks.
    error BadRange();
    /// @notice Reposition swap is not exact-input.
    error ExactInputOnly();
    /// @notice A reposition would spend bond tokens.
    error BondTouched();
    /// @notice `msg.value` does not match `amount0Max` for native currency0, or is non-zero otherwise.
    error BadNativeAmount();
    /// @notice `refreshOpenWindow` before `maxOpen` has passed.
    error OpenWindowNotExpired();
    /// @notice A deposit would mint zero shares.
    error ZeroShares();
    /// @notice `initOpenWindow` not called by the factory.
    error OnlyFactory();
    /// @notice `initOpenWindow` called twice.
    error AlreadyInitialized();

    /// @notice The Uniswap v4 PoolManager.
    function manager() external view returns (IPoolManager);
    /// @notice The pool's Oath hook (the referee).
    function hook() external view returns (IOathHook);
    /// @notice The factory that created this vault.
    function factory() external view returns (address);
    /// @notice The curator: posts the bond, starts epochs and rebalances.
    function curator() external view returns (address);
    /// @notice The vault's pool key.
    function poolKey() external view returns (PoolKey memory);
    /// @notice The vault's pool id.
    function poolId() external view returns (PoolId);
    /// @notice The vault's fixed parameters.
    function params() external view returns (VaultParams memory);

    /// @notice Current lifecycle state.
    function state() external view returns (State);
    /// @notice Currency1 held as curator bond (excluded from NAV).
    function bondBalance() external view returns (uint256);
    /// @notice Open-window start `T0`.
    function openSince() external view returns (uint32);
    /// @notice Hook tick cumulative at `T0`.
    function cumAtOpen() external view returns (int256);
    /// @notice Current or last epoch start `S`.
    function epochStart() external view returns (uint32);
    /// @notice Current or last epoch end `E`.
    function epochEnd() external view returns (uint32);
    /// @notice Time of the last `startEpoch` or `rebalance`.
    function lastReposition() external view returns (uint32);
    /// @notice Vault position liquidity `L_v`.
    function positionLiquidity() external view returns (uint128);
    /// @notice Vault position lower tick.
    function positionLower() external view returns (int24);
    /// @notice Vault position upper tick.
    function positionUpper() external view returns (int24);
    /// @notice The current epoch's benchmark (see `Benchmark`).
    function benchmark()
        external
        view
        // forge-lint: disable-next-line(mixed-case-variable)
        returns (uint128 L, uint256 r0, uint256 r1, uint256 G0, uint256 G1, uint256 navStart, int24 startTick);

    /// @notice Idle currency0: the vault's currency0 balance (native ETH balance if currency0 is native).
    function idle0() external view returns (uint256);
    /// @notice Idle currency1: the vault's currency1 balance minus `bondBalance`.
    function idle1() external view returns (uint256);
    /// @notice Whether `settle` may be called: `state == ACTIVE && now ≥ epochEnd`.
    function isSettleable() external view returns (bool);

    /// @notice Deposits in kind during the open window (MATH.md §11). Price-free: the
    ///         first deposit mints `sqrt(a0·a1) − MIN_SHARES` (MIN_SHARES to 0xdead); later deposits mint
    ///         `min_i(supply·a_i/h_i)` and take `mulDivUp(h_i, shares, supply)`; unused amounts are not taken.
    /// @param amount0Max Maximum currency0 to deposit (must equal `msg.value` if currency0 is native).
    /// @param amount1Max Maximum currency1 to deposit.
    /// @param minShares Minimum shares to mint, else `Slippage()`.
    /// @param receiver Receiver of the shares.
    /// @return shares Shares minted.
    /// @return used0 Currency0 taken.
    /// @return used1 Currency1 taken.
    function deposit(uint256 amount0Max, uint256 amount1Max, uint256 minShares, address receiver)
        external
        payable
        returns (uint256 shares, uint256 used0, uint256 used1);

    /// @notice Burns shares for a pro-rata share of both idle tokens during the open window: `out_i =
    ///         mulDiv(h_i, shares, supply)` (MATH.md §11).
    /// @param shares Shares to burn from the caller.
    /// @param min0 Minimum currency0 out, else `Slippage()`.
    /// @param min1 Minimum currency1 out, else `Slippage()`.
    /// @param receiver Receiver of the tokens.
    /// @return out0 Currency0 sent.
    /// @return out1 Currency1 sent.
    function withdraw(uint256 shares, uint256 min0, uint256 min1, address receiver)
        external
        returns (uint256 out0, uint256 out1);

    /// @notice Adds currency1 to the curator bond. Curator only, any state.
    /// @param amount Currency1 to pull from the curator.
    function postBond(uint256 amount) external;

    /// @notice Withdraws currency1 from the bond. Curator only, OPEN only.
    /// @param amount Currency1 to send to the curator.
    function withdrawBond(uint256 amount) external;

    /// @notice Restarts an open window that exceeded `maxOpen`: `T0 = now`, `cumAtOpen = cumulativeNow`.
    ///         Anyone, OPEN only.
    function refreshOpenWindow() external;

    /// @notice Starts the first open window right after pool initialization. Factory only, once.
    function initOpenWindow() external;

    /// @notice Starts an epoch: marks the vault at the open-window TWAP, creates the
    ///         benchmark, checks the cap and the bond, schedules the hook checkpoints, and opens the position.
    /// @param tickLower Lower tick of the curator's range.
    /// @param tickUpper Upper tick of the curator's range.
    /// @param swap Optional exact-input swap before adding liquidity.
    function startEpoch(int24 tickLower, int24 tickUpper, SwapIntent calldata swap) external;

    /// @notice Moves the position to a new range during an epoch, after the cooldown.
    /// @param tickLower New lower tick.
    /// @param tickUpper New upper tick.
    /// @param swap Optional exact-input swap between removing and adding liquidity.
    function rebalance(int24 tickLower, int24 tickUpper, SwapIntent calldata swap) external;

    /// @notice Settles the epoch against the benchmark at the end TWAP, applies the payout or fee, unwinds
    ///         the position and reopens the window. Anyone, once `now ≥ epochEnd`.
    function settle() external;

    /// @notice Live mark of vault and benchmark at the current spot price with live fee growth. For display
    ///         only ("live mark (spot)"); settlement uses TWAP.
    /// @return navNow Vault NAV at spot.
    /// @return benchNow Benchmark value at spot.
    /// @return diff `navNow − benchNow`.
    function previewLive() external view returns (uint256 navNow, uint256 benchNow, int256 diff);

    /// @notice Number of settled epochs.
    function epochCount() external view returns (uint256);

    /// @notice The result of settled epoch `i`.
    /// @param i Epoch index, `0 ≤ i < epochCount()`.
    function getResult(uint256 i) external view returns (EpochResult memory);

    /// @notice The vault's current position.
    /// @return lower Lower tick.
    /// @return upper Upper tick.
    /// @return liquidity Liquidity `L_v`.
    function positionInfo() external view returns (int24 lower, int24 upper, uint128 liquidity);
}
