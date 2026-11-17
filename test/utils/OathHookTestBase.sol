// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolModifyLiquidityTestNoChecks} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTestNoChecks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {OathHook} from "../../src/OathHook.sol";
import {OathTestBase} from "./OathTestBase.sol";

/// @title OathHookTestBase
/// @notice Shared setup for OathHook tests on the real PoolManager: the hook at its flagged address, an Oath
///         pool created through the (pranked) factory with deep full-range liquidity, and time helpers.
abstract contract OathHookTestBase is OathTestBase {
    using StateLibrary for IPoolManager;

    /// @dev The demo pool's start tick on the Nov 8 mainnet fork ($2,235.94 per ETH, MATH.md §9.1).
    int24 internal constant START_TICK = -199196;
    /// @dev Full-range liquidity deep enough to move the price anywhere the tests need.
    uint256 internal constant DEPTH = 1e24;

    address internal factory = makeAddr("factory");
    /// @dev The pool's registered vault. Tests that need the vault to add liquidity point it at a router.
    address internal vault = makeAddr("vault");
    /// @dev The guard threshold registered with the vault (the default parameter, MATH.md §12).
    int24 internal maxIntraBlockTicks = 50;

    OathHook internal hook;
    PoolId internal id;
    uint32 internal createdAt;
    /// @dev Set by `_useVaultRouter`: a liquidity router registered as the vault, so the vault's own liquidity
    ///      changes reach the hook with `sender == vault`, as the real vault's will.
    PoolModifyLiquidityTestNoChecks internal vaultRouter;

    function setUp() public virtual override {
        super.setUp();
        hook = OathHook(address(_deployOathHook(factory)));
        key = _oathKey(currency0, currency1);
        id = key.toId();
    }

    /// @dev Registers `vault` with `maxIntraBlockTicks`, creates the pool through the factory at `tick`, and
    ///      adds deep full-range liquidity from a non-vault LP.
    function _createPool(int24 tick) internal {
        vm.prank(factory);
        hook.registerVault(key, vault, maxIntraBlockTicks);
        _initializeAt(tick);
        (int24 tickMin, int24 tickMax) = _fullRange();
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickMin, tickUpper: tickMax, liquidityDelta: int256(DEPTH), salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    /// @dev Makes a fresh liquidity router the pool's vault. Call before `_createPool`. It pulls tokens from this
    ///      test contract and does not assert on one-sided withdrawals.
    function _useVaultRouter() internal {
        vaultRouter = new PoolModifyLiquidityTestNoChecks(manager);
        MockERC20(Currency.unwrap(currency0)).approve(address(vaultRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(vaultRouter), type(uint256).max);
        vault = address(vaultRouter);
    }

    /// @dev Changes the vault's liquidity on `[lower, upper)` (salt 0) through the vault router.
    function _vaultModify(int24 lower, int24 upper, int256 liquidityDelta) internal returns (BalanceDelta) {
        return vaultRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: liquidityDelta, salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function _initializeAt(int24 tick) internal {
        vm.prank(factory);
        manager.initialize(key, TickMath.getSqrtPriceAtTick(tick));
        createdAt = uint32(_time());
        assertEq(_tick(), tick, "created at tick");
    }

    /// @dev Opens an epoch as the vault.
    function _openEpoch(uint32 epochEnd, uint32 twapWindow) internal {
        vm.prank(vault);
        hook.openEpoch(key, epochEnd, twapWindow);
    }

    function _moveToTick(int24 tick) internal {
        _moveTo(key, TickMath.getSqrtPriceAtTick(tick));
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(id);
    }
}
