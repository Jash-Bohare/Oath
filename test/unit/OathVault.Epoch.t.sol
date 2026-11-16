// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {OathVault} from "../../src/OathVault.sol";
import {OathHookTestBase} from "../utils/OathHookTestBase.sol";

/// @notice OathVault construction and its open window, on the real PoolManager. This test contract plays the
///         factory: it deploys the vault (becoming `factory()`), registers it and creates the pool.
contract OathVaultEpochTest is OathHookTestBase {
    OathVault internal oathVault;

    function setUp() public override {
        factory = address(this);
        super.setUp();
        oathVault = new OathVault(manager, hook, key, curator, _defaultParams());
        vault = address(oathVault);
    }

    // ---------------------------------------------------------------- construction

    function test_vault_constructorSetsViews() public view {
        assertEq(address(oathVault.manager()), address(manager), "manager");
        assertEq(address(oathVault.hook()), address(hook), "hook");
        assertEq(oathVault.factory(), address(this), "factory = deployer");
        assertEq(oathVault.curator(), curator, "curator");
        assertEq(abi.encode(oathVault.poolKey()), abi.encode(key), "poolKey");
        assertEq(PoolId.unwrap(oathVault.poolId()), PoolId.unwrap(id), "poolId");
        assertEq(abi.encode(oathVault.params()), abi.encode(_defaultParams()), "params");
        assertEq(oathVault.openSince(), 0, "no open window yet");
        assertEq(oathVault.cumAtOpen(), 0);
    }

    function test_vault_shareToken() public view {
        assertEq(oathVault.name(), "Oath TEST/TEST");
        assertEq(oathVault.symbol(), "oath-TEST-TEST");
        assertEq(oathVault.decimals(), 18);
        assertEq(oathVault.totalSupply(), 0);
    }

    /// @dev Native currency0 is named ETH.
    function test_vault_shareTokenNativeEth() public {
        PoolKey memory ethKey = _oathKey(CurrencyLibrary.ADDRESS_ZERO, currency1);
        OathVault ethVault = new OathVault(manager, hook, ethKey, curator, _demoParams());
        assertEq(ethVault.name(), "Oath ETH/TEST");
        assertEq(ethVault.symbol(), "oath-ETH-TEST");
        assertEq(Currency.unwrap(ethVault.poolKey().currency0), address(0));
        assertEq(ethVault.params().epochDuration, 1 days);
    }

    // ---------------------------------------------------------------- initOpenWindow

    /// @dev `T0 = now` and `cumAtOpen` is the hook's cumulative at `T0` (here after the start tick held 600 s).
    function test_vault_initOpenWindowRecordsT0AndCumulative() public {
        _createPool(START_TICK);
        _wait(600);
        int256 expected = int256(START_TICK) * 600;
        assertEq(hook.cumulativeNow(key), expected);

        vm.expectEmit(false, false, false, true, address(oathVault));
        emit IOathVault.OpenWindowRefreshed(uint32(_time()), expected);
        oathVault.initOpenWindow();
        assertEq(oathVault.openSince(), _time(), "T0");
        assertEq(oathVault.cumAtOpen(), expected, "cumAtOpen");
    }

    function testFuzz_vault_initOpenWindowOnlyFactory(address caller) public {
        vm.assume(caller != address(this));
        _createPool(START_TICK);
        vm.prank(caller);
        vm.expectRevert(IOathVault.OnlyFactory.selector);
        oathVault.initOpenWindow();
    }

    function test_vault_initOpenWindowOnce() public {
        _createPool(START_TICK);
        oathVault.initOpenWindow();
        _wait(1 hours);
        vm.expectRevert(IOathVault.AlreadyInitialized.selector);
        oathVault.initOpenWindow();
    }
}
