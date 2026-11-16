// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
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
contract OathVault is ERC20 {
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

    // ---------------------------------------------------------------- open window

    /// @notice Starts the first open window right after pool initialization: `T0 = now`,
    ///         `cumAtOpen = hook.cumulativeNow(key)`. Factory only, once.
    /// @dev Reverts `OnlyFactory()` or `AlreadyInitialized()`.
    function initOpenWindow() external {
        if (msg.sender != FACTORY) revert IOathVault.OnlyFactory();
        if (openSince != 0) revert IOathVault.AlreadyInitialized();
        _startOpenWindow();
    }

    // ---------------------------------------------------------------- views

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
