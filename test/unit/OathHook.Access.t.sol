// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IOathHook} from "../../src/interfaces/IOathHook.sol";
import {OathHook} from "../../src/OathHook.sol";
import {OathTestBase, oathPermissions} from "../utils/OathTestBase.sol";

/// @notice Access control of OathHook on the real PoolManager: permissions, vault registration,
///         factory-only pool creation and the vault-only epoch functions.
contract OathHookAccessTest is OathTestBase {
    address internal factory = makeAddr("factory");
    address internal vault = makeAddr("vault");

    OathHook internal hook;
    PoolId internal id;

    function setUp() public override {
        super.setUp();
        hook = OathHook(address(_deployOathHook(factory)));
        key = _oathKey(currency0, currency1);
        id = key.toId();
    }

    // ---------------------------------------------------------------- permissions and construction

    function test_access_permissionsMatchFlags() public view {
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(oathPermissions()));
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS);
    }

    function test_access_constructorStoresManagerAndFactory() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.factory(), factory);
    }

    /// @dev `BaseHook` rejects a deployment whose address does not carry exactly the permission flags.
    function test_access_deployAtUnflaggedAddressReverts() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        assertTrue(uint160(predicted) & Hooks.ALL_HOOK_MASK != HOOK_FLAGS, "predicted address is unflagged");
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new OathHook(manager, factory);
    }

    // ---------------------------------------------------------------- registerVault

    function test_access_registerVault_storesConfigAndEmits() public {
        vm.expectEmit(true, false, false, true, address(hook));
        emit IOathHook.VaultRegistered(id, vault);
        vm.prank(factory);
        hook.registerVault(key, vault, 50);

        (address v, int24 maxTicks, int24 lower, int24 upper) = hook.configs(id);
        assertEq(v, vault);
        assertEq(maxTicks, 50);
        assertEq(lower, 0);
        assertEq(upper, 0);
    }

    function testFuzz_access_registerVault_onlyFactory(address caller) public {
        vm.assume(caller != factory);
        vm.prank(caller);
        vm.expectRevert(IOathHook.OnlyFactory.selector);
        hook.registerVault(key, vault, 50);
    }

    function test_access_registerVault_wrongHook() public {
        PoolKey memory other = key;
        other.hooks = IHooks(address(0));
        vm.prank(factory);
        vm.expectRevert(IOathHook.WrongHook.selector);
        hook.registerVault(other, vault, 50);
    }

    function test_access_registerVault_zeroVault() public {
        vm.prank(factory);
        vm.expectRevert(IOathHook.ZeroVault.selector);
        hook.registerVault(key, address(0), 50);
    }

    function test_access_registerVault_once() public {
        vm.startPrank(factory);
        hook.registerVault(key, vault, 50);
        vm.expectRevert(IOathHook.AlreadyRegistered.selector);
        hook.registerVault(key, alice, 10);
        vm.stopPrank();

        (address v, int24 maxTicks,,) = hook.configs(id);
        assertEq(v, vault, "first registration kept");
        assertEq(maxTicks, 50);
    }

    /// @dev Registration is per pool id: a pool with another fee gets its own vault.
    function test_access_registerVault_perPool() public {
        PoolKey memory other = key;
        other.fee = 3000;
        vm.startPrank(factory);
        hook.registerVault(key, vault, 50);
        hook.registerVault(other, alice, 20);
        vm.stopPrank();

        (address v,,,) = hook.configs(id);
        (address w, int24 maxTicks,,) = hook.configs(other.toId());
        assertEq(v, vault);
        assertEq(w, alice);
        assertEq(maxTicks, 20);
    }
}
