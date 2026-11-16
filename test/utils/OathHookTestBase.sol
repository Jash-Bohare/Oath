// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
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

    OathHook internal hook;
    PoolId internal id;
    uint32 internal createdAt;

    function setUp() public virtual override {
        super.setUp();
        hook = OathHook(address(_deployOathHook(factory)));
        key = _oathKey(currency0, currency1);
        id = key.toId();
    }

    /// @dev Registers `vault`, creates the pool through the factory at `tick`, and adds deep full-range
    ///      liquidity from a non-vault LP.
    function _createPool(int24 tick) internal {
        vm.prank(factory);
        hook.registerVault(key, vault, 50);
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

    /// @dev Live block values. Under via_ir the optimizer may treat `block.timestamp` and `block.number` as
    ///      constant within the test's transaction, so after `vm.warp`/`vm.roll` read them through the cheatcodes.
    function _time() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _block() internal view returns (uint256) {
        return vm.getBlockNumber();
    }

    function _wait(uint256 dt) internal {
        vm.warp(_time() + dt);
    }

    function _nextBlock(uint256 dt) internal {
        vm.roll(_block() + 1);
        vm.warp(_time() + dt);
    }
}
