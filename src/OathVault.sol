// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {IOathHook} from "./interfaces/IOathHook.sol";
import {IOathVault} from "./interfaces/IOathVault.sol";
import {BenchmarkLib} from "./libraries/BenchmarkLib.sol";
import {SettlementLib} from "./libraries/SettlementLib.sol";
import {ValuationLib} from "./libraries/ValuationLib.sol";

/// @title OathVault
/// @notice A curated two-token vault in one Oath pool. Depositors receive ERC-20 shares; the curator posts a
///         currency1 bond and manages one concentrated position, measured every epoch against an exact on-chain
///         counterfactual (MATH.md §6, §9). Created only by `OathFactory`, which also creates its pool.
/// @dev Pool key and parameters are fixed at creation and held as immutables. Values are in raw currency1 units
///      (MATH.md §1).
contract OathVault is ERC20, IUnlockCallback, ReentrancyGuardTransient, IOathVault {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    /// @dev What the vault's own `unlock` does in `unlockCallback`.
    enum Action {
        REPOSITION,
        UNWIND
    }

    /// @notice Shares minted to `DEAD` on the first deposit, so the share price cannot be inflated (MATH.md §11).
    uint256 public constant MIN_SHARES = 1_000;
    /// @notice Holder of the permanently locked `MIN_SHARES`.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @dev Basis-point denominator.
    uint256 private constant BPS = 10_000;
    /// @notice Salt of the vault's single pool position.
    bytes32 public constant POSITION_SALT = bytes32(0);

    IPoolManager private immutable MANAGER;
    IOathHook private immutable HOOK;
    address private immutable FACTORY;
    address private immutable CURATOR;

    Currency private immutable CURRENCY0;
    Currency private immutable CURRENCY1;
    uint24 private immutable FEE;
    int24 private immutable TICK_SPACING;
    PoolId private immutable POOL_ID;

    uint32 private immutable EPOCH_DURATION;
    uint32 private immutable TWAP_WINDOW;
    uint32 private immutable MAX_OPEN;
    uint32 private immutable REBALANCE_COOLDOWN;
    int24 private immutable MAX_INTRA_BLOCK_TICKS;
    uint16 private immutable BAND_BPS;
    uint16 private immutable PERF_FEE_BPS;
    uint16 private immutable MIN_BOND_BPS;
    uint16 private immutable CAP_BPS;

    /// @notice Current lifecycle state. Deposits and withdrawals happen only while OPEN.
    /// @dev OPEN (the zero value) at creation; `startEpoch` moves it to ACTIVE and `settle` back to OPEN.
    IOathVault.State public state;
    /// @notice Currency1 held as the curator's bond. Part of the vault's currency1 balance, but not of `idle1`
    ///         or of NAV.
    uint256 public bondBalance;
    /// @notice Open-window start `T0`: when the current open window began.
    uint32 public openSince;
    /// @notice The hook's tick cumulative at `T0`, the start of the open-window TWAP (MATH.md §5).
    int256 public cumAtOpen;
    /// @notice Current or last epoch start `S`.
    uint32 public epochStart;
    /// @notice Current or last epoch end `E`.
    uint32 public epochEnd;
    /// @notice Time of the last `startEpoch` or `rebalance`.
    uint32 public lastReposition;
    /// @notice Liquidity `L_v` of the vault's position. Zero in the open window.
    uint128 public positionLiquidity;
    /// @notice Lower tick of the vault's position.
    int24 public positionLower;
    /// @notice Upper tick of the vault's position.
    int24 public positionUpper;
    /// @notice The current epoch's benchmark (MATH.md §6.1).
    IOathVault.Benchmark public benchmark;
    /// @notice Results of the settled epochs, in order.
    IOathVault.EpochResult[] public results;

    /// @dev Called by `OathFactory`, which becomes `factory()`. The factory validates `params`, rejects a zero
    ///      curator and builds `key` with this pool's hook, so the vault does not re-check them.
    /// @param manager_ The Uniswap v4 PoolManager.
    /// @param hook_ The pool's Oath hook.
    /// @param key_ The vault's pool key.
    /// @param curator_ The curator.
    /// @param params_ The vault's fixed parameters (MATH.md §12).
    constructor(
        IPoolManager manager_,
        IOathHook hook_,
        PoolKey memory key_,
        // forge-lint: disable-next-line(missing-zero-check)
        address curator_,
        IOathVault.VaultParams memory params_
    ) ERC20(_shareName(key_), _shareSymbol(key_)) {
        MANAGER = manager_;
        HOOK = hook_;
        FACTORY = msg.sender;
        CURATOR = curator_;

        CURRENCY0 = key_.currency0;
        CURRENCY1 = key_.currency1;
        FEE = key_.fee;
        TICK_SPACING = key_.tickSpacing;
        POOL_ID = key_.toId();

        EPOCH_DURATION = params_.epochDuration;
        TWAP_WINDOW = params_.twapWindow;
        MAX_OPEN = params_.maxOpen;
        REBALANCE_COOLDOWN = params_.rebalanceCooldown;
        MAX_INTRA_BLOCK_TICKS = params_.maxIntraBlockTicks;
        BAND_BPS = params_.bandBps;
        PERF_FEE_BPS = params_.perfFeeBps;
        MIN_BOND_BPS = params_.minBondBps;
        CAP_BPS = params_.capBps;
    }

    /// @notice Accepts ETH only from the PoolManager (native currency0 taken out of the pool). Depositors send ETH
    ///         through `deposit`.
    receive() external payable {
        if (msg.sender != address(MANAGER)) revert IOathVault.OnlyManager();
    }

    // ---------------------------------------------------------------- shares

    /// @notice Deposits in kind during the open window and mints shares to `receiver` (MATH.md §11). Price-free:
    ///         - first deposit: `shares = sqrt(a0·a1) − MIN_SHARES`, `MIN_SHARES` minted to `DEAD`, both amounts
    ///           taken in full;
    ///         - later deposits: `shares = min_i mulDiv(supply, a_i, h_i)` over the tokens the vault holds
    ///           (`h_i > 0`), and `used_i = mulDivUp(h_i, shares, supply)` is taken; the rest is not.
    /// @dev Holdings `h_i` are the idle balances before this deposit (bond excluded; for native currency0, the
    ///      ETH sent with this call excluded). Shares round down and taken amounts round up, so rounding favours the
    ///      vault. `a0·a1` must fit in 256 bits. For native currency0, `msg.value` must equal `amount0Max` and the
    ///      unused ETH is refunded to the sender; otherwise no ETH may be sent.
    ///      Reverts `NotOpen()`, `BadNativeAmount()`, `ZeroShares()`, `EmptyVault()`, `Slippage()`.
    /// @param amount0Max Maximum currency0 to deposit (equal to `msg.value` if currency0 is native).
    /// @param amount1Max Maximum currency1 to deposit.
    /// @param minShares Minimum shares to mint, else `Slippage()`.
    /// @param receiver Receiver of the shares.
    /// @return shares Shares minted to `receiver`.
    /// @return used0 Currency0 taken.
    /// @return used1 Currency1 taken.
    function deposit(uint256 amount0Max, uint256 amount1Max, uint256 minShares, address receiver)
        external
        payable
        nonReentrant
        returns (uint256 shares, uint256 used0, uint256 used1)
    {
        if (state != IOathVault.State.OPEN) revert IOathVault.NotOpen();
        bool native = CURRENCY0.isAddressZero();
        if (native ? msg.value != amount0Max : msg.value != 0) revert IOathVault.BadNativeAmount();

        uint256 supply = totalSupply();
        if (supply == 0) {
            if (amount0Max == 0 || amount1Max == 0) revert IOathVault.ZeroShares();
            uint256 root = Math.sqrt(amount0Max * amount1Max);
            if (root <= MIN_SHARES) revert IOathVault.ZeroShares();
            shares = root - MIN_SHARES;
            (used0, used1) = (amount0Max, amount1Max);
            _mint(DEAD, MIN_SHARES);
        } else {
            // The ETH sent with this call is already in the balance; it is not yet part of the holdings.
            (shares, used0, used1) = _proportional(supply, amount0Max, amount1Max, idle0() - msg.value, idle1());
        }
        if (shares < minShares) revert IOathVault.Slippage();

        if (!native && used0 != 0) {
            IERC20(Currency.unwrap(CURRENCY0)).safeTransferFrom(msg.sender, address(this), used0);
        }
        if (used1 != 0) IERC20(Currency.unwrap(CURRENCY1)).safeTransferFrom(msg.sender, address(this), used1);
        _mint(receiver, shares);
        emit IOathVault.Deposit(msg.sender, receiver, used0, used1, shares);
        if (native && amount0Max > used0) CURRENCY0.transfer(msg.sender, amount0Max - used0);
    }

    /// @notice Burns `shares` from the caller for a pro-rata share of both idle currencies during the open window,
    ///         sent to `receiver`: `out_i = mulDiv(h_i, shares, supply)` (MATH.md §11). The bond is not part of
    ///         the holdings.
    /// @dev Rounds down, in the vault's favour. Reverts `NotOpen()`, `Slippage()`, or the ERC-20 balance error if
    ///      the caller holds fewer than `shares`.
    /// @param shares Shares to burn from the caller.
    /// @param min0 Minimum currency0 out, else `Slippage()`.
    /// @param min1 Minimum currency1 out, else `Slippage()`.
    /// @param receiver Receiver of the currencies.
    /// @return out0 Currency0 sent.
    /// @return out1 Currency1 sent.
    function withdraw(uint256 shares, uint256 min0, uint256 min1, address receiver)
        external
        nonReentrant
        returns (uint256 out0, uint256 out1)
    {
        if (state != IOathVault.State.OPEN) revert IOathVault.NotOpen();
        uint256 supply = totalSupply();
        out0 = FullMath.mulDiv(idle0(), shares, supply);
        out1 = FullMath.mulDiv(idle1(), shares, supply);
        if (out0 < min0 || out1 < min1) revert IOathVault.Slippage();

        _burn(msg.sender, shares);
        emit IOathVault.Withdraw(msg.sender, receiver, out0, out1, shares);
        if (out0 != 0) CURRENCY0.transfer(receiver, out0);
        if (out1 != 0) CURRENCY1.transfer(receiver, out1);
    }

    // ---------------------------------------------------------------- bond

    /// @notice Adds `amount` currency1 to the curator's bond. Curator only, in any state.
    /// @dev The bond is held by the vault but excluded from `idle1`, shares and NAV. Reverts `NotCurator()`.
    /// @param amount Currency1 to pull from the curator.
    function postBond(uint256 amount) external nonReentrant {
        if (msg.sender != CURATOR) revert IOathVault.NotCurator();
        IERC20(Currency.unwrap(CURRENCY1)).safeTransferFrom(msg.sender, address(this), amount);
        bondBalance += amount;
        emit IOathVault.BondPosted(amount, bondBalance);
    }

    /// @notice Sends `amount` currency1 of the bond back to the curator. Curator only, open window only: during
    ///         an epoch the bond backs the curator's result.
    /// @dev Reverts `NotCurator()`, `NotOpen()`, `InsufficientBond()`.
    /// @param amount Currency1 to withdraw from the bond.
    function withdrawBond(uint256 amount) external nonReentrant {
        if (msg.sender != CURATOR) revert IOathVault.NotCurator();
        if (state != IOathVault.State.OPEN) revert IOathVault.NotOpen();
        if (amount > bondBalance) revert IOathVault.InsufficientBond();
        bondBalance -= amount;
        emit IOathVault.BondWithdrawn(amount, bondBalance);
        CURRENCY1.transfer(msg.sender, amount);
    }

    // ---------------------------------------------------------------- open window

    /// @notice Restarts an open window that has run longer than `maxOpen`: `T0 = now`,
    ///         `cumAtOpen = hook.cumulativeNow(key)`. Anyone, OPEN only. Without it, a vault whose curator waited
    ///         too long could never start an epoch, since the start TWAP must span at most `maxOpen` (MATH.md §5).
    /// @dev Reverts `NotOpen()`, or `OpenWindowNotExpired()` unless `now − openSince > maxOpen`.
    function refreshOpenWindow() external nonReentrant {
        if (state != IOathVault.State.OPEN) revert IOathVault.NotOpen();
        // Open windows are hours long; validator timestamp skew of seconds is irrelevant here.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp - openSince <= MAX_OPEN) revert IOathVault.OpenWindowNotExpired();
        _startOpenWindow();
    }

    /// @notice Starts the first open window right after pool initialization: `T0 = now`,
    ///         `cumAtOpen = hook.cumulativeNow(key)`. Factory only, once.
    /// @dev Reverts `OnlyFactory()` or `AlreadyInitialized()`.
    function initOpenWindow() external nonReentrant {
        if (msg.sender != FACTORY) revert IOathVault.OnlyFactory();
        if (openSince != 0) revert IOathVault.AlreadyInitialized();
        _startOpenWindow();
    }

    // ---------------------------------------------------------------- epoch

    /// @notice Starts an epoch: marks the vault at the open-window TWAP, creates the benchmark, checks the size
    ///         cap and the bond, schedules the hook's end-of-epoch checkpoints and opens the curator's position.
    ///         Curator only, OPEN only. Steps (MATH.md §5, §6.1, §10):
    ///         1. `W ≤ now − T0 ≤ maxOpen`.
    ///         2. Start price: `startTick = floorDiv(hook.cumulativeNow − cumAtOpen, now − T0)`,
    ///            `sqrtP_S = getSqrtPriceAtTick(startTick)`.
    ///         3. `navStart = value(idle0, idle1, sqrtP_S)` (the vault holds no position yet), `> 0`.
    ///         4. Benchmark `(L_b, r0, r1) = BenchmarkLib.create(navStart, sqrtP_S)` with the current global fee
    ///            growth `G0, G1`.
    ///         5. Cap `L_b ≤ activeLiquidity · capBps / 10,000` and bond `≥ navStart · minBondBps / 10,000`.
    ///         6. `S = now`, `E = now + epochDuration`, ACTIVE; the hook schedules its checkpoints at `E − W`
    ///            and `E`.
    ///         7. Reposition into `[tickLower, tickUpper)` with the optional swap.
    /// @dev The start price is a TWAP over at least `W`, so moving the spot price at `startEpoch` does not set it,
    ///      and the vault and benchmark both start at `navStart` (MATH.md §6.1). Reverts, in this order:
    ///      `NotCurator()`, `NotOpen()`, `BadRange()`, `OpenWindowTooShort()`, `OpenWindowExpired()`,
    ///      `EmptyVault()`, `VaultTooLarge()`, `BondTooSmall()`; then the reposition's own errors
    ///      (`ExactInputOnly()`, `BondTouched()`, the hook's guard).
    /// @param tickLower Lower tick of the curator's range.
    /// @param tickUpper Upper tick of the curator's range.
    /// @param swap Optional exact-input swap before adding liquidity (`amountSpecified == 0`: none).
    function startEpoch(int24 tickLower, int24 tickUpper, IOathVault.SwapIntent calldata swap) external nonReentrant {
        if (msg.sender != CURATOR) revert IOathVault.NotCurator();
        if (state != IOathVault.State.OPEN) revert IOathVault.NotOpen();
        _checkRange(tickLower, tickUpper);

        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 nowTs = uint32(block.timestamp); // fits until 2106
        uint32 elapsed = nowTs - openSince;
        if (elapsed < TWAP_WINDOW) revert IOathVault.OpenWindowTooShort();
        if (elapsed > MAX_OPEN) revert IOathVault.OpenWindowExpired();

        PoolKey memory key = poolKey();
        int24 startTick = _twapTick(HOOK.cumulativeNow(key) - cumAtOpen, elapsed);
        uint160 sqrtPriceStart = TickMath.getSqrtPriceAtTick(startTick);
        uint256 navStart = ValuationLib.value(idle0(), idle1(), sqrtPriceStart);
        if (navStart == 0) revert IOathVault.EmptyVault();

        (uint128 benchLiquidity, uint256 r0, uint256 r1) = BenchmarkLib.create(navStart, sqrtPriceStart, TICK_SPACING);
        (uint256 g0, uint256 g1) = MANAGER.getFeeGrowthGlobals(POOL_ID);
        if (benchLiquidity > FullMath.mulDiv(MANAGER.getLiquidity(POOL_ID), CAP_BPS, BPS)) {
            revert IOathVault.VaultTooLarge();
        }
        if (bondBalance < FullMath.mulDiv(navStart, MIN_BOND_BPS, BPS)) revert IOathVault.BondTooSmall();
        benchmark = IOathVault.Benchmark({
            L: benchLiquidity, r0: r0, r1: r1, G0: g0, G1: g1, navStart: navStart, startTick: startTick
        });

        uint32 end = nowTs + EPOCH_DURATION;
        epochStart = nowTs;
        epochEnd = end;
        state = IOathVault.State.ACTIVE;
        lastReposition = nowTs;

        emit IOathVault.EpochStarted(
            results.length, nowTs, end, startTick, navStart, benchLiquidity, tickLower, tickUpper
        );

        HOOK.openEpoch(key, end, TWAP_WINDOW);
        _reposition(tickLower, tickUpper, swap);
    }

    /// @notice Moves the vault's position to a new range during an epoch, with an optional exact-input swap in
    ///         between: removes the whole position (principal and uncollected fees become idle), swaps, then adds
    ///         the most liquidity the idle balances buy at the new range. Curator only, while ACTIVE, before `E`,
    ///         and at least `rebalanceCooldown` after the last reposition.
    /// @dev Every cost of a rebalance (swap fees, price impact, rounding) lowers the vault's NAV and not the
    ///      benchmark's, so the curator must beat passive after costs (MATH.md §9.3). The hook's guard bounds the
    ///      price impact of the curator's own swap to `maxIntraBlockTicks` per block, and blocks a same-block
    ///      sandwich of the liquidity changes. Reverts, in this order: `NotCurator()`, `NotActive()`,
    ///      `EpochEnded()` if `now ≥ E`, `Cooldown()` if `now < lastReposition + rebalanceCooldown`, `BadRange()`;
    ///      then the reposition's own errors (`ExactInputOnly()`, `BondTouched()`, the hook's guard).
    /// @param tickLower New lower tick.
    /// @param tickUpper New upper tick.
    /// @param swap Optional exact-input swap between removing and adding liquidity (`amountSpecified == 0`: none).
    function rebalance(int24 tickLower, int24 tickUpper, IOathVault.SwapIntent calldata swap) external nonReentrant {
        if (msg.sender != CURATOR) revert IOathVault.NotCurator();
        if (state != IOathVault.State.ACTIVE) revert IOathVault.NotActive();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 nowTs = uint32(block.timestamp); // fits until 2106
        if (nowTs >= epochEnd) revert IOathVault.EpochEnded();
        if (nowTs < lastReposition + REBALANCE_COOLDOWN) revert IOathVault.Cooldown();
        _checkRange(tickLower, tickUpper);

        lastReposition = nowTs;
        _reposition(tickLower, tickUpper, swap);
        // `L_v` is known only after the reposition; the reentrancy lock is held throughout.
        // forge-lint: disable-next-line(reentrancy-events)
        emit IOathVault.Rebalanced(tickLower, tickUpper, positionLiquidity);
    }

    // ---------------------------------------------------------------- settlement

    /// @notice Settles the epoch against its benchmark (MATH.md §5–§9). Anyone, once `now ≥ E`. Steps, in order:
    ///         1. `hook.poke`: records any due checkpoint and the boundary snapshot at `E` (MATH.md §8).
    ///         2. End price: `endTick = floorDiv(cumB − cumA, W)`, the TWAP over `[E − W, E]`;
    ///            `sqrtP_E = getSqrtPriceAtTick(endTick)`.
    ///         3. Vault NAV at `E` (MATH.md §7): idle balances (unchanged since `E`: the vault is frozen) plus the
    ///            position's principal at `sqrtP_E` and its fees between its last fee-growth-inside and the
    ///            snapshot's fee growth inside at `E`.
    ///         4. Benchmark value at `E` (MATH.md §6.2), with the snapshot's global fee growth at `E`.
    ///         5. Verdict: `SettlementLib.settle` (MATH.md §9).
    ///         6. Apply: the payout moves from the bond to the depositors (the tokens stay in the vault and
    ///            become idle); the fee shares are minted to the curator.
    ///         7. Unwind: remove the whole position; its principal and all uncollected fees, including any earned
    ///            after `E`, become idle.
    ///         8. `hook.closeEpoch`.
    ///         9. Store the `EpochResult` and emit `Settled`.
    ///         10. Reopen: OPEN, with a new open window from now (`T0 = now`, `cumAtOpen = hook.cumulativeNow`).
    /// @dev Both sides are marked at the same TWAP, never at spot, so moving the price at `E` cannot favour
    ///      either (MATH.md §9.3). Between `E` and settlement the position stays in the pool unmeasured; what it
    ///      earns or loses in that gap belongs to the depositors and counts toward the next epoch's start NAV.
    ///      The unwind is subject to the hook's guard: if the price moved more than `maxIntraBlockTicks` earlier in
    ///      the block, `settle` reverts and anyone can retry in a later block. Reverts `NotActive()`,
    ///      `EpochNotEnded()`, or `IOathHook.EpochNotReady()` if the hook has not recorded both checkpoints and
    ///      the snapshot (impossible after the poke; checked anyway).
    function settle() external nonReentrant {
        if (state != IOathVault.State.ACTIVE) revert IOathVault.NotActive();
        // Epochs are days long; validator timestamp skew of seconds is irrelevant here.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < epochEnd) revert IOathVault.EpochNotEnded();
        PoolKey memory key = poolKey();

        // The steps run in the order above. The hook and the PoolManager are trusted and this function holds the
        // reentrancy lock, so the state written and the events emitted after their calls are safe from reentry.

        // 1. Checkpoints and boundary snapshot.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        HOOK.poke(key);
        IOathHook.Epoch memory e = HOOK.epochData(key);
        if (!(e.snapTaken && e.doneA && e.doneB)) revert IOathHook.EpochNotReady();

        // 2. End price: the TWAP over the last W seconds of the epoch.
        IOathVault.EpochResult memory r;
        r.endTick = _twapTick(e.cumB - e.cumA, TWAP_WINDOW);
        uint160 sqrtPriceEnd = TickMath.getSqrtPriceAtTick(r.endTick);

        // 3. Vault NAV at E.
        (r.navEnd, r.vaultFees0, r.vaultFees1) =
            ValuationLib.nav(idle0(), idle1(), _positionMarkedAt(e.fgIn0, e.fgIn1), sqrtPriceEnd);

        // 4. Benchmark value at E.
        IOathVault.Benchmark memory b = benchmark;
        (r.benchEnd, r.benchFees0, r.benchFees1) = BenchmarkLib.valueAt(b, e.G0, e.G1, sqrtPriceEnd, TICK_SPACING);

        // 5. Verdict.
        (r.payout, r.fee, r.feeShares, r.diff, r.band) =
            SettlementLib.settle(r.navEnd, r.benchEnd, bondBalance, totalSupply(), BAND_BPS, PERF_FEE_BPS);

        // 6. Apply.
        bondBalance -= r.payout;
        if (r.feeShares > 0) _mint(CURATOR, r.feeShares);
        if (r.navEnd + r.band < r.benchEnd) {
            // Shortfall beyond the band (`d < −band`). If it exceeds the bond, the rest stays with depositors
            // (MATH.md §9.2).
            uint256 excessShortfall = r.benchEnd - r.navEnd - r.band;
            // forge-lint: disable-next-line(reentrancy-events)
            if (excessShortfall > r.payout) emit IOathVault.BondExhausted(excessShortfall - r.payout);
        }

        // 7. Unwind.
        _unwind();

        // 8. Close the hook's epoch.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        HOOK.closeEpoch(key);

        // 9. Record.
        r.start = epochStart;
        r.end = epochEnd;
        r.startTick = b.startTick;
        r.navStart = b.navStart;
        r.bondAfter = bondBalance;
        uint256 epoch = results.length;
        results.push(r);
        // forge-lint: disable-next-line(reentrancy-events)
        emit IOathVault.Settled(epoch, r);

        // 10. Reopen.
        state = IOathVault.State.OPEN;
        _startOpenWindow();
    }

    // ---------------------------------------------------------------- position

    /// @notice The PoolManager's callback for the vault's own `unlock`. PoolManager only: the PoolManager calls
    ///         back the contract that unlocked it, so only the vault's own repositions and unwinds reach this.
    /// @dev Reverts `OnlyManager()`. See `_onReposition` and `_onUnwind` for the steps.
    /// @param data `abi.encode(Action.REPOSITION, tickLower, tickUpper, swap)` or `abi.encode(Action.UNWIND)`.
    /// @return Empty bytes.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(MANAGER)) revert IOathVault.OnlyManager();
        if (abi.decode(data, (Action)) == Action.UNWIND) {
            _onUnwind();
        } else {
            (, int24 tickLower, int24 tickUpper, IOathVault.SwapIntent memory swap) =
                abi.decode(data, (Action, int24, int24, IOathVault.SwapIntent));
            _onReposition(tickLower, tickUpper, swap);
        }
        return "";
    }

    // ---------------------------------------------------------------- views

    /// @notice Idle currency0: the vault's currency0 balance (its ETH balance if currency0 is native).
    function idle0() public view returns (uint256) {
        return CURRENCY0.balanceOfSelf();
    }

    /// @notice Idle currency1: the vault's currency1 balance minus the bond.
    function idle1() public view returns (uint256) {
        return CURRENCY1.balanceOfSelf() - bondBalance;
    }

    /// @notice The Uniswap v4 PoolManager.
    function manager() external view returns (IPoolManager) {
        return MANAGER;
    }

    /// @notice The pool's Oath hook (the referee).
    function hook() external view returns (IOathHook) {
        return HOOK;
    }

    /// @notice The factory that created this vault.
    function factory() external view returns (address) {
        return FACTORY;
    }

    /// @notice The curator: posts the bond, starts epochs and rebalances.
    function curator() external view returns (address) {
        return CURATOR;
    }

    /// @notice Live mark of the vault and the benchmark at the current spot price, with live fee growth. For
    ///         display only ("live mark (spot)"); settlement marks both at the end-of-epoch TWAP instead.
    ///         - ACTIVE (including after `E` until settled): `navNow` is MATH.md §7 with the pool's live fee growth
    ///           inside the vault's range; `benchNow` is MATH.md §6.2 with the live global fee growth.
    ///         - OPEN (no epoch running): `navNow` is the idle NAV at spot, `benchNow = navNow`, `diff = 0`.
    /// @return navNow Vault NAV at spot.
    /// @return benchNow Benchmark value at spot.
    /// @return diff `navNow − benchNow`.
    function previewLive() external view returns (uint256 navNow, uint256 benchNow, int256 diff) {
        (uint160 sqrtPriceX96,,,) = MANAGER.getSlot0(POOL_ID);
        if (state == IOathVault.State.OPEN) {
            navNow = ValuationLib.value(idle0(), idle1(), sqrtPriceX96);
            return (navNow, navNow, 0);
        }
        (uint256 in0, uint256 in1) = MANAGER.getFeeGrowthInside(POOL_ID, positionLower, positionUpper);
        (navNow,,) = ValuationLib.nav(idle0(), idle1(), _positionMarkedAt(in0, in1), sqrtPriceX96);
        (uint256 g0, uint256 g1) = MANAGER.getFeeGrowthGlobals(POOL_ID);
        (benchNow,,) = BenchmarkLib.valueAt(benchmark, g0, g1, sqrtPriceX96, TICK_SPACING);
        diff = SafeCast.toInt256(navNow) - SafeCast.toInt256(benchNow);
    }

    /// @notice Whether `settle` may be called: `state == ACTIVE && now ≥ epochEnd`.
    function isSettleable() external view returns (bool) {
        // forge-lint: disable-next-line(block-timestamp)
        return state == IOathVault.State.ACTIVE && block.timestamp >= epochEnd;
    }

    /// @notice The result of settled epoch `i`, `0 ≤ i < epochCount()`.
    /// @param i Epoch index.
    function getResult(uint256 i) external view returns (IOathVault.EpochResult memory) {
        return results[i];
    }

    /// @notice Number of settled epochs; also the index of the current epoch while ACTIVE.
    function epochCount() external view returns (uint256) {
        return results.length;
    }

    /// @notice The vault's current position.
    /// @return lower Lower tick.
    /// @return upper Upper tick.
    /// @return liquidity Liquidity `L_v`.
    function positionInfo() external view returns (int24 lower, int24 upper, uint128 liquidity) {
        return (positionLower, positionUpper, positionLiquidity);
    }

    /// @notice The vault's pool key.
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: CURRENCY0,
            currency1: CURRENCY1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(HOOK))
        });
    }

    /// @notice The vault's pool id.
    function poolId() external view returns (PoolId) {
        return POOL_ID;
    }

    /// @notice The vault's fixed parameters (MATH.md §12).
    function params() external view returns (IOathVault.VaultParams memory) {
        return IOathVault.VaultParams({
            epochDuration: EPOCH_DURATION,
            twapWindow: TWAP_WINDOW,
            maxOpen: MAX_OPEN,
            rebalanceCooldown: REBALANCE_COOLDOWN,
            maxIntraBlockTicks: MAX_INTRA_BLOCK_TICKS,
            bandBps: BAND_BPS,
            perfFeeBps: PERF_FEE_BPS,
            minBondBps: MIN_BOND_BPS,
            capBps: CAP_BPS
        });
    }

    // ---------------------------------------------------------------- internal

    /// @dev A later deposit priced against holdings `(h0, h1)` (MATH.md §11): `shares = min_i mulDiv(supply, a_i,
    ///      h_i)` over tokens with `h_i > 0`, `used_i = mulDivUp(h_i, shares, supply) ≤ a_i`. Reverts `EmptyVault()`
    ///      if the vault holds neither token, `ZeroShares()` if the deposit is too small for one share.
    function _proportional(uint256 supply, uint256 a0, uint256 a1, uint256 h0, uint256 h1)
        private
        pure
        returns (uint256 shares, uint256 used0, uint256 used1)
    {
        if (h0 == 0 && h1 == 0) revert IOathVault.EmptyVault();
        shares = type(uint256).max;
        if (h0 != 0) shares = FullMath.mulDiv(supply, a0, h0);
        if (h1 != 0) shares = Math.min(shares, FullMath.mulDiv(supply, a1, h1));
        if (shares == 0) revert IOathVault.ZeroShares();
        used0 = FullMath.mulDivRoundingUp(h0, shares, supply);
        used1 = FullMath.mulDivRoundingUp(h1, shares, supply);
    }

    /// @dev The vault's position for MATH.md §7, marked at fee growth inside `(mark0, mark1)`: the hook's
    ///      snapshot at `E` for settlement, the live value for `previewLive`. The last marks are the fee growth
    ///      inside when its fees were last collected (`getPositionInfo`). With `positionLiquidity == 0` the marks
    ///      are irrelevant: fees and principal are 0.
    function _positionMarkedAt(uint256 mark0, uint256 mark1) private view returns (ValuationLib.Position memory) {
        (int24 lower, int24 upper) = (positionLower, positionUpper);
        (, uint256 last0, uint256 last1) = MANAGER.getPositionInfo(POOL_ID, address(this), lower, upper, POSITION_SALT);
        return ValuationLib.Position({
            liquidity: positionLiquidity,
            tickLower: lower,
            tickUpper: upper,
            feeGrowthInside0Last: last0,
            feeGrowthInside1Last: last1,
            feeGrowthInside0Mark: mark0,
            feeGrowthInside1Mark: mark1
        });
    }

    /// @dev Range rule for `startEpoch` and `rebalance`: `tickLower < tickUpper`, both multiples of `tickSpacing`,
    ///      both within the usable ticks `[minUsableTick, maxUsableTick]`. Reverts `BadRange()`.
    function _checkRange(int24 tickLower, int24 tickUpper) private view {
        if (
            tickLower >= tickUpper || tickLower % TICK_SPACING != 0 || tickUpper % TICK_SPACING != 0
                || tickLower < TickMath.minUsableTick(TICK_SPACING) || tickUpper > TickMath.maxUsableTick(TICK_SPACING)
        ) revert IOathVault.BadRange();
    }

    /// @dev The TWAP tick over `elapsed` seconds whose tick cumulative grew by `cumulativeDelta` (MATH.md §4):
    ///      `floorDiv(cumulativeDelta, elapsed)`, rounding toward −∞ (if the quotient is negative and there is a
    ///      remainder, subtract 1), as Uniswap v3's oracle does. `elapsed > 0`.
    function _twapTick(int256 cumulativeDelta, uint32 elapsed) private pure returns (int24) {
        int256 dt = int256(uint256(elapsed));
        int256 tick = cumulativeDelta / dt;
        if (cumulativeDelta < 0 && cumulativeDelta % dt != 0) tick--;
        // A time-weighted mean of ticks in [MIN_TICK, MAX_TICK] stays in that range, so it fits int24.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(tick);
    }

    /// @dev Moves the vault's position to `[tickLower, tickUpper)`, with an optional swap in between, in one
    ///      `unlock` of the PoolManager (`_onReposition`).
    function _reposition(int24 tickLower, int24 tickUpper, IOathVault.SwapIntent calldata swap) private {
        // forge-lint: disable-next-line(unused-return)
        MANAGER.unlock(abi.encode(Action.REPOSITION, tickLower, tickUpper, swap)); // the callback returns nothing
    }

    /// @dev Removes the whole position in one `unlock` of the PoolManager (`_onUnwind`).
    function _unwind() private {
        // forge-lint: disable-next-item(reentrancy-no-eth,unused-return)
        MANAGER.unlock(abi.encode(Action.UNWIND)); // the callback returns nothing
    }

    /// @dev The reposition, inside the unlock:
    ///      1. If the vault has a position, remove all of it. The credit is principal plus all uncollected fees.
    ///      2. If `swap.amountSpecified != 0`, swap; exact input only (`amountSpecified < 0`), else
    ///         `ExactInputOnly()`.
    ///      3. Settle both currencies' net deltas (take credits, pay debts from idle), then require
    ///         `balance1 ≥ bondBalance`, else `BondTouched()`: a reposition never spends the bond.
    ///      4. Add the most liquidity the idle balances buy at the current price:
    ///         `L_new = getLiquidityForAmounts(sqrtP, sqrtAt(lower), sqrtAt(upper), idle0 − 1, idle1 − 1)`,
    ///         saturating at 0. The 1-wei buffer absorbs the pool's round-up of the amounts it charges.
    ///      5. Store the new range and `L_new`.
    ///      The hook's intra-block guard runs on steps 1 and 4, so the whole reposition reverts if the price moved
    ///      more than `maxIntraBlockTicks` within the block, including through the curator's own swap.
    function _onReposition(int24 tickLower, int24 tickUpper, IOathVault.SwapIntent memory swap) private {
        // The PoolManager is trusted and every entry point holds the vault's reentrancy lock, so the position is
        // safely stored after the calls below.
        PoolKey memory key = poolKey();
        BalanceDelta delta = _removePosition(key);
        if (swap.amountSpecified != 0) {
            if (swap.amountSpecified > 0) revert IOathVault.ExactInputOnly();
            // forge-lint: disable-next-item(reentrancy-no-eth)
            delta = delta
                + MANAGER.swap(
                    key,
                    SwapParams({
                        zeroForOne: swap.zeroForOne,
                        amountSpecified: swap.amountSpecified,
                        sqrtPriceLimitX96: swap.sqrtPriceLimitX96
                    }),
                    ""
                );
        }
        _settle(delta);
        if (CURRENCY1.balanceOfSelf() < bondBalance) revert IOathVault.BondTouched();

        (uint160 sqrtPriceX96,,,) = MANAGER.getSlot0(POOL_ID);
        uint128 newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            _lessOneWei(idle0()),
            _lessOneWei(idle1())
        );
        if (newLiquidity > 0) {
            // forge-lint: disable-next-item(reentrancy-no-eth,unused-return)
            (BalanceDelta added,) = MANAGER.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(uint256(newLiquidity)),
                    salt: POSITION_SALT
                }),
                ""
            );
            _settle(added);
        }
        positionLower = tickLower;
        positionUpper = tickUpper;
        positionLiquidity = newLiquidity;
    }

    /// @dev Removes the vault's whole position from the pool, inside the unlock (settlement step 7):
    ///      principal and all uncollected fees, including any earned after `E`, become idle; `L_v = 0`. The range
    ///      is kept as the last position's. The hook's guard runs on the removal.
    function _onUnwind() private {
        _settle(_removePosition(poolKey()));
        positionLiquidity = 0;
    }

    /// @dev Removes all of the vault's liquidity, if it has any. The returned credit is principal plus all
    ///      uncollected fees (`callerDelta` already includes them, so `feesAccrued` is unused).
    function _removePosition(PoolKey memory key) private returns (BalanceDelta delta) {
        uint128 liquidity = positionLiquidity;
        if (liquidity == 0) return delta;
        // forge-lint: disable-next-item(reentrancy-no-eth,unused-return)
        (delta,) = MANAGER.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: positionLower,
                tickUpper: positionUpper,
                liquidityDelta: -int256(uint256(liquidity)),
                salt: POSITION_SALT
            }),
            ""
        );
    }

    /// @dev Clears the vault's deltas with the PoolManager: takes each credit into the vault and pays each debt
    ///      from the vault's balance.
    function _settle(BalanceDelta delta) private {
        _settleCurrency(CURRENCY0, delta.amount0());
        _settleCurrency(CURRENCY1, delta.amount1());
    }

    /// @dev Takes `amount > 0` of `currency` from the PoolManager, or pays `−amount` if negative.
    function _settleCurrency(Currency currency, int128 amount) private {
        // Both casts are of a positive int128, so they cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (amount > 0) currency.take(MANAGER, address(this), uint128(amount), false);
        // forge-lint: disable-next-line(unsafe-typecast)
        else if (amount < 0) currency.settle(MANAGER, address(this), uint128(-amount), false);
    }

    /// @dev `amount − 1`, or 0 if `amount` is 0.
    function _lessOneWei(uint256 amount) private pure returns (uint256) {
        return amount == 0 ? 0 : amount - 1;
    }

    /// @dev Starts an open window at now: records `T0` and the hook's cumulative at `T0`.
    function _startOpenWindow() private {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 nowTs = uint32(block.timestamp); // fits until 2106
        int256 cumulative = HOOK.cumulativeNow(poolKey());
        openSince = nowTs;
        cumAtOpen = cumulative;
        // Reached from `settle` after its trusted hook and PoolManager calls, under the reentrancy lock.
        // forge-lint: disable-next-line(reentrancy-events)
        emit IOathVault.OpenWindowRefreshed(nowTs, cumulative);
    }

    /// @dev Share token name: `"Oath <sym0>/<sym1>"`.
    function _shareName(PoolKey memory key_) private view returns (string memory) {
        return string.concat("Oath ", _symbolOf(key_.currency0), "/", _symbolOf(key_.currency1));
    }

    /// @dev Share token symbol: `"oath-<sym0>-<sym1>"`.
    function _shareSymbol(PoolKey memory key_) private view returns (string memory) {
        return string.concat("oath-", _symbolOf(key_.currency0), "-", _symbolOf(key_.currency1));
    }

    /// @dev `"ETH"` for native currency, otherwise the token's `symbol()`.
    function _symbolOf(Currency currency) private view returns (string memory) {
        return currency.isAddressZero() ? "ETH" : IERC20Metadata(Currency.unwrap(currency)).symbol();
    }
}
