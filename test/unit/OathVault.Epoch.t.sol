// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IOathHook} from "../../src/interfaces/IOathHook.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {BenchmarkLib} from "../../src/libraries/BenchmarkLib.sol";
import {ValuationLib} from "../../src/libraries/ValuationLib.sol";
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

    // ---------------------------------------------------------------- access and range

    function testFuzz_start_onlyCurator(address caller) public {
        vm.assume(caller != curator);
        _seedPool(POOL_LIQUIDITY);
        _fundWorkedExample();
        _wait(1 hours);
        vm.prank(caller);
        vm.expectRevert(IOathVault.NotCurator.selector);
        vault.startEpoch(RANGE_LOWER, RANGE_UPPER, _noSwap());
    }

    /// @dev An epoch cannot start while one is running.
    function test_start_notTwice() public {
        _startWorkedExample();
        _wait(1 hours);
        vm.expectRevert(IOathVault.NotOpen.selector);
        _startEpoch(RANGE_LOWER, RANGE_UPPER, _noSwap());
    }

    /// @dev `tickLower < tickUpper`, both on the tick spacing, both within the usable ticks.
    function test_start_badRange() public {
        _seedPool(POOL_LIQUIDITY);
        _fundWorkedExample();
        _wait(1 hours);
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
            _startEpoch(bad[i][0], bad[i][1], _noSwap());
        }
    }

    /// @dev The widest legal range is the full usable range.
    function test_start_fullRangeAllowed() public {
        _seedPool(POOL_LIQUIDITY);
        _fundWorkedExample();
        _wait(1 hours);
        (int24 tickMin, int24 tickMax) = _fullRange();
        _startEpoch(tickMin, tickMax, _noSwap());
        (int24 lower, int24 upper, uint128 liquidity) = vault.positionInfo();
        assertEq(lower, tickMin);
        assertEq(upper, tickMax);
        assertEq(_poolPositionLiquidity(tickMin, tickMax), liquidity);
    }

    // ---------------------------------------------------------------- open window

    /// @dev `W ≤ now − T0`: one second short of `W` reverts.
    function test_start_openWindowTooShort() public {
        _seedPool(POOL_LIQUIDITY);
        _fundWorkedExample();
        vm.warp(createdAt + 30 minutes - 1);
        vm.expectRevert(IOathVault.OpenWindowTooShort.selector);
        _startEpoch(RANGE_LOWER, RANGE_UPPER, _noSwap());
    }

    /// @dev Exactly `W` is enough.
    function test_start_atMinimumWindow() public {
        _seedPool(POOL_LIQUIDITY);
        _fundWorkedExample();
        vm.warp(createdAt + 30 minutes);
        _startEpoch(RANGE_LOWER, RANGE_UPPER, _noSwap());
        assertEq(uint8(vault.state()), uint8(IOathVault.State.ACTIVE));
    }

    /// @dev Exactly `maxOpen` is still allowed.
    function test_start_atMaximumWindow() public {
        _seedPool(POOL_LIQUIDITY);
        _fundWorkedExample();
        vm.warp(createdAt + 6 hours);
        _startEpoch(RANGE_LOWER, RANGE_UPPER, _noSwap());
        assertEq(uint8(vault.state()), uint8(IOathVault.State.ACTIVE));
    }

    /// @dev `now − T0 ≤ maxOpen`: one second over reverts.
    function test_start_openWindowExpired() public {
        _seedPool(POOL_LIQUIDITY);
        _fundWorkedExample();
        vm.warp(createdAt + 6 hours + 1);
        vm.expectRevert(IOathVault.OpenWindowExpired.selector);
        _startEpoch(RANGE_LOWER, RANGE_UPPER, _noSwap());
    }

    /// @dev After a refresh the window restarts: `W` must pass again, and the start TWAP covers only the new
    ///      window (the price moved during the expired one).
    function test_start_afterRefreshUsesNewWindow() public {
        _seedPool(POOL_LIQUIDITY);
        _fundWorkedExample();
        _nextBlock(1 hours);
        _moveToTick(START_TICK - 300); // held for the rest of the expired window only
        _nextBlock(0);
        _moveToTick(START_TICK);
        vm.warp(createdAt + 6 hours + 1);
        vault.refreshOpenWindow();
        uint256 refreshedAt = _time();

        vm.warp(refreshedAt + 30 minutes - 1);
        vm.expectRevert(IOathVault.OpenWindowTooShort.selector);
        _startEpoch(RANGE_LOWER, RANGE_UPPER, _noSwap());

        _nextBlock(1);
        _startEpoch(RANGE_LOWER, RANGE_UPPER, _noSwap());
        (,,,,,, int24 startTick) = vault.benchmark();
        assertEq(startTick, START_TICK, "TWAP over the new window only");
    }

    // ---------------------------------------------------------------- start price

    /// @dev The start price is the TWAP over the whole open window (MATH.md §5), equal to a brute-force sum of
    ///      tick × seconds held, floor-divided by the window. Moving the spot price just before `startEpoch` (here
    ///      1,150 ticks, one block earlier) barely moves it. The cumulative is negative with a remainder, so
    ///      flooring differs from truncation. The benchmark is created at that price with the fee growth at `S`.
    function test_start_usesOpenWindowTwap() public {
        _seedPool(POOL_LIQUIDITY);
        (uint256 x, uint256 y) = _depositWorkedExample();
        _postBond(2 * BOND); // the start NAV moves with the TWAP; keep the bond check out of the way

        int256 cumulative = int256(START_TICK) * 600;
        _nextBlock(600);
        _moveToTick(START_TICK - 104);
        int24 t1 = _tick();
        _nextBlock(900);
        _moveToTick(START_TICK + 46);
        int24 t2 = _tick();
        _nextBlock(1500);
        _moveToTick(START_TICK + 1196); // spot moved far just before the start
        int24 t3 = _tick();
        _nextBlock(7);
        cumulative += int256(t1) * 900 + int256(t2) * 1500 + int256(t3) * 7;
        uint32 elapsed = 600 + 900 + 1500 + 7;
        assertEq(_time(), createdAt + elapsed);
        assertEq(hook.cumulativeNow(key) - vault.cumAtOpen(), cumulative, "hook cumulative = brute force");

        int256 floorTick = cumulative / int256(uint256(elapsed));
        assertTrue(cumulative < 0 && cumulative % int256(uint256(elapsed)) != 0, "floor differs from truncation");
        floorTick -= 1;
        (uint256 g0, uint256 g1) = manager.getFeeGrowthGlobals(key.toId());
        assertGt(g0, 0, "swaps paid fees");

        _startEpoch(-198100, -197900, _noSwap()); // around the spot tick -198000
        (uint128 benchL,,, uint256 bg0, uint256 bg1, uint256 navStart, int24 startTick) = vault.benchmark();
        assertEq(startTick, int24(floorTick), "start tick = floor of the brute-force TWAP");
        assertTrue(startTick != t3, "not the spot tick");
        uint160 sqrtStart = TickMath.getSqrtPriceAtTick(startTick);
        assertEq(navStart, ValuationLib.value(x, y, sqrtStart), "navStart = idle deposit marked at the TWAP");
        (uint128 expectedL,,) = BenchmarkLib.create(navStart, sqrtStart, TICK_SPACING);
        assertEq(benchL, expectedL, "benchmark created at the TWAP");
        assertEq(bg0, g0, "G0 at S");
        assertEq(bg1, g1, "G1 at S");
    }

    // ---------------------------------------------------------------- start value, cap and bond

    /// @dev A vault with nothing to manage cannot start (the bond is not part of the NAV).
    function test_start_emptyVault() public {
        _seedPool(POOL_LIQUIDITY);
        _postBond(BOND);
        _wait(1 hours);
        vm.expectRevert(IOathVault.EmptyVault.selector);
        _startEpoch(RANGE_LOWER, RANGE_UPPER, _noSwap());
    }

    /// @dev Cap `L_b ≤ activeLiquidity · capBps / 10,000` (MATH.md §10), inclusive: at `400·L_b − 1` the limit
    ///      floors to `L_b − 1` and the start reverts; one more unit of pool liquidity and it passes.
    function test_start_capBoundary() public {
        (uint128 benchL,,) = BenchmarkLib.create(NAV_START, TickMath.getSqrtPriceAtTick(START_TICK), TICK_SPACING);
        _seedPool(uint256(benchL) * 400 - 1);
        _fundWorkedExample();
        _wait(1 hours);
        vm.expectRevert(IOathVault.VaultTooLarge.selector);
        _startEpoch(RANGE_LOWER, RANGE_UPPER, _noSwap());

        _seedPool(1);
        assertEq(manager.getLiquidity(key.toId()), uint256(benchL) * 400);
        _startEpoch(RANGE_LOWER, RANGE_UPPER, _noSwap());
        (uint128 l,,,,,,) = vault.benchmark();
        assertEq(l, benchL);
    }

    /// @dev Bond `≥ navStart · minBondBps / 10,000` (MATH.md §10), inclusive: $2,999.999999 against a $30,000
    ///      start reverts; one more raw unit makes exactly 10% and passes.
    function test_start_bondBoundary() public {
        _seedPool(POOL_LIQUIDITY);
        _depositWorkedExample();
        _postBond(BOND - 1);
        _wait(1 hours);
        vm.expectRevert(IOathVault.BondTooSmall.selector);
        _startEpoch(RANGE_LOWER, RANGE_UPPER, _noSwap());

        _postBond(1);
        _startEpoch(RANGE_LOWER, RANGE_UPPER, _noSwap());
        assertEq(vault.bondBalance(), BOND);
    }

    /// @dev The cap is checked before the bond.
    function test_start_capCheckedBeforeBond() public {
        _seedPool(1e9);
        _depositWorkedExample();
        _wait(1 hours);
        vm.expectRevert(IOathVault.VaultTooLarge.selector);
        _startEpoch(RANGE_LOWER, RANGE_UPPER, _noSwap());
    }

    // ---------------------------------------------------------------- reposition at start

    /// @dev Someone moves the price more than `maxIntraBlockTicks` (50) earlier in the same block: the vault's
    ///      liquidity add hits the hook's guard and the whole start reverts.
    function test_start_guardBlocksSameBlockMove() public {
        _seedPool(POOL_LIQUIDITY);
        _fundWorkedExample();
        _nextBlock(1 hours);
        _moveToTick(START_TICK + 51);
        vm.expectRevert(
            _hookError(
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(IOathHook.PriceMovedThisBlock.selector, START_TICK + 51, START_TICK)
            )
        );
        _startEpoch(RANGE_LOWER, RANGE_UPPER, _noSwap());
    }

    /// @dev A same-block move of exactly `maxIntraBlockTicks` is allowed.
    function test_start_guardAllowsMoveAtBound() public {
        _seedPool(POOL_LIQUIDITY);
        _fundWorkedExample();
        _nextBlock(1 hours);
        _moveToTick(START_TICK + 50);
        _startEpoch(RANGE_LOWER, RANGE_UPPER, _noSwap());
        assertEq(uint8(vault.state()), uint8(IOathVault.State.ACTIVE));
    }

    /// @dev The curator's exact-input swap runs before the liquidity is added. The benchmark keeps the fee
    ///      growth from before it (the start mark is taken first) and the start NAV is the pre-swap value.
    function test_start_withSwap() public {
        _seedPool(POOL_LIQUIDITY);
        (uint256 x,) = _fundWorkedExample();
        _wait(1 hours);
        _startEpoch(
            RANGE_LOWER,
            RANGE_UPPER,
            IOathVault.SwapIntent({
                zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
        (uint256 g0,) = manager.getFeeGrowthGlobals(key.toId());
        assertGt(g0, 0, "the curator's swap paid fees");
        (,,, uint256 bg0, uint256 bg1, uint256 navStart,) = vault.benchmark();
        assertEq(bg0, 0, "G0 at S excludes the curator's own swap");
        assertEq(bg1, 0);
        assertEq(navStart, NAV_START);
        assertLt(_tick(), START_TICK, "price moved down");

        (,, uint128 liquidity) = vault.positionInfo();
        assertGt(liquidity, 0);
        assertEq(_poolPositionLiquidity(RANGE_LOWER, RANGE_UPPER), liquidity);
        assertLt(vault.idle0(), x - 1e18, "swapped and added currency0");
        assertEq(vault.bondBalance(), BOND);
    }

    /// @dev Exact output (`amountSpecified > 0`) is rejected.
    function test_start_exactInputOnly() public {
        _seedPool(POOL_LIQUIDITY);
        _fundWorkedExample();
        _wait(1 hours);
        vm.expectRevert(IOathVault.ExactInputOnly.selector);
        _startEpoch(
            RANGE_LOWER,
            RANGE_UPPER,
            IOathVault.SwapIntent({
                zeroForOne: true, amountSpecified: 1, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
    }

    /// @dev A swap that needs one raw unit more currency1 than the idle balance would spend the bond: reverts.
    function test_start_swapCannotSpendBond() public {
        _seedPool(POOL_LIQUIDITY);
        (, uint256 y) = _fundWorkedExample();
        _wait(1 hours);
        vm.expectRevert(IOathVault.BondTouched.selector);
        _startEpoch(
            RANGE_LOWER,
            RANGE_UPPER,
            IOathVault.SwapIntent({
                zeroForOne: false, amountSpecified: -int256(y + 1), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    /// @dev Swapping all idle currency1 leaves nothing to pair with currency0 in an in-range position, so no
    ///      liquidity is added: the epoch still starts, with the range stored and `L_v = 0`. The hook's recorded
    ///      range stays unset, which is harmless with `L_v = 0` (the snapshot's fee growth is multiplied by 0).
    function test_start_zeroLiquidityPosition() public {
        _seedPool(POOL_LIQUIDITY);
        (uint256 x, uint256 y) = _fundWorkedExample();
        _wait(1 hours);
        _startEpoch(
            RANGE_LOWER,
            RANGE_UPPER,
            IOathVault.SwapIntent({
                zeroForOne: false, amountSpecified: -int256(y), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            })
        );
        assertGt(_tick(), START_TICK);
        assertLt(_tick(), RANGE_UPPER, "still in range");

        (int24 lower, int24 upper, uint128 liquidity) = vault.positionInfo();
        assertEq(lower, RANGE_LOWER);
        assertEq(upper, RANGE_UPPER);
        assertEq(liquidity, 0, "L_v = 0");
        assertEq(_poolPositionLiquidity(RANGE_LOWER, RANGE_UPPER), 0);
        (,, int24 vaultLower, int24 vaultUpper) = hook.configs(key.toId());
        assertEq(vaultLower, 0);
        assertEq(vaultUpper, 0);
        assertEq(vault.idle1(), 0, "all currency1 swapped");
        assertGt(vault.idle0(), x, "currency0 bought");
        assertEq(uint8(vault.state()), uint8(IOathVault.State.ACTIVE));
        assertEq(vault.bondBalance(), BOND);
    }

    /// @dev Whatever the range and swap (within the idle balance), a start never spends the bond, and the pool
    ///      holds exactly the recorded `L_v` under the vault's salt.
    function testFuzz_start_neverSpendsBond(bool zeroForOne, uint256 amountIn, int256 lowerSeed, uint256 width) public {
        _seedPool(POOL_LIQUIDITY);
        (uint256 x, uint256 y) = _fundWorkedExample();
        _wait(1 hours);
        amountIn = bound(amountIn, 1, zeroForOne ? x : y); // at most ~41 ticks of impact, inside the guard
        int24 lower = int24(bound(lowerSeed, -2_010, -1_970)) * TICK_SPACING * 10;
        int24 upper = lower + int24(int256(bound(width, 1, 400))) * TICK_SPACING;

        _startEpoch(
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
    }

    // ---------------------------------------------------------------- while ACTIVE

    /// @dev Deposits happen only in the open window.
    function test_active_depositReverts() public {
        _startWorkedExample();
        _give(bob, 1e18, 1e9);
        vm.prank(bob);
        vm.expectRevert(IOathVault.NotOpen.selector);
        vault.deposit(1e18, 1e9, 0, bob);
    }

    /// @dev Withdrawals happen only in the open window.
    function test_active_withdrawReverts() public {
        _startWorkedExample();
        uint256 shares = vault.balanceOf(alice);
        assertGt(shares, 0);
        vm.prank(alice);
        vm.expectRevert(IOathVault.NotOpen.selector);
        vault.withdraw(shares, 0, 0, alice);
    }

    /// @dev During an epoch the bond backs the curator's result and cannot be withdrawn.
    function test_active_withdrawBondReverts() public {
        _startWorkedExample();
        vm.prank(curator);
        vm.expectRevert(IOathVault.NotOpen.selector);
        vault.withdrawBond(1);
    }

    /// @dev The open window cannot be refreshed during an epoch, however long ago it opened.
    function test_active_refreshOpenWindowReverts() public {
        _startWorkedExample();
        vm.warp(createdAt + 6 hours + 1);
        vm.expectRevert(IOathVault.NotOpen.selector);
        vault.refreshOpenWindow();
    }

    /// @dev The curator can add to the bond at any time, including during an epoch.
    function test_active_postBondAllowed() public {
        _startWorkedExample();
        _postBond(500e6);
        assertEq(vault.bondBalance(), BOND + 500e6);
        assertEq(c1.balanceOf(address(vault)), vault.idle1() + BOND + 500e6);
    }

    /// @dev Native ETH as currency0: the curator's ETH swap and the liquidity add are both paid in ETH.
    function test_start_nativeEth() public {
        _createVault(CurrencyLibrary.ADDRESS_ZERO);
        uint256 openedAt = _time();
        _seedPool(POOL_LIQUIDITY);
        (uint256 x,) = _fundWorkedExample();
        vm.warp(openedAt + 1 hours);
        _startEpoch(
            RANGE_LOWER,
            RANGE_UPPER,
            IOathVault.SwapIntent({
                zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
        (,, uint128 liquidity) = vault.positionInfo();
        assertGt(liquidity, 0);
        assertEq(_poolPositionLiquidity(RANGE_LOWER, RANGE_UPPER), liquidity);
        assertEq(vault.idle0(), address(vault).balance);
        assertLt(vault.idle0(), x - 1e18);
        assertEq(vault.bondBalance(), BOND);
    }
}

/// @notice The hook's guard also bounds the curator's own swap at `startEpoch`. A tighter `maxIntraBlockTicks`
///         (10) keeps the swap within what the worked-example vault can pay.
contract OathVaultStartSwapBoundTest is OathVaultTestBase {
    function setUp() public override {
        super.setUp();
        IOathVault.VaultParams memory p = _defaultParams();
        p.maxIntraBlockTicks = 10;
        _createVault(currency0, p);
        _seedPool(POOL_LIQUIDITY);
        _fundWorkedExample();
        _wait(1 hours);
    }

    /// @dev Swapping the price up 11 ticks, one more than the guard allows: the add reverts.
    function test_start_ownSwapBeyondGuardReverts() public {
        IOathVault.SwapIntent memory swap = _swapUpTo(START_TICK + 11);
        vm.expectRevert(
            _hookError(
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(IOathHook.PriceMovedThisBlock.selector, START_TICK + 11, START_TICK)
            )
        );
        _startEpoch(RANGE_LOWER, RANGE_UPPER, swap);
    }

    /// @dev Exactly 10 ticks is allowed.
    function test_start_ownSwapAtGuardBound() public {
        _startEpoch(RANGE_LOWER, RANGE_UPPER, _swapUpTo(START_TICK + 10));
        (, int24 tick,,) = StateLibrary.getSlot0(manager, key.toId());
        assertEq(tick, START_TICK + 10);
        (,, uint128 liquidity) = vault.positionInfo();
        assertGt(liquidity, 0);
    }

    /// @dev Exact-input currency1 swap stopped by the price limit at `tick`.
    function _swapUpTo(int24 tick) internal view returns (IOathVault.SwapIntent memory) {
        return IOathVault.SwapIntent({
            zeroForOne: false,
            amountSpecified: -int256(vault.idle1()),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tick)
        });
    }
}
