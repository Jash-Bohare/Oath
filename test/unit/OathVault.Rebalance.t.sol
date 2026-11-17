// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IOathHook} from "../../src/interfaces/IOathHook.sol";
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

    // ---------------------------------------------------------------- access and timing

    function testFuzz_rebalance_onlyCurator(address caller) public {
        vm.assume(caller != curator);
        _nextBlock(1 hours);
        vm.prank(caller);
        vm.expectRevert(IOathVault.NotCurator.selector);
        vault.rebalance(RANGE_LOWER, RANGE_UPPER, _noSwap());
    }

    /// @dev No rebalance in the open window.
    function test_rebalance_notActive() public {
        _createVault(CurrencyLibrary.ADDRESS_ZERO); // a fresh vault, still OPEN
        vm.expectRevert(IOathVault.NotActive.selector);
        _rebalance(RANGE_LOWER, RANGE_UPPER, _noSwap());
    }

    /// @dev `now ≥ lastReposition + rebalanceCooldown` (1 h after `startEpoch`), inclusive.
    function test_rebalance_cooldownBoundary() public {
        vm.roll(_block() + 1);
        vm.warp(startedAt + 1 hours - 1);
        vm.expectRevert(IOathVault.Cooldown.selector);
        _rebalance(RANGE_LOWER, RANGE_UPPER, _noSwap());

        vm.warp(startedAt + 1 hours);
        _rebalance(RANGE_LOWER, RANGE_UPPER, _noSwap());
        assertEq(vault.lastReposition(), startedAt + 1 hours);
    }

    /// @dev Each rebalance restarts the cooldown.
    function test_rebalance_cooldownRestarts() public {
        _nextBlock(1 hours);
        _rebalance(RANGE_LOWER, RANGE_UPPER, _noSwap());
        uint256 first = _time();

        _nextBlock(1 hours - 1);
        vm.expectRevert(IOathVault.Cooldown.selector);
        _rebalance(RANGE_LOWER, RANGE_UPPER, _noSwap());
        vm.warp(first + 1 hours);
        _rebalance(RANGE_LOWER, RANGE_UPPER, _noSwap());
    }

    /// @dev The vault is frozen from `E`: one second before `E` is the last chance to rebalance.
    function test_rebalance_epochEndBoundary() public {
        uint256 end = vault.epochEnd();
        assertEq(end, startedAt + 7 days);
        vm.roll(_block() + 1);
        vm.warp(end);
        vm.expectRevert(IOathVault.EpochEnded.selector);
        _rebalance(RANGE_LOWER, RANGE_UPPER, _noSwap());

        vm.warp(end - 1);
        _rebalance(RANGE_LOWER, RANGE_UPPER, _noSwap());
        assertEq(vault.lastReposition(), end - 1);
    }

    /// @dev Same range rule as `startEpoch`.
    function test_rebalance_badRange() public {
        _nextBlock(1 hours);
        (int24 tickMin, int24 tickMax) = _fullRange();
        int24[2][6] memory bad = [
            [RANGE_LOWER, RANGE_LOWER], // empty
            [RANGE_UPPER, RANGE_LOWER], // reversed
            [RANGE_LOWER - 5, RANGE_UPPER], // lower off the spacing
            [RANGE_LOWER, RANGE_UPPER + 5], // upper off the spacing
            [tickMin - TICK_SPACING, RANGE_UPPER], // below the usable ticks
            [RANGE_LOWER, tickMax + TICK_SPACING] // above the usable ticks
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(IOathVault.BadRange.selector);
            _rebalance(bad[i][0], bad[i][1], _noSwap());
        }
    }

    /// @dev Exact output (`amountSpecified > 0`) is rejected.
    function test_rebalance_exactInputOnly() public {
        _nextBlock(1 hours);
        vm.expectRevert(IOathVault.ExactInputOnly.selector);
        _rebalance(
            RANGE_LOWER,
            RANGE_UPPER,
            IOathVault.SwapIntent({
                zeroForOne: true, amountSpecified: 1, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
    }

    // ---------------------------------------------------------------- value and fees

    /// @dev Outside swaps through the range earn the position fees. Rebalancing (here into the same range,
    ///      no swap) collects them into the vault and re-adds everything, so the NAV marked at spot is preserved
    ///      up to rounding: v4 returns principal and fees exactly, and re-adding costs at most 1 raw unit of each
    ///      currency (the pool rounds the cost up and the principal down), worth at most `value(1, 1) + 1`.
    function test_rebalance_collectsFeesAndPreservesNav() public {
        for (uint256 i; i < 4; ++i) {
            _nextBlock(10 minutes);
            _moveToTick(START_TICK - 40);
            _nextBlock(10 minutes);
            _moveToTick(START_TICK + 40);
        }
        _nextBlock(1 hours);
        (uint256 navBefore, uint256 feesBefore) = _liveNav();
        assertGt(feesBefore, 1e6, "position earned > $1 of fees");

        _rebalance(RANGE_LOWER, RANGE_UPPER, _noSwap());
        (uint256 navAfter, uint256 feesAfter) = _liveNav();
        assertEq(feesAfter, 0, "fees collected");
        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        assertLe(navAfter, navBefore, "no value created");
        assertLe(navBefore - navAfter, ValuationLib.value(1, 1, sqrtP) + 1, "only rounding lost");
    }

    // ---------------------------------------------------------------- guard and bond

    /// @dev Someone moves the price more than `maxIntraBlockTicks` (50) earlier in the same block: the removal of
    ///      the old position hits the hook's guard and the whole rebalance reverts.
    function test_rebalance_guardBlocksSameBlockMove() public {
        _nextBlock(1 hours);
        _moveToTick(START_TICK + 51);
        vm.expectRevert(
            _hookError(
                IHooks.beforeRemoveLiquidity.selector,
                abi.encodeWithSelector(IOathHook.PriceMovedThisBlock.selector, START_TICK + 51, START_TICK)
            )
        );
        _rebalance(RANGE_LOWER, RANGE_UPPER, _noSwap());
    }

    /// @dev After the removal the vault can spend exactly its idle currency1 (idle plus the principal it got
    ///      back; no fees yet). One raw unit more would spend the bond and reverts; exactly that much passes and
    ///      leaves the bond whole.
    function test_rebalance_swapCannotSpendBond() public {
        _nextBlock(1 hours);
        (, uint256 available1) = _availableAfterRemoval();
        IOathVault.SwapIntent memory tooMuch = IOathVault.SwapIntent({
            zeroForOne: false, amountSpecified: -int256(available1 + 1), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        vm.expectRevert(IOathVault.BondTouched.selector);
        _rebalance(RANGE_LOWER, RANGE_UPPER, tooMuch);

        _rebalance(
            RANGE_LOWER,
            RANGE_UPPER,
            IOathVault.SwapIntent({
                zeroForOne: false, amountSpecified: -int256(available1), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            })
        );
        assertEq(vault.idle1(), 0, "all idle currency1 spent");
        assertEq(vault.bondBalance(), BOND);
        assertEq(c1.balanceOf(address(vault)), BOND, "only the bond is left");
    }

    /// @dev Whatever the new range and swap (within what the vault holds), a rebalance never spends the bond,
    ///      and the pool holds exactly `L_v` in the new range and nothing in the old one.
    function testFuzz_rebalance_neverSpendsBond(bool zeroForOne, uint256 amountIn, int256 lowerSeed, uint256 width)
        public
    {
        _nextBlock(1 hours);
        (uint256 available0, uint256 available1) = _availableAfterRemoval();
        amountIn = bound(amountIn, 1, zeroForOne ? available0 : available1); // ~41 ticks at most, inside the guard
        int24 lower = int24(bound(lowerSeed, -2_010, -1_970)) * TICK_SPACING * 10;
        int24 upper = lower + int24(int256(bound(width, 1, 400))) * TICK_SPACING;
        vm.assume(lower != RANGE_LOWER || upper != RANGE_UPPER);

        _rebalance(
            lower,
            upper,
            IOathVault.SwapIntent({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
        assertEq(vault.bondBalance(), BOND, "bond balance");
        assertEq(c1.balanceOf(address(vault)), vault.idle1() + BOND, "bond tokens still held");
        (,, uint128 liquidity) = vault.positionInfo();
        assertEq(_poolPositionLiquidity(lower, upper), liquidity, "pool position = L_v");
        assertEq(_poolPositionLiquidity(RANGE_LOWER, RANGE_UPPER), 0, "old position removed");
    }

    // ---------------------------------------------------------------- helpers

    function _rebalance(int24 lower, int24 upper, IOathVault.SwapIntent memory swap) internal {
        vm.prank(curator);
        vault.rebalance(lower, upper, swap);
    }

    /// @dev What the vault holds right after removing its position at the current price, with no fees owed:
    ///      idle plus principal (exactly what v4 returns).
    function _availableAfterRemoval() internal view returns (uint256 a0, uint256 a1) {
        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        (int24 lower, int24 upper, uint128 liquidity) = vault.positionInfo();
        (uint256 p0, uint256 p1) = ValuationLib.principal(liquidity, lower, upper, sqrtP);
        return (vault.idle0() + p0, vault.idle1() + p1);
    }

    /// @dev The vault's NAV marked at spot with live fee growth (MATH.md §7), and the position's uncollected fees
    ///      valued at spot.
    function _liveNav() internal view returns (uint256 navNow, uint256 fees) {
        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        (int24 lower, int24 upper, uint128 liquidity) = vault.positionInfo();
        (, uint256 last0, uint256 last1) =
            manager.getPositionInfo(key.toId(), address(vault), lower, upper, vault.POSITION_SALT());
        (uint256 in0, uint256 in1) = manager.getFeeGrowthInside(key.toId(), lower, upper);
        ValuationLib.Position memory position = ValuationLib.Position({
            liquidity: liquidity,
            tickLower: lower,
            tickUpper: upper,
            feeGrowthInside0Last: last0,
            feeGrowthInside1Last: last1,
            feeGrowthInside0Mark: in0,
            feeGrowthInside1Mark: in1
        });
        uint256 fees0;
        uint256 fees1;
        (navNow, fees0, fees1) = ValuationLib.nav(vault.idle0(), vault.idle1(), position, sqrtP);
        fees = ValuationLib.value(fees0, fees1, sqrtP);
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

/// @notice The hook's guard bounds the price impact of the curator's own rebalance swap to `maxIntraBlockTicks` per
///         block (here 10, so the worked-example vault can afford a swap past it).
contract OathVaultRebalanceSwapBoundTest is OathVaultTestBase {
    using StateLibrary for IPoolManager;

    function setUp() public override {
        super.setUp();
        IOathVault.VaultParams memory p = _defaultParams();
        p.maxIntraBlockTicks = 10;
        _createVault(currency0, p);
        _startWorkedExample();
        _nextBlock(1 hours);
    }

    /// @dev Swapping the price up 11 ticks, one more than the guard allows: the removal passes (no swap yet in
    ///      the block), the swap runs, and the add of the new position reverts.
    function test_rebalance_swapImpactBounded() public {
        IOathVault.SwapIntent memory swap = _swapUpTo(START_TICK + 11);
        vm.expectRevert(
            _hookError(
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(IOathHook.PriceMovedThisBlock.selector, START_TICK + 11, START_TICK)
            )
        );
        vm.prank(curator);
        vault.rebalance(RANGE_LOWER, RANGE_UPPER, swap);
    }

    /// @dev Exactly 10 ticks of impact is allowed.
    function test_rebalance_swapImpactAtBound() public {
        IOathVault.SwapIntent memory swap = _swapUpTo(START_TICK + 10);
        vm.prank(curator);
        vault.rebalance(RANGE_LOWER, RANGE_UPPER, swap);
        assertEq(_tick(), START_TICK + 10);
        (,, uint128 liquidity) = vault.positionInfo();
        assertGt(liquidity, 0);
        assertEq(_poolPositionLiquidity(RANGE_LOWER, RANGE_UPPER), liquidity);
    }

    /// @dev Exact-input currency1 swap (more than enough to reach the limit) stopped by the price limit at `tick`.
    function _swapUpTo(int24 tick) internal pure returns (IOathVault.SwapIntent memory) {
        return IOathVault.SwapIntent({
            zeroForOne: false, amountSpecified: -int256(10_000e6), sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tick)
        });
    }
}
