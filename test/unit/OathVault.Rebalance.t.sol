// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {ValuationLib} from "../../src/libraries/ValuationLib.sol";
import {OathVaultTestBase} from "../utils/OathVaultTestBase.sol";

/// @notice Moving the vault's position during an epoch, on a vault created through the real factory and started
///         with the MATH.md §9.1 worked example.
contract OathVaultRebalanceTest is OathVaultTestBase {
    using StateLibrary for IPoolManager;

    uint256 internal startedAt;

    function setUp() public override {
        super.setUp();
        _createVault(currency0);
        _startWorkedExample();
        startedAt = _time();
    }

    /// @dev The whole old position comes back (no fees yet: no swaps) and the most liquidity the idle balances
    ///      buy, less the 1-wei buffer, goes into the new range. The pool, the vault and the hook all agree.
    function test_rebalance_movesPosition() public {
        _nextBlock(1 hours);
        int24 lower = -199600;
        int24 upper = -198800;
        uint128 expected = _expectedLiquidity(lower, upper);

        vm.expectEmit(false, false, false, true, address(vault));
        emit IOathVault.Rebalanced(lower, upper, expected);
        _rebalance(lower, upper, _noSwap());

        (int24 l, int24 u, uint128 liquidity) = vault.positionInfo();
        assertEq(l, lower);
        assertEq(u, upper);
        assertEq(liquidity, expected, "L_v");
        assertEq(_poolPositionLiquidity(lower, upper), expected, "new pool position");
        assertEq(_poolPositionLiquidity(RANGE_LOWER, RANGE_UPPER), 0, "old position fully removed");
        (,, int24 vaultLower, int24 vaultUpper) = hook.configs(key.toId());
        assertEq(vaultLower, lower, "hook range lower");
        assertEq(vaultUpper, upper, "hook range upper");

        assertEq(vault.lastReposition(), _time(), "lastReposition");
        assertEq(uint8(vault.state()), uint8(IOathVault.State.ACTIVE));
        assertEq(vault.epochEnd(), startedAt + 7 days, "epoch unchanged");
        assertEq(vault.bondBalance(), BOND, "bond untouched");
    }

    // ---------------------------------------------------------------- helpers

    function _rebalance(int24 lower, int24 upper, IOathVault.SwapIntent memory swap) internal {
        vm.prank(curator);
        vault.rebalance(lower, upper, swap);
    }

    /// @dev `L_new` for a rebalance into `[lower, upper)` without a swap, when the position has no uncollected
    ///      fees: the idle balances plus the old position's principal at spot (exactly what v4 returns), less the
    ///      1-wei buffer.
    function _expectedLiquidity(int24 lower, int24 upper) internal view returns (uint128) {
        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        (int24 oldLower, int24 oldUpper, uint128 oldLiquidity) = vault.positionInfo();
        (uint256 p0, uint256 p1) = ValuationLib.principal(oldLiquidity, oldLower, oldUpper, sqrtP);
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtP,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            vault.idle0() + p0 - 1,
            vault.idle1() + p1 - 1
        );
    }
}
