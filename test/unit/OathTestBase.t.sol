// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {OathTestBase, oathPermissions} from "../utils/OathTestBase.sol";

/// @notice Test-only hook with exactly OathHook's permissions. BaseHook's constructor validates the
///         deployment address against `getHookPermissions()`, so deploying it at `HOOK_ADDRESS` proves the
///         flagged address is right; each callback counts its calls.
contract PermissionsProbeHook is BaseHook {
    mapping(bytes4 => uint256) public calls;

    constructor(IPoolManager manager) BaseHook(manager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return oathPermissions();
    }

    function _beforeInitialize(address, PoolKey calldata, uint160) internal override returns (bytes4) {
        return _count(this.beforeInitialize.selector);
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        return _count(this.beforeAddLiquidity.selector);
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        return _count(this.beforeRemoveLiquidity.selector);
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (_count(this.beforeSwap.selector), BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        return _count(this.beforeDonate.selector);
    }

    function _count(bytes4 selector) private returns (bytes4) {
        calls[selector]++;
        return selector;
    }
}

contract OathTestBaseTest is OathTestBase {
    /// @dev External wrapper so `validateHookPermissions` reverts can be caught with `expectRevert`.
    function validateAt(address hookAddress) external pure {
        Hooks.validateHookPermissions(IHooks(hookAddress), oathPermissions());
    }

    function test_base_hookFlagsMatchSpec() public pure {
        assertEq(HOOK_FLAGS, 0x2AA0, "flags");
        assertEq(HOOK_FLAGS, 10912, "flags decimal");
        assertEq(uint160(HOOK_ADDRESS) & Hooks.ALL_HOOK_MASK, 0x2AA0, "address low 14 bits");
    }

    function test_base_permissionsAreExactlyTheFiveBeforeHooks() public pure {
        Hooks.Permissions memory p = oathPermissions();
        assertTrue(p.beforeInitialize && p.beforeAddLiquidity && p.beforeRemoveLiquidity);
        assertTrue(p.beforeSwap && p.beforeDonate);
        assertFalse(p.afterInitialize || p.afterAddLiquidity || p.afterRemoveLiquidity);
        assertFalse(p.afterSwap || p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta || p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
    }

    function test_base_flaggedAddressValid() public view {
        this.validateAt(HOOK_ADDRESS);
        assertTrue(Hooks.isValidHookAddress(IHooks(HOOK_ADDRESS), POOL_FEE));
    }

    function test_base_anyFlagFlipRejected() public {
        for (uint160 bit = 0; bit < 14; bit++) {
            address wrong = address(uint160(HOOK_ADDRESS) ^ (uint160(1) << bit));
            vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, wrong));
            this.validateAt(wrong);
        }
    }

    function test_base_currenciesSortedAndFunded() public view {
        assertTrue(currency0 < currency1, "sorted");
        assertFalse(currency0.isAddressZero(), "erc20 currency0");
        assertGt(currency0.balanceOf(address(this)), 0);
        assertGt(currency1.balanceOf(address(this)), 0);
    }

    function test_base_fullRangeForSpacing10() public pure {
        (int24 tickMin, int24 tickMax) = _fullRange();
        assertEq(tickMin, -887270);
        assertEq(tickMax, 887270);
    }

    function test_base_oathKeyShape() public view {
        PoolKey memory k = _oathKey(currency0, currency1);
        assertEq(Currency.unwrap(k.currency0), Currency.unwrap(currency0));
        assertEq(Currency.unwrap(k.currency1), Currency.unwrap(currency1));
        assertEq(k.fee, 500);
        assertEq(k.tickSpacing, 10);
        assertEq(address(k.hooks), HOOK_ADDRESS);
    }

    function test_base_defaultParamsMatchArchitecture() public pure {
        IOathVault.VaultParams memory p = _defaultParams();
        assertEq(p.epochDuration, 7 days);
        assertEq(p.twapWindow, 30 minutes);
        assertEq(p.maxOpen, 6 hours);
        assertEq(p.rebalanceCooldown, 1 hours);
        assertEq(p.maxIntraBlockTicks, 50);
        assertEq(p.bandBps, 35);
        assertEq(p.perfFeeBps, 2_000);
        assertEq(p.minBondBps, 1_000);
        assertEq(p.capBps, 25);
    }

    function test_base_demoParamsDifferOnlyInEpochDuration() public pure {
        IOathVault.VaultParams memory d = _demoParams();
        IOathVault.VaultParams memory p = _defaultParams();
        assertEq(d.epochDuration, 1 days);
        p.epochDuration = d.epochDuration;
        assertEq(abi.encode(d), abi.encode(p));
    }

    /// @dev The factory bounds from MATH.md §12 hold for both parameter sets.
    function test_base_paramsWithinFactoryBounds() public pure {
        _assertWithinBounds(_defaultParams());
        _assertWithinBounds(_demoParams());
    }

    function test_base_fundErc20AndNative() public {
        _fund(currency1, alice, 123);
        assertEq(currency1.balanceOf(alice), 123);
        _fund(CurrencyLibrary.ADDRESS_ZERO, alice, 1 ether);
        assertEq(alice.balance, 1 ether);
    }

    /// @dev End to end on the real PoolManager: a hook at `HOOK_ADDRESS` with OathHook's permissions is
    ///      accepted, and initialize, add, swap, donate and remove each reach exactly their callback.
    function test_base_flaggedHookRunsEveryCallbackOnRealPool() public {
        PermissionsProbeHook probe =
            PermissionsProbeHook(_deployHookAt("OathTestBase.t.sol:PermissionsProbeHook", abi.encode(manager)));
        PoolKey memory k = _oathKey(currency0, currency1);

        manager.initialize(k, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(k, LIQUIDITY_PARAMS, ZERO_BYTES);
        swap(k, true, -100, ZERO_BYTES);
        donateRouter.donate(k, 100, 100, ZERO_BYTES);
        modifyLiquidityRouter.modifyLiquidity(k, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);

        assertEq(probe.calls(IHooks.beforeInitialize.selector), 1, "initialize");
        assertEq(probe.calls(IHooks.beforeAddLiquidity.selector), 1, "add");
        assertEq(probe.calls(IHooks.beforeSwap.selector), 1, "swap");
        assertEq(probe.calls(IHooks.beforeDonate.selector), 1, "donate");
        assertEq(probe.calls(IHooks.beforeRemoveLiquidity.selector), 1, "remove");
    }

    /// @dev Same for a native-ETH pool (currency0 = address(0)), as used by the demo's ETH/USDC pool.
    function test_base_flaggedHookWorksWithNativeEth() public {
        PermissionsProbeHook probe =
            PermissionsProbeHook(_deployHookAt("OathTestBase.t.sol:PermissionsProbeHook", abi.encode(manager)));
        PoolKey memory k = _oathKey(CurrencyLibrary.ADDRESS_ZERO, currency1);
        _fund(CurrencyLibrary.ADDRESS_ZERO, address(this), 10 ether);

        manager.initialize(k, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: 1 ether}(k, LIQUIDITY_PARAMS, ZERO_BYTES);
        swapNativeInput(k, true, -100, ZERO_BYTES, 100);

        assertEq(probe.calls(IHooks.beforeAddLiquidity.selector), 1, "add");
        assertEq(probe.calls(IHooks.beforeSwap.selector), 1, "swap");
    }

    function _assertWithinBounds(IOathVault.VaultParams memory p) private pure {
        assertGe(p.epochDuration, 2 * uint256(p.twapWindow), "epochDuration >= 2W");
        assertGe(p.twapWindow, 5 minutes, "W >= 5 min");
        assertLe(p.twapWindow, 2 hours, "W <= 2 h");
        assertGt(p.maxOpen, p.twapWindow, "maxOpen > W");
        assertLe(p.rebalanceCooldown, p.epochDuration, "cooldown <= epochDuration");
        assertGe(p.maxIntraBlockTicks, 1, "maxIntraBlockTicks >= 1");
        assertLe(p.maxIntraBlockTicks, 1_000, "maxIntraBlockTicks <= 1000");
        assertLe(p.bandBps, 500, "band <= 500");
        assertLe(p.perfFeeBps, 5_000, "perfFee <= 5000");
        assertGe(p.minBondBps, 100, "minBond >= 100");
        assertGe(p.capBps, 1, "cap >= 1");
        assertLe(p.capBps, 1_000, "cap <= 1000");
    }
}
