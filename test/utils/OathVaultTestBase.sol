// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IOathHook} from "../../src/interfaces/IOathHook.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {BenchmarkLib} from "../../src/libraries/BenchmarkLib.sol";
import {ValuationLib} from "../../src/libraries/ValuationLib.sol";
import {OathFactory} from "../../src/OathFactory.sol";
import {OathVault} from "../../src/OathVault.sol";
import {OathTestBase} from "./OathTestBase.sol";

/// @title OathVaultTestBase
/// @notice Shared setup for OathVault tests: the real hook and factory, and a vault created through the factory
///         (which also creates its pool on the real PoolManager), plus funding and deposit helpers.
abstract contract OathVaultTestBase is OathTestBase {
    using StateLibrary for IPoolManager;

    /// @dev The demo pool's start tick (MATH.md §9.1).
    int24 internal constant START_TICK = -199196;
    /// @dev MATH.md §9.1 worked example: start value $30,000, bond $3,000 (10%), curator range [−199400, −199000).
    uint256 internal constant NAV_START = 30_000e6;
    uint256 internal constant BOND = 3_000e6;
    int24 internal constant RANGE_LOWER = -199400;
    int24 internal constant RANGE_UPPER = -199000;
    /// @dev The real mainnet ETH/USDC pool's active liquidity at the start of the worked example (MATH.md §9.1).
    uint256 internal constant POOL_LIQUIDITY = 153_902_357_621_796_655;

    IOathHook internal hook;
    OathFactory internal factory;
    OathVault internal vault;
    Currency internal c0;
    Currency internal c1;

    function setUp() public virtual override {
        super.setUp();
        (hook, factory) = _deployOathStack();
    }

    /// @dev Creates the vault for `currency0_`/`currency1` with the default parameters through the factory.
    function _createVault(Currency currency0_) internal {
        _createVault(currency0_, _defaultParams());
    }

    /// @dev Creates the vault for `currency0_`/`currency1` with `params` through the factory.
    function _createVault(Currency currency0_, IOathVault.VaultParams memory params) internal {
        vault = OathVault(
            payable(factory.createVault(
                    currency0_,
                    currency1,
                    POOL_FEE,
                    TICK_SPACING,
                    TickMath.getSqrtPriceAtTick(START_TICK),
                    curator,
                    params
                ))
        );
        key = vault.poolKey();
        c0 = currency0_;
        c1 = currency1;
    }

    /// @dev Gives `who` `a0` currency0 and `a1` currency1 and approves the vault for both ERC-20s.
    function _give(address who, uint256 a0, uint256 a1) internal {
        _fund(c0, who, a0);
        _fund(c1, who, a1);
        vm.startPrank(who);
        if (!c0.isAddressZero()) MockERC20(Currency.unwrap(c0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev `who` deposits up to `(a0, a1)` for itself, sending `a0` as ETH if currency0 is native.
    function _deposit(address who, uint256 a0, uint256 a1) internal returns (uint256 shares, uint256 u0, uint256 u1) {
        vm.prank(who);
        return vault.deposit{value: c0.isAddressZero() ? a0 : 0}(a0, a1, 0, who);
    }

    /// @dev Sets the vault's currency0 balance directly (as if an epoch had changed its holdings).
    function _setIdle0(uint256 amount) internal {
        if (c0.isAddressZero()) vm.deal(address(vault), amount);
        else deal(Currency.unwrap(c0), address(vault), amount);
    }

    /// @dev Sets the vault's idle currency1 directly, keeping the bond on top.
    function _setIdle1(uint256 amount) internal {
        deal(Currency.unwrap(c1), address(vault), amount + vault.bondBalance());
    }

    /// @dev Adds `liquidity` full-range from this test contract (a non-vault LP).
    function _seedPool(uint256 liquidity) internal {
        (int24 tickMin, int24 tickMax) = _fullRange();
        uint256 value;
        if (c0.isAddressZero()) {
            (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
            value = SqrtPriceMath.getAmount0Delta(sqrtP, TickMath.getSqrtPriceAtTick(tickMax), uint128(liquidity), true);
            vm.deal(address(this), address(this).balance + value);
        }
        modifyLiquidityRouter.modifyLiquidity{value: value}(
            key,
            ModifyLiquidityParams({
                tickLower: tickMin, tickUpper: tickMax, liquidityDelta: int256(liquidity), salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    /// @dev The MATH.md §9.1 start: alice deposits `x` currency0 (the benchmark's 50/50 split of $30,000 at the
    ///      start tick) and the currency1 that brings the vault to exactly `NAV_START` at that tick; the curator
    ///      posts `BOND`. Returns the deposit.
    function _fundWorkedExample() internal returns (uint256 x, uint256 y) {
        (x, y) = _depositWorkedExample();
        _postBond(BOND);
    }

    /// @dev The deposit of `_fundWorkedExample`, without the bond.
    function _depositWorkedExample() internal returns (uint256 x, uint256 y) {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(START_TICK);
        (x,) = BenchmarkLib.split(NAV_START, sqrtP);
        y = NAV_START - ValuationLib.value(x, 0, sqrtP);
        _give(alice, x, y);
        _deposit(alice, x, y);
    }

    /// @dev The worked-example epoch: real pool depth, the §9.1 deposit and bond, a 1-hour open window with no
    ///      swaps (start TWAP = start tick), then the curator starts on [−199400, −199000) without a swap.
    function _startWorkedExample() internal {
        _seedPool(POOL_LIQUIDITY);
        _fundWorkedExample();
        _wait(1 hours);
        _startEpoch(RANGE_LOWER, RANGE_UPPER, _noSwap());
    }

    /// @dev The curator posts `amount` currency1 of bond (funded here).
    function _postBond(uint256 amount) internal {
        _give(curator, 0, amount);
        vm.prank(curator);
        vault.postBond(amount);
    }

    /// @dev No swap in a reposition.
    function _noSwap() internal pure returns (IOathVault.SwapIntent memory) {
        return IOathVault.SwapIntent({zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0});
    }

    /// @dev The curator starts an epoch on `[lower, upper)` with `swap`.
    function _startEpoch(int24 lower, int24 upper, IOathVault.SwapIntent memory swap) internal {
        vm.prank(curator);
        vault.startEpoch(lower, upper, swap);
    }

    /// @dev The vault's position liquidity as the PoolManager records it.
    function _poolPositionLiquidity(int24 lower, int24 upper) internal view returns (uint128 liquidity) {
        (liquidity,,) = manager.getPositionInfo(key.toId(), address(vault), lower, upper, bytes32(0));
    }

    function _balance0(address who) internal view returns (uint256) {
        return c0.balanceOf(who);
    }

    function _balance1(address who) internal view returns (uint256) {
        return c1.balanceOf(who);
    }
}
