// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
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
    /// @dev Each `_create` uses a fresh static fee, so every call is a new pool key.
    uint24 internal nextFee = 100;

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

    // ---------------------------------------------------------------- one vault per pool key

    /// @dev A second vault for the same pool key is refused by the hook; the first registration stands.
    function test_factory_oneVaultPerPoolKey() public {
        address first =
            factory.createVault(currency0, currency1, POOL_FEE, TICK_SPACING, startPrice, curator, _defaultParams());

        vm.prank(alice);
        vm.expectRevert(IOathHook.AlreadyRegistered.selector);
        factory.createVault(currency0, currency1, POOL_FEE, TICK_SPACING, startPrice, alice, _demoParams());

        (address registered,,,) = hook.configs(_oathKey(currency0, currency1).toId());
        assertEq(registered, first, "first vault kept");
    }

    /// @dev The same currencies with another fee or tick spacing are other pools, each with its own vault.
    function test_factory_otherKeysGetTheirOwnVaults() public {
        address a =
            factory.createVault(currency0, currency1, POOL_FEE, TICK_SPACING, startPrice, curator, _defaultParams());
        address b =
            factory.createVault(currency0, currency1, 3_000, TICK_SPACING, startPrice, curator, _defaultParams());
        address c = factory.createVault(currency0, currency1, POOL_FEE, 60, startPrice, curator, _defaultParams());
        assertTrue(a != b && b != c && a != c, "distinct vaults");
    }

    // ---------------------------------------------------------------- checks before the bounds

    function test_factory_zeroCurator() public {
        vm.expectRevert(IOathFactory.ZeroCurator.selector);
        factory.createVault(currency0, currency1, POOL_FEE, TICK_SPACING, startPrice, address(0), _defaultParams());
    }

    /// @dev Dynamic-fee pools are refused: the hook never sets a fee, so they would trade at 0%.
    function test_factory_dynamicFee() public {
        vm.expectRevert(IOathFactory.DynamicFee.selector);
        factory.createVault(
            currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, startPrice, curator, _defaultParams()
        );
    }

    /// @dev Checks run in the documented order: curator, fee, then the bounds in declaration order.
    function test_factory_checkOrder() public {
        IOathVault.VaultParams memory p = _defaultParams();
        p.twapWindow = 0; // BadTwapWindow
        p.capBps = 0; // BadCap

        vm.expectRevert(IOathFactory.ZeroCurator.selector);
        factory.createVault(
            currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, startPrice, address(0), p
        );
        vm.expectRevert(IOathFactory.DynamicFee.selector);
        factory.createVault(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, startPrice, curator, p);
        vm.expectRevert(IOathFactory.BadTwapWindow.selector);
        factory.createVault(currency0, currency1, POOL_FEE, TICK_SPACING, startPrice, curator, p);
    }

    // ---------------------------------------------------------------- parameter bounds (MATH.md §12)

    /// @dev `twapWindow` in 5 min – 2 h.
    function test_factory_twapWindowBounds() public {
        IOathVault.VaultParams memory p = _defaultParams();
        p.twapWindow = 5 minutes;
        _create(p);
        p.twapWindow = 2 hours;
        _create(p);
        p.twapWindow = 5 minutes - 1;
        _expectBad(p, IOathFactory.BadTwapWindow.selector);
        p.twapWindow = 2 hours + 1;
        _expectBad(p, IOathFactory.BadTwapWindow.selector);
    }

    /// @dev `epochDuration ≥ 2 × twapWindow`.
    function test_factory_epochDurationAtLeastTwoWindows() public {
        IOathVault.VaultParams memory p = _defaultParams();
        p.epochDuration = 2 * p.twapWindow;
        p.rebalanceCooldown = p.epochDuration;
        _create(p);
        p.epochDuration = 2 * p.twapWindow - 1;
        p.rebalanceCooldown = 0;
        _expectBad(p, IOathFactory.BadEpochDuration.selector);
    }

    /// @dev `maxOpen > twapWindow`.
    function test_factory_maxOpenAboveWindow() public {
        IOathVault.VaultParams memory p = _defaultParams();
        p.maxOpen = p.twapWindow + 1;
        _create(p);
        p.maxOpen = p.twapWindow;
        _expectBad(p, IOathFactory.BadMaxOpen.selector);
    }

    /// @dev `rebalanceCooldown ≤ epochDuration` (0 allowed).
    function test_factory_rebalanceCooldownWithinEpoch() public {
        IOathVault.VaultParams memory p = _defaultParams();
        p.rebalanceCooldown = p.epochDuration;
        _create(p);
        p.rebalanceCooldown = 0;
        _create(p);
        p.rebalanceCooldown = p.epochDuration + 1;
        _expectBad(p, IOathFactory.BadRebalanceCooldown.selector);
    }

    /// @dev `maxIntraBlockTicks` in 1 – 1,000.
    function test_factory_maxIntraBlockTicksBounds() public {
        IOathVault.VaultParams memory p = _defaultParams();
        p.maxIntraBlockTicks = 1;
        _create(p);
        p.maxIntraBlockTicks = 1_000;
        _create(p);
        p.maxIntraBlockTicks = 0;
        _expectBad(p, IOathFactory.BadMaxIntraBlockTicks.selector);
        p.maxIntraBlockTicks = -1;
        _expectBad(p, IOathFactory.BadMaxIntraBlockTicks.selector);
        p.maxIntraBlockTicks = 1_001;
        _expectBad(p, IOathFactory.BadMaxIntraBlockTicks.selector);
    }

    /// @dev `bandBps ≤ 500` (0 allowed).
    function test_factory_bandBounds() public {
        IOathVault.VaultParams memory p = _defaultParams();
        p.bandBps = 500;
        _create(p);
        p.bandBps = 0;
        _create(p);
        p.bandBps = 501;
        _expectBad(p, IOathFactory.BadBand.selector);
    }

    /// @dev `perfFeeBps ≤ 5,000` (0 allowed).
    function test_factory_perfFeeBounds() public {
        IOathVault.VaultParams memory p = _defaultParams();
        p.perfFeeBps = 5_000;
        _create(p);
        p.perfFeeBps = 0;
        _create(p);
        p.perfFeeBps = 5_001;
        _expectBad(p, IOathFactory.BadPerfFee.selector);
    }

    /// @dev `minBondBps ≥ 100`.
    function test_factory_minBondBounds() public {
        IOathVault.VaultParams memory p = _defaultParams();
        p.minBondBps = 100;
        _create(p);
        p.minBondBps = 99;
        _expectBad(p, IOathFactory.BadMinBond.selector);
    }

    /// @dev `capBps` in 1 – 1,000.
    function test_factory_capBounds() public {
        IOathVault.VaultParams memory p = _defaultParams();
        p.capBps = 1;
        _create(p);
        p.capBps = 1_000;
        _create(p);
        p.capBps = 0;
        _expectBad(p, IOathFactory.BadCap.selector);
        p.capBps = 1_001;
        _expectBad(p, IOathFactory.BadCap.selector);
    }

    /// @dev For parameters near every edge, `createVault` succeeds exactly when all MATH.md §12 bounds hold, and
    ///      otherwise reverts with the error of the first broken rule.
    function testFuzz_factory_acceptsExactlyTheBounds(
        uint32 epochDuration,
        uint32 twapWindow,
        uint32 maxOpen,
        uint32 rebalanceCooldown,
        int24 maxIntraBlockTicks,
        uint16 bandBps,
        uint16 perfFeeBps,
        uint16 minBondBps,
        uint16 capBps
    ) public {
        IOathVault.VaultParams memory p = IOathVault.VaultParams({
            epochDuration: uint32(bound(epochDuration, 0, 5 hours)),
            twapWindow: uint32(bound(twapWindow, 0, 2 hours + 60)),
            maxOpen: uint32(bound(maxOpen, 0, 3 hours)),
            rebalanceCooldown: uint32(bound(rebalanceCooldown, 0, 5 hours)),
            maxIntraBlockTicks: int24(bound(maxIntraBlockTicks, -5, 1_005)),
            bandBps: uint16(bound(bandBps, 0, 505)),
            perfFeeBps: uint16(bound(perfFeeBps, 4_995, 5_005)),
            minBondBps: uint16(bound(minBondBps, 95, 105)),
            capBps: uint16(bound(capBps, 0, 1_005))
        });

        bytes4 expected = _firstBrokenRule(p);
        if (expected == bytes4(0)) {
            _create(p);
        } else {
            _expectBad(p, expected);
        }
    }

    // ---------------------------------------------------------------- helpers

    /// @dev The MATH.md §12 table, rule by rule, in the factory's check order; `0` if every rule holds.
    function _firstBrokenRule(IOathVault.VaultParams memory p) internal pure returns (bytes4) {
        if (p.twapWindow < 5 minutes || p.twapWindow > 2 hours) return IOathFactory.BadTwapWindow.selector;
        if (uint256(p.epochDuration) < 2 * uint256(p.twapWindow)) return IOathFactory.BadEpochDuration.selector;
        if (p.maxOpen <= p.twapWindow) return IOathFactory.BadMaxOpen.selector;
        if (p.rebalanceCooldown > p.epochDuration) return IOathFactory.BadRebalanceCooldown.selector;
        if (p.maxIntraBlockTicks < 1 || p.maxIntraBlockTicks > 1_000) {
            return IOathFactory.BadMaxIntraBlockTicks.selector;
        }
        if (p.bandBps > 500) return IOathFactory.BadBand.selector;
        if (p.perfFeeBps > 5_000) return IOathFactory.BadPerfFee.selector;
        if (p.minBondBps < 100) return IOathFactory.BadMinBond.selector;
        if (p.capBps < 1 || p.capBps > 1_000) return IOathFactory.BadCap.selector;
        return bytes4(0);
    }

    /// @dev Creates a vault for a fresh pool key and checks it stored `p`.
    function _create(IOathVault.VaultParams memory p) internal returns (address v) {
        v = factory.createVault(currency0, currency1, nextFee++, TICK_SPACING, startPrice, curator, p);
        assertEq(abi.encode(OathVault(v).params()), abi.encode(p), "params stored");
    }

    function _expectBad(IOathVault.VaultParams memory p, bytes4 err) internal {
        vm.expectRevert(err);
        factory.createVault(currency0, currency1, nextFee++, TICK_SPACING, startPrice, curator, p);
    }
}
