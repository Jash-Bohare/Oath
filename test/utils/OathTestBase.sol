// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IOathHook} from "../../src/interfaces/IOathHook.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {OathFactory} from "../../src/OathFactory.sol";

/// @notice The exact permission set of OathHook; everything else, including every
///         `*ReturnsDelta` flag, is false.
function oathPermissions() pure returns (Hooks.Permissions memory p) {
    p.beforeInitialize = true;
    p.beforeAddLiquidity = true;
    p.beforeRemoveLiquidity = true;
    p.beforeSwap = true;
    p.beforeDonate = true;
}

/// @title OathTestBase
/// @notice Shared setup for Oath tests: a real `PoolManager` with v4-core's test routers (via `Deployers`),
///         two sorted ERC-20 currencies, the flagged hook address, pool keys and the per-vault parameters.
/// @dev The hook can only live at an address whose low 14 bits equal its permission flags,
///      so it is deployed with `deployCodeTo` at `HOOK_ADDRESS`.
abstract contract OathTestBase is Deployers {
    using StateLibrary for IPoolManager;

    /// @notice OathHook permission flags: beforeInitialize | beforeAddLiquidity | beforeRemoveLiquidity |
    ///         beforeSwap | beforeDonate = 0x2AA0.
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG;

    /// @notice Where tests deploy the hook: arbitrary high bits, low 14 bits exactly `HOOK_FLAGS`.
    address internal constant HOOK_ADDRESS = address(uint160(0x4f41544800000000000000000000000000000000) | HOOK_FLAGS);

    /// @notice Demo pool shape: ETH/USDC, fee 500, tick spacing 10 (MATH.md §1).
    uint24 internal constant POOL_FEE = 500;
    int24 internal constant TICK_SPACING = 10;

    address internal curator = makeAddr("curator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    /// @notice Deploys a fresh `PoolManager`, all v4-core test routers, and two sorted, minted and
    ///         router-approved ERC-20 currencies (`currency0 < currency1`).
    function setUp() public virtual {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
    }

    /// @notice Deploys the contract `artifact` with constructor `args` at `HOOK_ADDRESS`.
    function _deployHookAt(string memory artifact, bytes memory args) internal returns (address) {
        deployCodeTo(artifact, args, HOOK_ADDRESS);
        return HOOK_ADDRESS;
    }

    /// @notice Deploys `OathHook(manager, factory)` at the flagged address.
    function _deployOathHook(address factory) internal returns (IOathHook) {
        return IOathHook(_deployHookAt("OathHook.sol:OathHook", abi.encode(manager, factory)));
    }

    /// @notice Deploys the real hook-and-factory pair: the hook (at `HOOK_ADDRESS`) for a factory at a fixed
    ///         address, then the factory there, whose constructor checks `hook.factory() == address(this)`.
    /// @dev Both use `deployCodeTo`, so no address prediction depends on this contract's nonce (which
    ///      `deployCodeTo` itself advances). The deploy script predicts the factory's CREATE address instead.
    function _deployOathStack() internal returns (IOathHook hook, OathFactory factory) {
        address factoryAddress = makeAddr("OathFactory");
        hook = _deployOathHook(factoryAddress);
        deployCodeTo("OathFactory.sol:OathFactory", abi.encode(manager, hook), factoryAddress);
        factory = OathFactory(factoryAddress);
    }

    /// @notice A pool key for `c0`/`c1` with the demo fee and tick spacing and the hook at `HOOK_ADDRESS`.
    ///         Pass `CurrencyLibrary.ADDRESS_ZERO` as `c0` for a native-ETH pool.
    function _oathKey(Currency c0, Currency c1) internal pure returns (PoolKey memory) {
        return
            PoolKey({
                currency0: c0, currency1: c1, fee: POOL_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(HOOK_ADDRESS)
            });
    }

    /// @notice Full-range bounds for the pool's tick spacing: −887270 / 887270 for spacing 10 (MATH.md §1).
    function _fullRange() internal pure returns (int24 tickMin, int24 tickMax) {
        return (TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING));
    }

    /// @notice Default vault parameters (MATH.md §12).
    function _defaultParams() internal pure returns (IOathVault.VaultParams memory) {
        return IOathVault.VaultParams({
            epochDuration: 7 days,
            twapWindow: 30 minutes,
            maxOpen: 6 hours,
            rebalanceCooldown: 1 hours,
            maxIntraBlockTicks: 50,
            bandBps: 35,
            perfFeeBps: 2_000,
            minBondBps: 1_000,
            capBps: 25
        });
    }

    /// @notice Demo vault parameters: the defaults with 1-day epochs (MATH.md §12).
    function _demoParams() internal pure returns (IOathVault.VaultParams memory p) {
        p = _defaultParams();
        p.epochDuration = 1 days;
    }

    /// @notice The revert data the `PoolManager` produces when the hook at `HOOK_ADDRESS` reverts with `reason`
    ///         inside the callback `callbackSelector`: v4 wraps it as
    ///         `WrappedError(hook, callbackSelector, reason, HookCallFailed())`. Use with `vm.expectRevert`.
    function _hookError(bytes4 callbackSelector, bytes memory reason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            HOOK_ADDRESS,
            callbackSelector,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @notice Gives `who` `amount` of `currency` (minted ERC-20, or ETH via `deal` for native).
    function _fund(Currency currency, address who, uint256 amount) internal {
        if (currency.isAddressZero()) {
            vm.deal(who, who.balance + amount);
        } else {
            MockERC20(Currency.unwrap(currency)).mint(who, amount);
        }
    }

    /// @notice Swaps exact-input through `key` until its price is exactly `target` (the swap's price limit).
    ///         No-op if the pool is already there. The pool needs enough liquidity on the way.
    function _moveTo(PoolKey memory key, uint160 target) internal {
        (uint160 current,,,) = manager.getSlot0(key.toId());
        if (current == target) return;
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: target < current, amountSpecified: -1e40, sqrtPriceLimitX96: target}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }
}
