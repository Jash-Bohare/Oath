// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IOathHook} from "../../src/interfaces/IOathHook.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {BenchmarkLib} from "../../src/libraries/BenchmarkLib.sol";
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
    using StateLibrary for IPoolManager;

    uint256 internal createdAt;

    function setUp() public override {
        super.setUp();
        createdAt = vm.getBlockTimestamp();
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

    // ---------------------------------------------------------------- startEpoch

    /// @dev The MATH.md §9.1 start, reproduced on-chain: $30,000 marked at the start tick (no swaps, so the
    ///      open-window TWAP is the start tick), the benchmark's L_b = 317,220,452,305,763 passes the cap against
    ///      the real pool's active liquidity, the bond is exactly 10%, and the curator's range [−199400, −199000)
    ///      gets L_v ≈ 3.126048e16 with 0.261795 ETH left idle (reference model `oath_math.py`). Every piece of
    ///      epoch state is set and the hook schedules the end-of-epoch checkpoints.
    function test_start_workedExample() public {
        _seedPool(POOL_LIQUIDITY);
        _fundWorkedExample();
        vm.warp(createdAt + 1 hours);
        uint32 start = uint32(_time());
        uint32 end = start + 7 days;
        (uint128 benchL, uint256 r0, uint256 r1) =
            BenchmarkLib.create(NAV_START, TickMath.getSqrtPriceAtTick(START_TICK), TICK_SPACING);
        assertApproxEqAbs(benchL, 317_220_452_305_763, 1, "L_b (MATH.md 9.1)");

        vm.expectEmit(true, false, false, true, address(vault));
        emit IOathVault.EpochStarted(0, start, end, START_TICK, NAV_START, benchL, RANGE_LOWER, RANGE_UPPER);
        _startEpoch(RANGE_LOWER, RANGE_UPPER, _noSwap());

        // Benchmark: created at the start TWAP, with the fee growth at S (no swaps yet, so zero).
        (uint128 l, uint256 br0, uint256 br1, uint256 g0, uint256 g1, uint256 navStart, int24 startTick) =
            vault.benchmark();
        assertEq(l, benchL, "L_b");
        assertEq(br0, r0, "r0");
        assertEq(br1, r1, "r1");
        assertEq(g0, 0, "G0 at S");
        assertEq(g1, 0, "G1 at S");
        assertEq(navStart, NAV_START, "navStart");
        assertEq(startTick, START_TICK, "startTick");

        // Lifecycle.
        assertEq(uint8(vault.state()), uint8(IOathVault.State.ACTIVE), "ACTIVE");
        assertEq(vault.epochStart(), start, "S");
        assertEq(vault.epochEnd(), end, "E");
        assertEq(vault.lastReposition(), start, "lastReposition");
        assertEq(vault.epochCount(), 0, "no settled epoch yet");

        // Position: in the pool under the vault's salt, recorded by the hook for the boundary snapshot.
        (int24 lower, int24 upper, uint128 liquidity) = vault.positionInfo();
        assertEq(lower, RANGE_LOWER);
        assertEq(upper, RANGE_UPPER);
        assertApproxEqRel(liquidity, 3.126048e16, 1e12, "L_v (reference 3.126048e16)");
        assertEq(_poolPositionLiquidity(RANGE_LOWER, RANGE_UPPER), liquidity, "pool position = L_v");
        (,, int24 vaultLower, int24 vaultUpper) = hook.configs(key.toId());
        assertEq(vaultLower, RANGE_LOWER, "hook range lower");
        assertEq(vaultUpper, RANGE_UPPER, "hook range upper");

        // Idle after adding: 0.261795 ETH; currency1 is the binding side, so only the 1-wei buffer and at most one
        // more raw unit of round-up remain (1 <= idle1 <= 2).
        assertApproxEqAbs(vault.idle0(), 0.261795e18, 0.000001e18, "idle0 (reference 0.261795 ETH)");
        assertGe(vault.idle1(), 1, "idle1 keeps the 1-wei buffer");
        assertLe(vault.idle1(), 2, "idle1 <= 2");
        assertEq(vault.bondBalance(), BOND, "bond untouched");
        assertEq(c1.balanceOf(address(vault)) - vault.idle1(), BOND, "bond still held");

        // Hook: epoch open, checkpoints at E − W and E.
        IOathHook.Epoch memory e = hook.epochData(key);
        assertTrue(e.active, "hook epoch active");
        assertEq(e.checkpointA, end - 30 minutes, "checkpoint A = E - W");
        assertEq(e.checkpointB, end, "checkpoint B = E");
    }
}
