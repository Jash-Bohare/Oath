// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IOathFactory} from "./interfaces/IOathFactory.sol";
import {IOathHook} from "./interfaces/IOathHook.sol";
import {IOathVault} from "./interfaces/IOathVault.sol";
import {OathVault} from "./OathVault.sol";

/// @title OathFactory
/// @notice Creates an Oath pool and its single vault atomically: deploy the vault, register it with the hook,
///         initialize the pool, open the vault's first open window. The hook lets only this factory create pools,
///         and trusts it to validate every vault parameter (MATH.md §12). No owner, no storage.
contract OathFactory is IOathFactory {
    using LPFeeLibrary for uint24;

    /// @dev Parameter bounds (MATH.md §12).
    uint256 private constant MIN_TWAP_WINDOW = 5 minutes;
    uint256 private constant MAX_TWAP_WINDOW = 2 hours;
    int24 private constant MAX_INTRA_BLOCK_TICKS = 1_000;
    uint256 private constant MAX_BAND_BPS = 500;
    uint256 private constant MAX_PERF_FEE_BPS = 5_000;
    uint256 private constant MIN_BOND_BPS_FLOOR = 100;
    uint256 private constant MAX_CAP_BPS = 1_000;

    IPoolManager private immutable MANAGER;
    IOathHook private immutable HOOK;

    /// @param manager_ The Uniswap v4 PoolManager.
    /// @param hook_ The Oath hook, deployed with this factory's address (predicted before deployment).
    /// @dev Reverts `HookFactoryMismatch()` unless `hook_.factory() == address(this)`.
    constructor(IPoolManager manager_, IOathHook hook_) {
        if (hook_.factory() != address(this)) revert HookFactoryMismatch();
        MANAGER = manager_;
        HOOK = hook_;
    }

    /// @inheritdoc IOathFactory
    function manager() external view returns (IPoolManager) {
        return MANAGER;
    }

    /// @inheritdoc IOathFactory
    function hook() external view returns (IOathHook) {
        return HOOK;
    }

    /// @inheritdoc IOathFactory
    function createVault(
        Currency currency0,
        Currency currency1,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96,
        address curator,
        IOathVault.VaultParams calldata params
    ) external returns (address vault) {
        if (curator == address(0)) revert ZeroCurator();
        if (fee.isDynamicFee()) revert DynamicFee();
        _validate(params);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(address(HOOK))
        });
        OathVault newVault = new OathVault(MANAGER, HOOK, key, curator, params);
        vault = address(newVault);
        HOOK.registerVault(key, vault, params.maxIntraBlockTicks);
        // forge-lint: disable-next-line(unused-return)
        MANAGER.initialize(key, sqrtPriceX96); // the returned start tick is not needed
        newVault.initOpenWindow();

        // After the calls because the vault's address only exists after `new`. They go to the hook, the
        // PoolManager and the new vault; the only foreign code is a token's `symbol()` in the vault's
        // constructor, and re-entering `createVault` from there either uses another key (harmless) or this
        // key (this call then reverts `AlreadyRegistered`).
        // forge-lint: disable-next-line(reentrancy-events)
        emit VaultCreated(key.toId(), vault, curator);
    }

    /// @dev The parameter bounds (MATH.md §12), one error per rule.
    function _validate(IOathVault.VaultParams calldata p) private pure {
        if (p.twapWindow < MIN_TWAP_WINDOW || p.twapWindow > MAX_TWAP_WINDOW) revert BadTwapWindow();
        if (p.epochDuration < 2 * uint256(p.twapWindow)) revert BadEpochDuration();
        if (p.maxOpen <= p.twapWindow) revert BadMaxOpen();
        if (p.rebalanceCooldown > p.epochDuration) revert BadRebalanceCooldown();
        if (p.maxIntraBlockTicks < 1 || p.maxIntraBlockTicks > MAX_INTRA_BLOCK_TICKS) revert BadMaxIntraBlockTicks();
        if (p.bandBps > MAX_BAND_BPS) revert BadBand();
        if (p.perfFeeBps > MAX_PERF_FEE_BPS) revert BadPerfFee();
        if (p.minBondBps < MIN_BOND_BPS_FLOOR) revert BadMinBond();
        if (p.capBps < 1 || p.capBps > MAX_CAP_BPS) revert BadCap();
    }
}
