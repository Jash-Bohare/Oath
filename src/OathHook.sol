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
contract OathHook is BaseHook {
    /// @notice The only address allowed to register vaults and initialize pools with this hook.
    /// @dev Lower-case because it implements `IOathHook.factory()`.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable factory;

    /// @notice Per-pool TWAP accumulator state (MATH.md §4).
    mapping(PoolId => IOathHook.Oracle) public oracles;
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
        cfg.vault = vault;
        cfg.maxIntraBlockTicks = maxIntraBlockTicks;
        emit IOathHook.VaultRegistered(id, vault);
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
