// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IOathHook} from "../../src/interfaces/IOathHook.sol";
import {OathFactory} from "../../src/OathFactory.sol";
import {OathVault} from "../../src/OathVault.sol";
import {OathTestBase} from "./OathTestBase.sol";

/// @title OathVaultTestBase
/// @notice Shared setup for OathVault tests: the real hook and factory, and a vault created through the factory
///         (which also creates its pool on the real PoolManager), plus funding and deposit helpers.
abstract contract OathVaultTestBase is OathTestBase {
    /// @dev The demo pool's start tick (MATH.md §9.1).
    int24 internal constant START_TICK = -199196;

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
        vault = OathVault(
            payable(factory.createVault(
                    currency0_,
                    currency1,
                    POOL_FEE,
                    TICK_SPACING,
                    TickMath.getSqrtPriceAtTick(START_TICK),
                    curator,
                    _defaultParams()
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

    function _balance0(address who) internal view returns (uint256) {
        return c0.balanceOf(who);
    }

    function _balance1(address who) internal view returns (uint256) {
        return c1.balanceOf(who);
    }
}
