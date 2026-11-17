// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IOathHook} from "../../src/interfaces/IOathHook.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {BenchmarkLib} from "../../src/libraries/BenchmarkLib.sol";
import {ValuationLib} from "../../src/libraries/ValuationLib.sol";
import {OathFactory} from "../../src/OathFactory.sol";
import {OathVault} from "../../src/OathVault.sol";
import {ForkBase} from "./ForkBase.sol";

/// @title OathForkBase
/// @notice An Oath vault on mainnet at B0: the real hook and factory deployed on the fork, a native-ETH/USDC Oath
///         pool created at the real pool's B0 price with the real pool's liquidity curve cloned into it, the MATH.md
///         §9.1 deposit ($30,000 split 50/50 by value) and bond ($3,000), and a price-anchored replay of the real
///         swaps recorded after B0 (`demo/fetch_swaps.py`) at their real blocks and timestamps.
abstract contract OathForkBase is ForkBase {
    using StateLibrary for IPoolManager;

    /// @dev OathHook's permission flags (0x2AA0) under arbitrary high bits.
    address internal constant HOOK_ADDRESS = address(
        uint160(0x4f41544800000000000000000000000000000000)
            | (Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_DONATE_FLAG)
    );
    uint256 internal constant NAV_START = 30_000e6;
    uint256 internal constant BOND = 3_000e6;
    uint32 internal constant TWAP_WINDOW = 30 minutes;

    address internal curator = makeAddr("curator");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");

    IOathHook internal hook;
    OathFactory internal factory;
    OathVault internal vault;
    PoolKey internal key;
    PoolId internal id;
    PoolModifyLiquidityTest internal lpRouter;
    PoolSwapTest internal swapRouter;
    uint256 internal createdAt;
    uint160 internal sqrtB0;

    // Replay state: the recorded swaps (only prices, blocks and timestamps are needed for price-anchored flow),
    // the next swap to replay, and a brute-force Σ tick·dt of the Oath pool since its creation.
    uint256[] internal prices;
    uint256[] internal blocks;
    uint256[] internal timestamps;
    uint256 internal cursor;
    int256 internal bruteCumulative;
    uint256 internal bruteLastTime;
    int24 internal bruteLastTick;
    uint256 internal priceMisses;

    /// @dev Forks mainnet at B0, deploys Oath, creates the vault (1-day epochs) at the real B0 price, clones the
    ///      real liquidity curve, funds the worked-example deposit and bond, and loads the swaps of the first
    ///      `replayDuration` seconds after B0.
    function _setUpOath(uint256 replayDuration) internal {
        _fork(B0);
        (lpRouter, swapRouter) = _routers();
        (sqrtB0,,,) = MANAGER.getSlot0(realId);

        address factoryAddress = makeAddr("OathFactory");
        deployCodeTo("OathHook.sol:OathHook", abi.encode(MANAGER, factoryAddress), HOOK_ADDRESS);
        hook = IOathHook(HOOK_ADDRESS);
        deployCodeTo("OathFactory.sol:OathFactory", abi.encode(MANAGER, hook), factoryAddress);
        factory = OathFactory(factoryAddress);

        IOathVault.VaultParams memory p = IOathVault.VaultParams({
            epochDuration: 1 days,
            twapWindow: TWAP_WINDOW,
            maxOpen: 6 hours,
            rebalanceCooldown: 1 hours,
            maxIntraBlockTicks: 50,
            bandBps: 35,
            perfFeeBps: 2_000,
            minBondBps: 1_000,
            capBps: 25
        });
        vault = OathVault(
            payable(factory.createVault(
                    CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(USDC), FEE, SPACING, sqrtB0, curator, p
                ))
        );
        key = vault.poolKey();
        id = key.toId();
        createdAt = vm.getBlockTimestamp();
        bruteLastTime = createdAt;
        (, bruteLastTick,,) = MANAGER.getSlot0(id);

        _cloneLayout();
        _fundWorkedExample();
        _loadSwaps(createdAt + replayDuration);
    }

    /// @dev One position per segment between consecutive initialized ticks of the real pool at B0, with the
    ///      segment's active liquidity, so the Oath pool's liquidity curve equals the real pool's.
    function _cloneLayout() internal {
        string memory layout = vm.readFile(string.concat(vm.projectRoot(), LAYOUT_FILE));
        assertEq(vm.parseJsonUint(layout, ".block"), B0, "layout at B0");
        int256[] memory ticks = vm.parseJsonIntArray(layout, ".ticks");
        int256[] memory nets = vm.parseJsonIntArray(layout, ".liquidityNet");
        int256 liquidity;
        for (uint256 i; i + 1 < ticks.length; ++i) {
            liquidity += nets[i];
            if (liquidity == 0) continue;
            lpRouter.modifyLiquidity{value: 10_000 ether}( // the router refunds what the pool does not take
                key, ModifyLiquidityParams(int24(ticks[i]), int24(ticks[i + 1]), liquidity, bytes32(0)), ""
            );
        }
        assertEq(liquidity + nets[ticks.length - 1], 0, "layout closes at zero liquidity");
        assertEq(MANAGER.getLiquidity(id), MANAGER.getLiquidity(realId), "cloned active liquidity = real pool's");
        assertEq(MANAGER.getLiquidity(id), vm.parseJsonUint(layout, ".activeLiquidity"));
    }

    /// @dev Alice deposits `x` ETH (the 50/50 split of $30,000 at the B0 price) and the USDC that makes exactly
    ///      $30,000 at that price; the curator posts the $3,000 bond.
    function _fundWorkedExample() internal {
        (uint256 x,) = BenchmarkLib.split(NAV_START, sqrtB0);
        uint256 y = NAV_START - ValuationLib.value(x, 0, sqrtB0);
        vm.deal(alice, x);
        deal(USDC, alice, y);
        vm.startPrank(alice);
        IERC20Minimal(USDC).approve(address(vault), type(uint256).max);
        vault.deposit{value: x}(x, y, 0, alice);
        vm.stopPrank();
        deal(USDC, curator, BOND);
        vm.startPrank(curator);
        IERC20Minimal(USDC).approve(address(vault), type(uint256).max);
        vault.postBond(BOND);
        vm.stopPrank();
    }

    function _loadSwaps(uint256 until) internal {
        string memory swaps = vm.readFile(string.concat(vm.projectRoot(), SWAPS_FILE));
        assertEq(vm.parseJsonUint(swaps, ".fromBlock"), B0, "swaps start at B0");
        uint256[] memory p = vm.parseJsonUintArray(swaps, ".sqrtPriceX96");
        uint256[] memory b = vm.parseJsonUintArray(swaps, ".blocks");
        uint256[] memory t = vm.parseJsonUintArray(swaps, ".timestamps");
        for (uint256 i; i < t.length && t[i] <= until; ++i) {
            prices.push(p[i]);
            blocks.push(b[i]);
            timestamps.push(t[i]);
        }
    }

    // ---------------------------------------------------------------- replay

    /// @dev Replays every loaded swap with timestamp ≤ `t`, at its real block and time: each moves the Oath pool to
    ///      the recorded post-swap price (arbitrage flow; huge exact input with the price as the limit). Accrues the
    ///      brute-force tick cumulative along the way.
    function _replayUntil(uint256 t) internal {
        while (cursor < timestamps.length && timestamps[cursor] <= t) {
            vm.roll(blocks[cursor]);
            vm.warp(timestamps[cursor]);
            _accrue(timestamps[cursor]);
            (uint160 current,,,) = MANAGER.getSlot0(id);
            uint160 target = uint160(prices[cursor]);
            if (current != target) {
                bool zeroForOne = target < current;
                swapRouter.swap{value: zeroForOne ? 10_000_000 ether : 0}(
                    key,
                    SwapParams(zeroForOne, zeroForOne ? -int256(10_000_000 ether) : -int256(1e16), target),
                    PoolSwapTest.TestSettings(false, false),
                    ""
                );
                (current,,,) = MANAGER.getSlot0(id);
                if (current != target) ++priceMisses;
            }
            (, bruteLastTick,,) = MANAGER.getSlot0(id);
            ++cursor;
        }
    }

    /// @dev Moves to time `t` (no swap between the last replayed swap and `t`) in the block after the last replayed
    ///      swap, for a vault action, and returns the brute-force cumulative at `t`.
    function _actAt(uint256 t) internal returns (int256 cumulative) {
        uint256 lastBlock = cursor == 0 ? B0 : blocks[cursor - 1];
        vm.roll(lastBlock + 1);
        vm.warp(t);
        _accrue(t);
        return bruteCumulative;
    }

    /// @dev The brute-force cumulative at `t` without moving time: valid when no swap lies between the last replayed
    ///      swap and `t` (call right after `_replayUntil(t)`).
    function _bruteCumulativeAt(uint256 t) internal view returns (int256) {
        return bruteCumulative + int256(bruteLastTick) * int256(t - bruteLastTime);
    }

    function _accrue(uint256 t) internal {
        bruteCumulative += int256(bruteLastTick) * int256(t - bruteLastTime);
        bruteLastTime = t;
    }

    /// @dev `floorDiv(delta, dt)` (MATH.md §4).
    function _floorDiv(int256 delta, uint256 dt) internal pure returns (int24) {
        int256 q = delta / int256(dt);
        if (delta < 0 && delta % int256(dt) != 0) --q;
        return int24(q);
    }
}
