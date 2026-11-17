// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IOathHook} from "./interfaces/IOathHook.sol";
import {IOathVault} from "./interfaces/IOathVault.sol";

/// @title OathVault
/// @notice A curated two-token vault in one Oath pool. Depositors receive ERC-20 shares; the curator posts a
///         currency1 bond and manages one concentrated position, measured every epoch against an exact on-chain
///         counterfactual (MATH.md §6, §9). Created only by `OathFactory`, which also creates its pool.
/// @dev Pool key and parameters are fixed at creation and held as immutables. Values are in raw currency1 units
///      (MATH.md §1).
contract OathVault is ERC20, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Shares minted to `DEAD` on the first deposit, so the share price cannot be inflated (MATH.md §11).
    uint256 public constant MIN_SHARES = 1_000;
    /// @notice Holder of the permanently locked `MIN_SHARES`.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

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
    /// @dev OPEN (the zero value) until `startEpoch` exists to move it to ACTIVE.
    // forge-lint: disable-next-line(uninitialized-state)
    IOathVault.State public state;
    /// @notice Currency1 held as the curator's bond. Part of the vault's currency1 balance, but not of `idle1`
    ///         or of NAV.
    uint256 public bondBalance;
    /// @notice Open-window start `T0`: when the current open window began.
    uint32 public openSince;
    /// @notice The hook's tick cumulative at `T0`, the start of the open-window TWAP (MATH.md §5).
    int256 public cumAtOpen;

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

    /// @dev Starts an open window at now: records `T0` and the hook's cumulative at `T0`.
    function _startOpenWindow() private {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 nowTs = uint32(block.timestamp); // fits until 2106
        int256 cumulative = HOOK.cumulativeNow(poolKey());
        openSince = nowTs;
        cumAtOpen = cumulative;
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
