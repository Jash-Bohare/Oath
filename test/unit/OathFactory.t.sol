// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IOathFactory} from "../../src/interfaces/IOathFactory.sol";
import {IOathHook} from "../../src/interfaces/IOathHook.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {OathFactory} from "../../src/OathFactory.sol";
import {OathVault} from "../../src/OathVault.sol";
import {OathTestBase} from "../utils/OathTestBase.sol";

/// @notice OathFactory on the real PoolManager with the real hook: atomic creation of pool + vault +
///         registration, the hook check, parameter bounds and one vault per pool key.
contract OathFactoryTest is OathTestBase {
    using StateLibrary for IPoolManager;

    int24 internal constant START_TICK = -199196; // MATH.md §9.1

    IOathHook internal hook;
    OathFactory internal factory;
    uint160 internal startPrice;

    function setUp() public override {
        super.setUp();
        (hook, factory) = _deployOathStack();
        startPrice = TickMath.getSqrtPriceAtTick(START_TICK);
    }

    // ---------------------------------------------------------------- construction

    function test_factory_constructorSetsViews() public view {
        assertEq(address(factory.manager()), address(manager));
        assertEq(address(factory.hook()), address(hook));
        assertEq(hook.factory(), address(factory), "hook deployed for this factory");
    }

    /// @dev A factory refuses a hook deployed for a different factory.
    function test_factory_constructorRejectsHookForOtherFactory() public {
        IOathHook otherHook = _deployOathHook(alice);
        vm.expectRevert(IOathFactory.HookFactoryMismatch.selector);
        new OathFactory(manager, otherHook);
    }

    // ---------------------------------------------------------------- atomic creation

    /// @dev One call deploys the vault, registers it with the hook, creates the pool at the given price with
    ///      the hook, starts the hook's accumulator and opens the vault's first open window.
    function test_factory_createVaultIsAtomic() public {
        vm.warp(1_700_000_000);
        PoolKey memory key_ = _oathKey(currency0, currency1);
        PoolId id = key_.toId();
        address predictedVault = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));

        vm.expectEmit(true, true, true, true, address(factory));
        emit IOathFactory.VaultCreated(id, predictedVault, curator);
        vm.prank(alice); // anyone may create
        address v =
            factory.createVault(currency0, currency1, POOL_FEE, TICK_SPACING, startPrice, curator, _defaultParams());
        assertEq(v, predictedVault, "vault address");

        // Registered with the hook, with the vault's guard threshold.
        (address registered, int24 maxTicks, int24 lower, int24 upper) = hook.configs(id);
        assertEq(registered, v, "registered vault");
        assertEq(maxTicks, _defaultParams().maxIntraBlockTicks, "guard threshold");
        assertEq(lower, 0);
        assertEq(upper, 0);

        // The pool exists at the requested price, and the hook's accumulator started now.
        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(id);
        assertEq(sqrtPriceX96, startPrice, "price");
        assertEq(tick, START_TICK, "tick");
        (uint32 lastTimestamp,,, int256 tickCumulative) = hook.oracles(id);
        assertEq(lastTimestamp, 1_700_000_000, "accumulator started");
        assertEq(tickCumulative, 0);

        // The vault: its pool, parameters, curator, factory and first open window.
        OathVault oathVault = OathVault(v);
        assertEq(abi.encode(oathVault.poolKey()), abi.encode(key_), "vault key");
        assertEq(PoolId.unwrap(oathVault.poolId()), PoolId.unwrap(id), "vault pool id");
        assertEq(abi.encode(oathVault.params()), abi.encode(_defaultParams()), "vault params");
        assertEq(oathVault.curator(), curator, "curator");
        assertEq(oathVault.factory(), address(factory), "vault factory");
        assertEq(address(oathVault.hook()), address(hook));
        assertEq(address(oathVault.manager()), address(manager));
        assertEq(oathVault.openSince(), 1_700_000_000, "T0");
        assertEq(oathVault.cumAtOpen(), 0, "cumulative at T0");
    }

    /// @dev The demo shape: native ETH as currency0.
    function test_factory_createVaultNativeEth() public {
        address v = factory.createVault(
            CurrencyLibrary.ADDRESS_ZERO, currency1, POOL_FEE, TICK_SPACING, startPrice, curator, _demoParams()
        );
        PoolKey memory ethKey = _oathKey(CurrencyLibrary.ADDRESS_ZERO, currency1);
        (address registered,,,) = hook.configs(ethKey.toId());
        assertEq(registered, v);
        assertEq(OathVault(v).name(), "Oath ETH/TEST");
        assertEq(OathVault(v).params().epochDuration, 1 days);
    }

    /// @dev If the PoolManager rejects the pool, nothing is created: no registration, no pool.
    function test_factory_failedPoolCreatesNothing() public {
        PoolKey memory reversed = _oathKey(currency1, currency0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPoolManager.CurrenciesOutOfOrderOrEqual.selector,
                Currency.unwrap(currency1),
                Currency.unwrap(currency0)
            )
        );
        factory.createVault(currency1, currency0, POOL_FEE, TICK_SPACING, startPrice, curator, _defaultParams());

        (address registered,,,) = hook.configs(reversed.toId());
        assertEq(registered, address(0), "nothing registered");
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(reversed.toId());
        assertEq(sqrtPriceX96, 0, "no pool");
    }

    /// @dev The created pool is a normal, open Oath pool: other LPs and swappers use it, and the hook observes.
    function test_factory_createdPoolIsOpenAndObserved() public {
        factory.createVault(currency0, currency1, POOL_FEE, TICK_SPACING, startPrice, curator, _defaultParams());
        PoolKey memory key_ = _oathKey(currency0, currency1);
        (int24 tickMin, int24 tickMax) = _fullRange();
        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({tickLower: tickMin, tickUpper: tickMax, liquidityDelta: 1e24, salt: bytes32(0)}),
            ZERO_BYTES
        );
        vm.warp(vm.getBlockTimestamp() + 100);
        swap(key_, true, -1e15, ZERO_BYTES);
        (,,, int256 tickCumulative) = hook.oracles(key_.toId());
        assertEq(tickCumulative, int256(START_TICK) * 100, "hook advanced on the swap");
    }
}
