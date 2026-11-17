// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IOathHook} from "./IOathHook.sol";
import {IOathVault} from "./IOathVault.sol";

/// @title IOathFactory
/// @notice Creates an Oath pool and its single vault atomically: deploys the vault, registers it with the hook,
///         initializes the pool and opens the vault's first open window. It is the only address the hook lets
///         create pools, and it validates every vault parameter (MATH.md §12). No owner, no storage.
interface IOathFactory {
    /// @notice Emitted when a vault and its pool are created.
    event VaultCreated(PoolId indexed id, address indexed vault, address indexed curator);

    /// @notice The hook was deployed for a different factory (`hook.factory() != address(this)`).
    error HookFactoryMismatch();
    /// @notice `createVault` with the zero address as curator.
    error ZeroCurator();
    /// @notice `createVault` with a dynamic-fee pool: the hook never sets a fee, so it would trade at 0%.
    error DynamicFee();
    /// @notice `twapWindow` outside 5 min – 2 h.
    error BadTwapWindow();
    /// @notice `epochDuration` below `2 × twapWindow`.
    error BadEpochDuration();
    /// @notice `maxOpen` not above `twapWindow`.
    error BadMaxOpen();
    /// @notice `rebalanceCooldown` above `epochDuration`.
    error BadRebalanceCooldown();
    /// @notice `maxIntraBlockTicks` outside 1 – 1,000.
    error BadMaxIntraBlockTicks();
    /// @notice `bandBps` above 500.
    error BadBand();
    /// @notice `perfFeeBps` above 5,000.
    error BadPerfFee();
    /// @notice `minBondBps` below 100.
    error BadMinBond();
    /// @notice `capBps` outside 1 – 1,000.
    error BadCap();

    /// @notice The Uniswap v4 PoolManager.
    /// @return The PoolManager.
    function manager() external view returns (IPoolManager);

    /// @notice The Oath hook every pool created here uses.
    /// @return The hook.
    function hook() external view returns (IOathHook);

    /// @notice Creates the pool `(currency0, currency1, fee, tickSpacing, hook)` at `sqrtPriceX96` with a new
    ///         vault for `curator`, atomically. Anyone may call; one vault per pool key (the hook rejects a second
    ///         registration with `AlreadyRegistered()`).
    /// @dev Reverts, in this order: `ZeroCurator()`, `DynamicFee()`, then the parameter bounds in the order the
    ///      errors are declared. Currency order, fee size and tick spacing are checked by the PoolManager.
    /// @param currency0 The pool's currency0 (`address(0)` for native ETH).
    /// @param currency1 The pool's currency1, the numeraire (MATH.md §1).
    /// @param fee The pool's static LP fee in pips.
    /// @param tickSpacing The pool's tick spacing.
    /// @param sqrtPriceX96 The pool's initial price.
    /// @param curator The vault's curator.
    /// @param params The vault's fixed parameters.
    /// @return vault The new vault.
    function createVault(
        Currency currency0,
        Currency currency1,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96,
        address curator,
        IOathVault.VaultParams calldata params
    ) external returns (address vault);
}
