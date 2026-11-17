// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {ValuationLib} from "../../src/libraries/ValuationLib.sol";
import {DemoLib} from "./DemoLib.sol";

/// @title DemoCurator
/// @notice The demo curator's repositions with a ratio swap: an exact-input swap that brings the vault's holdings
///         to the new range's token ratio at the price the swap itself leaves behind, so that the least value stays
///         idle. A ratio read at the pre-swap price would ignore the swap's own impact (tens of ticks for a
///         $30,000 vault on the real pool's depth), so the swap size is found the way an off-chain quoter would:
///         by dry-running the vault's own `startEpoch` or `rebalance` on a state snapshot.
/// @dev Simulation only (cheatcodes). Each dry run is reverted, so only the final call changes state. Steps:
///      1. Dry run without a swap: the idle side left over is the surplus token, and its amount bounds the sale.
///      2. Bisect the sale `s ∈ [0, surplus]`: after a dry run with `s`, if the sold token is still the one left
///         idle, sell more, else less; stop at 1 ppm of the surplus. Keep the dry run that left the least value
///         idle (marked at the post-swap spot).
///      3. Make the real call with that swap. Its price limit (`DemoLib.guardedLimit`) keeps the curator's own
///         impact inside the hook's guard.
library DemoCurator {
    using StateLibrary for IPoolManager;

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    /// @dev The bisection stops once the bracket is within 1 / PRECISION of the surplus.
    uint256 private constant PRECISION = 1e6;

    /// @dev The value left idle by a dry run, and which token holds most of it.
    struct Leftover {
        bool token0;
        uint256 amount;
        uint256 value;
    }

    /// @notice Starts the vault's epoch on `[lower, upper)` with the ratio swap (see the library notice).
    /// @param vault The vault (OPEN, open window ready, bond sufficient).
    /// @param lower Lower tick.
    /// @param upper Upper tick.
    /// @return swap The swap used.
    function startEpoch(IOathVault vault, int24 lower, int24 upper)
        internal
        returns (IOathVault.SwapIntent memory swap)
    {
        swap = _bestSwap(vault, true, lower, upper);
        _call(vault, true, lower, upper, swap);
    }

    /// @notice Rebalances the vault to `[lower, upper)` with the ratio swap (see the library notice).
    /// @param vault The vault (ACTIVE, cooldown passed, before the epoch end).
    /// @param lower Lower tick.
    /// @param upper Upper tick.
    /// @return swap The swap used.
    function rebalance(IOathVault vault, int24 lower, int24 upper)
        internal
        returns (IOathVault.SwapIntent memory swap)
    {
        swap = _bestSwap(vault, false, lower, upper);
        _call(vault, false, lower, upper, swap);
    }

    function _bestSwap(IOathVault vault, bool start, int24 lower, int24 upper)
        private
        returns (IOathVault.SwapIntent memory best)
    {
        Leftover memory none = _dryRun(vault, start, lower, upper, best);
        if (none.amount == 0) return best;
        (, int24 tick,,) = vault.manager().getSlot0(vault.poolId());
        uint160 limit = DemoLib.guardedLimit(tick, none.token0, vault.params().maxIntraBlockTicks);
        uint256 bestValue = none.value;
        uint256 lo;
        uint256 hi = none.amount;
        while (hi - lo > 1 && hi - lo > hi / PRECISION) {
            uint256 mid = (lo + hi) / 2;
            IOathVault.SwapIntent memory s = IOathVault.SwapIntent(none.token0, -int256(mid), limit);
            Leftover memory left = _dryRun(vault, start, lower, upper, s);
            if (left.value < bestValue) (best, bestValue) = (s, left.value);
            if (left.token0 == none.token0) lo = mid;
            else hi = mid;
        }
    }

    /// @dev Makes the call on a snapshot, measures the idle leftover at the resulting spot price, and reverts.
    function _dryRun(IOathVault vault, bool start, int24 lower, int24 upper, IOathVault.SwapIntent memory swap)
        private
        returns (Leftover memory left)
    {
        uint256 snapshot = VM.snapshotState();
        _call(vault, start, lower, upper, swap);
        (uint160 sqrtPriceX96,,,) = vault.manager().getSlot0(vault.poolId());
        uint256 value0 = ValuationLib.value(vault.idle0(), 0, sqrtPriceX96);
        uint256 value1 = vault.idle1();
        left = Leftover({token0: value0 > value1, amount: 0, value: value0 + value1});
        left.amount = left.token0 ? vault.idle0() : value1;
        VM.revertToStateAndDelete(snapshot);
    }

    function _call(IOathVault vault, bool start, int24 lower, int24 upper, IOathVault.SwapIntent memory swap) private {
        address curator = vault.curator();
        VM.prank(curator);
        if (start) vault.startEpoch(lower, upper, swap);
        else vault.rebalance(lower, upper, swap);
    }
}
