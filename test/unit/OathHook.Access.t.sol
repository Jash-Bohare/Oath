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

    // ---------------------------------------------------------------- beforeInitialize (factory only)

    function test_access_initialize_byFactoryStartsOracle() public {
        _register();
        vm.warp(1_700_000_000);
        vm.prank(factory);
        manager.initialize(key, SQRT_PRICE_1_1);

        (uint32 lastTimestamp, uint64 lastSwapBlock, int24 blockStartTick, int256 tickCumulative) = hook.oracles(id);
        assertEq(lastTimestamp, 1_700_000_000);
        assertEq(lastSwapBlock, 0);
        assertEq(blockStartTick, 0);
        assertEq(tickCumulative, 0);
    }

    /// @dev Threat T14: nobody but the factory can create a pool with the Oath hook, even with a registered
    ///      vault. The hook itself is excluded: v4 never calls a hook for its own actions, and OathHook has no
    ///      code path that calls `initialize`.
    function testFuzz_access_initialize_onlyFactory(address caller) public {
        vm.assume(caller != factory && caller != address(hook));
        _register();
        vm.prank(caller);
        vm.expectRevert(
            _hookError(IHooks.beforeInitialize.selector, abi.encodeWithSelector(IOathHook.OnlyFactory.selector))
        );
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_access_initialize_requiresRegisteredVault() public {
        vm.prank(factory);
        vm.expectRevert(
            _hookError(IHooks.beforeInitialize.selector, abi.encodeWithSelector(IOathHook.VaultNotRegistered.selector))
        );
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    /// @dev Registering one pool does not let the factory create another pool with no vault.
    function test_access_initialize_otherPoolStillNeedsVault() public {
        _register();
        PoolKey memory other = key;
        other.fee = 3000;
        vm.prank(factory);
        vm.expectRevert(
            _hookError(IHooks.beforeInitialize.selector, abi.encodeWithSelector(IOathHook.VaultNotRegistered.selector))
        );
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    // ---------------------------------------------------------------- openEpoch / closeEpoch (vault only)

    function test_access_openEpoch_schedulesCheckpoints() public {
        _registerAndInitialize();
        uint32 epochEnd = uint32(block.timestamp + 7 days);

        vm.expectEmit(true, false, false, true, address(hook));
        emit IOathHook.EpochOpened(id, epochEnd - 30 minutes, epochEnd);
        vm.prank(vault);
        hook.openEpoch(key, epochEnd, 30 minutes);

        IOathHook.Epoch memory e = hook.epochData(key);
        assertEq(e.checkpointA, epochEnd - 30 minutes, "checkpointA = E - W");
        assertEq(e.checkpointB, epochEnd, "checkpointB = E");
        assertTrue(e.active, "active");
        assertFalse(e.doneA || e.doneB || e.snapTaken, "nothing recorded yet");
        assertEq(e.cumA, 0);
        assertEq(e.cumB, 0);
        assertEq(e.G0 | e.G1 | e.fgIn0 | e.fgIn1, 0, "no snapshot yet");
    }

    function testFuzz_access_openEpoch_onlyVault(address caller) public {
        vm.assume(caller != vault);
        _registerAndInitialize();
        vm.prank(caller);
        vm.expectRevert(IOathHook.OnlyVault.selector);
        hook.openEpoch(key, uint32(block.timestamp + 7 days), 30 minutes);
    }

    /// @dev A vault is only the vault of its own pool.
    function test_access_openEpoch_otherPoolReverts() public {
        _registerAndInitialize();
        PoolKey memory other = key;
        other.fee = 3000;
        vm.prank(vault);
        vm.expectRevert(IOathHook.OnlyVault.selector);
        hook.openEpoch(other, uint32(block.timestamp + 7 days), 30 minutes);
    }

    function test_access_openEpoch_notTwice() public {
        _registerAndInitialize();
        vm.startPrank(vault);
        hook.openEpoch(key, uint32(block.timestamp + 7 days), 30 minutes);
        vm.expectRevert(IOathHook.EpochAlreadyActive.selector);
        hook.openEpoch(key, uint32(block.timestamp + 8 days), 30 minutes);
        vm.stopPrank();
    }

    /// @dev `E − W` must be strictly after now: `E − W = now` reverts, `E − W = now + 1` opens.
    function test_access_openEpoch_badWindowEdges() public {
        _registerAndInitialize();
        uint32 w = 30 minutes;
        uint32 edge = uint32(block.timestamp) + w;
        vm.startPrank(vault);
        vm.expectRevert(IOathHook.BadWindow.selector);
        hook.openEpoch(key, edge, w);
        hook.openEpoch(key, edge + 1, w);
        vm.stopPrank();
        assertEq(hook.epochData(key).checkpointA, block.timestamp + 1);
    }

    /// @dev `epochEnd < twapWindow` reverts `BadWindow` rather than underflowing.
    function test_access_openEpoch_windowLongerThanEndReverts() public {
        _registerAndInitialize();
        vm.prank(vault);
        vm.expectRevert(IOathHook.BadWindow.selector);
        hook.openEpoch(key, 10, 20);
    }

    function testFuzz_access_openEpoch_windowRule(uint32 epochEnd, uint32 twapWindow) public {
        _registerAndInitialize();
        vm.prank(vault);
        if (uint256(epochEnd) <= block.timestamp + twapWindow) {
            vm.expectRevert(IOathHook.BadWindow.selector);
            hook.openEpoch(key, epochEnd, twapWindow);
        } else {
            hook.openEpoch(key, epochEnd, twapWindow);
            assertGt(hook.epochData(key).checkpointA, block.timestamp);
        }
    }

    function testFuzz_access_closeEpoch_onlyVault(address caller) public {
        vm.assume(caller != vault);
        _registerAndInitialize();
        vm.prank(vault);
        hook.openEpoch(key, uint32(block.timestamp + 7 days), 30 minutes);
        vm.prank(caller);
        vm.expectRevert(IOathHook.OnlyVault.selector);
        hook.closeEpoch(key);
    }

    /// @dev Nothing is recorded yet, so the epoch cannot be closed, even after `E`.
    function test_access_closeEpoch_notReady() public {
        _registerAndInitialize();
        vm.startPrank(vault);
        vm.expectRevert(IOathHook.EpochNotReady.selector);
        hook.closeEpoch(key);

        hook.openEpoch(key, uint32(block.timestamp + 7 days), 30 minutes);
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(IOathHook.EpochNotReady.selector);
        hook.closeEpoch(key);
        vm.stopPrank();
        assertTrue(hook.epochData(key).active, "still active");
    }

    function test_access_epochData_emptyBeforeFirstEpoch() public {
        _registerAndInitialize();
        IOathHook.Epoch memory e = hook.epochData(key);
        assertEq(abi.encode(e), abi.encode(IOathHook.Epoch(0, 0, false, false, false, false, 0, 0, 0, 0, 0, 0)));
    }

    // ---------------------------------------------------------------- helpers

    function _register() internal {
        vm.prank(factory);
        hook.registerVault(key, vault, 50);
    }

    /// @dev Registers the vault and creates the pool through the factory, at price 1.
    function _registerAndInitialize() internal {
        _register();
        vm.prank(factory);
        manager.initialize(key, SQRT_PRICE_1_1);
    }
}
