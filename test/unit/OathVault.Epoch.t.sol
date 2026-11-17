// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {OathVault} from "../../src/OathVault.sol";
import {OathHookTestBase} from "../utils/OathHookTestBase.sol";
import {OathVaultTestBase} from "../utils/OathVaultTestBase.sol";

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

/// @notice Refreshing an expired open window, on a vault created through the real factory.
contract OathVaultOpenWindowTest is OathVaultTestBase {
    uint32 internal maxOpen;
    uint256 internal createdAt;

    function setUp() public override {
        super.setUp();
        createdAt = vm.getBlockTimestamp();
        _createVault(currency0);
        maxOpen = vault.params().maxOpen;
    }

    /// @dev The factory opened the first window at creation, at the hook's cumulative then (zero).
    function test_window_openedByFactory() public view {
        assertEq(vault.openSince(), createdAt);
        assertEq(vault.cumAtOpen(), 0);
    }

    /// @dev Refreshing needs `now − openSince > maxOpen`: at exactly `maxOpen` it reverts.
    function test_window_refreshNotBeforeExpiry() public {
        vm.warp(createdAt + maxOpen);
        vm.expectRevert(IOathVault.OpenWindowNotExpired.selector);
        vault.refreshOpenWindow();
    }

    /// @dev One second later anyone can restart the window: `T0 = now` and `cumAtOpen` is the hook's cumulative
    ///      at that moment (the start tick held since creation).
    function test_window_refreshByAnyoneAfterExpiry() public {
        uint256 refreshAt = createdAt + maxOpen + 1;
        vm.warp(refreshAt);
        int256 expected = int256(START_TICK) * int256(uint256(maxOpen) + 1);
        assertEq(hook.cumulativeNow(key), expected);

        vm.expectEmit(false, false, false, true, address(vault));
        emit IOathVault.OpenWindowRefreshed(uint32(refreshAt), expected);
        vm.prank(keeper);
        vault.refreshOpenWindow();
        assertEq(vault.openSince(), refreshAt, "T0 = now");
        assertEq(vault.cumAtOpen(), expected, "cumAtOpen = hook cumulative now");
    }

    /// @dev A refreshed window runs a full `maxOpen` again before the next refresh.
    function test_window_refreshRestartsTheClock() public {
        uint256 first = createdAt + maxOpen + 1;
        vm.warp(first);
        vault.refreshOpenWindow();

        vm.warp(first + maxOpen);
        vm.expectRevert(IOathVault.OpenWindowNotExpired.selector);
        vault.refreshOpenWindow();
        vm.warp(first + maxOpen + 1);
        vault.refreshOpenWindow();
        assertEq(vault.openSince(), first + maxOpen + 1);
    }

    /// @dev Refreshing moves no tokens and changes no shares or bond.
    function test_window_refreshTouchesNoFunds() public {
        _give(alice, 1e30, 1e30);
        _give(curator, 0, 1e30);
        _deposit(alice, 1e18, 2e18);
        vm.prank(curator);
        vault.postBond(1_000e6);
        uint256 supply = vault.totalSupply();

        vm.warp(createdAt + maxOpen + 1);
        vault.refreshOpenWindow();
        assertEq(vault.idle0(), 1e18);
        assertEq(vault.idle1(), 2e18);
        assertEq(vault.bondBalance(), 1_000e6);
        assertEq(vault.totalSupply(), supply);
    }
}

/// @notice Starting an epoch and moving the vault's position, on a vault created through the real factory.
contract OathVaultStartEpochTest is OathVaultTestBase {
    function setUp() public override {
        super.setUp();
        _createVault(currency0);
    }

    // ---------------------------------------------------------------- reposition

    /// @dev The vault starts with no position.
    function test_reposition_noPositionAtCreation() public view {
        (int24 lower, int24 upper, uint128 liquidity) = vault.positionInfo();
        assertEq(lower, 0);
        assertEq(upper, 0);
        assertEq(liquidity, 0);
        assertEq(vault.POSITION_SALT(), bytes32(0));
    }

    /// @dev Only the PoolManager may call back into the vault.
    function testFuzz_reposition_callbackOnlyManager(address caller) public {
        vm.assume(caller != address(manager));
        vm.prank(caller);
        vm.expectRevert(IOathVault.OnlyManager.selector);
        vault.unlockCallback("");
    }
}
