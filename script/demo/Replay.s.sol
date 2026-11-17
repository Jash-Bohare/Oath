// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {ValuationLib} from "../../src/libraries/ValuationLib.sol";
import {DemoCurator} from "./DemoCurator.sol";
import {DemoLib} from "./DemoLib.sol";
import {DemoSeed} from "./Seed.s.sol";

/// @title Replay
/// @notice The demo backtest: the seeded Oath vault (`Seed.s.sol`) lives through a window of real mainnet swaps,
///         replayed at their real blocks and timestamps, while a curator strategy runs 1-day epochs and anyone
///         settles them. Writes `demo/results/<window>_<strategy>.json` (`..._amount.json` in amount mode).
///
///         Flow models: `price` (default) moves the Oath pool to each recorded post-swap price with a huge exact
///         input and the price as the limit (arbitrage keeping the pool at the market price, the flow under which
///         the benchmark is exact, MATH.md §13); `amount` replays each recorded exact-input amount instead.
///
///         Each run: an epoch starts once the open window reaches the TWAP window (30 minutes), settles at its end,
///         and the next open window starts at settlement, until the next epoch would end after the window. Before
///         each start the curator tops the bond up to the minimum (10% of the start NAV, computed as the vault
///         will) and repositions with a ratio swap (`DemoCurator`). Vault actions at time `t` run in the block
///         after the last replayed swap. `series` samples `previewLive()` every hour from the seed time: the
///         sample at second `s` is the state before any swap or action at `s`. `epochs` come only from `Settled`
///         events.
///
///         Run: `FOUNDRY_PROFILE=demo forge script script/demo/Replay.s.sol` (the `demo` profile lifts the 2^30
///         gas limit; the script forks mainnet itself through `ETH_RPC_URL`). Environment:
///         `WINDOW` (default `2026-11-08_2026-11-15`, reads `demo/swaps/<window>.json`), `LAYOUT` (default
///         `demo/layout_B0.json`, its block must be the swaps' `fromBlock`), `STRATEGY` (`all` or one name),
///         `MODE` (`price` or `amount`).
/// @dev Simulation only. Liquidity changes in the real pool during the window are not replayed: the cloned curve is
///      the real one at the seed block.
contract Replay is DemoSeed {
    using StateLibrary for IPoolManager;

    /// @notice Curator strategies. Each starts every epoch on its range around the start TWAP tick.
    /// - Tight: ±200 ticks; never rebalances.
    /// - Recentering: ±300 ticks; when the spot tick leaves the inner ±150 band around the range's centre, it
    ///   rebalances to ±300 around that tick, once the 1-hour cooldown has passed. The check runs at the end of every
    ///   block with a replayed swap; the rebalance lands in the next block, at its slot time (12 s after that swap,
    ///   never after the next recorded swap), before the epoch end.
    /// - Wide: ±3,000 ticks; never rebalances (close to the benchmark).
    enum Strategy {
        Tight,
        Recentering,
        Wide
    }

    /// @notice One hourly sample of the live mark.
    struct Sample {
        uint256 t;
        uint160 sqrtPriceX96;
        uint256 navLive;
        uint256 benchLive;
    }

    /// @notice The window's recorded swaps (parallel arrays, in order), held in memory; `[begin, end)` are the ones
    ///         replayed (after the seed block, up to the window end).
    struct Swaps {
        uint256[] prices;
        int256[] amounts0;
        int256[] amounts1;
        uint256[] blocks;
        uint256[] timestamps;
        uint256 begin;
        uint256 end;
    }

    string internal constant DEFAULT_WINDOW = "2026-11-08_2026-11-15";
    uint256 internal constant SAMPLE_INTERVAL = 1 hours;
    /// @dev Ethereum's slot time: the block after a swap's block is 12 s later.
    uint256 internal constant SLOT = 12 seconds;
    /// @dev Recentering's inner band, in ticks from the range's centre.
    int24 internal constant RECENTRE_BAND = 150;

    address internal trader = makeAddr("trader");
    address internal keeper = makeAddr("keeper");

    /// @notice The window name, the flow model, and the last replayed second.
    string public window;
    bool public amountMode;
    uint256 public windowEnd;

    // One run.
    /// @notice The strategy of the current or last run.
    Strategy public strategy;
    /// @notice Index of the next swap to replay, recorded prices not reached (price mode), and bond posted (seed
    ///         + top-ups).
    uint256 public cursor;
    uint256 public priceMisses;
    uint256 public bondPosted;
    /// @notice The centre of the curator's current range.
    int24 public centre;
    uint256 internal nextSample;
    uint256[] internal rebalanceTimes;
    Sample[] internal series;
    IOathVault.EpochResult[] internal epochs;

    /// @notice `MODE` is neither `price` nor `amount`.
    error UnknownMode(string mode);
    /// @notice `STRATEGY` is neither `all` nor a strategy name.
    error UnknownStrategy(string name);
    /// @notice The swaps file does not start at the seed block, or holds no swap after it.
    error SwapsMismatch();
    /// @notice Price mode left recorded prices unreached.
    error PricesMissed(uint256 misses);
    /// @notice The vault's start tick or start NAV differs from the curator's prediction.
    error StartMismatch(int24 predictedTick, int24 tick, uint256 predictedNav, uint256 nav);
    /// @notice `settle` did not emit exactly one `Settled` event.
    error SettledEvents(uint256 count);
    /// @notice An action was scheduled before the current time.
    error TimeWentBack(uint256 t, uint256 current);

    /// @notice Seeds once, then runs each selected strategy from the same seeded state and writes its results.
    function run() external {
        string memory mode = vm.envOr("MODE", string("price"));
        string memory only = vm.envOr("STRATEGY", string("all"));
        require(_eq(mode, "price") || _eq(mode, "amount"), UnknownMode(mode));
        Swaps memory sw = _prepare(
            vm.envOr("WINDOW", string(DEFAULT_WINDOW)),
            vm.envOr("LAYOUT", string(DEFAULT_LAYOUT)),
            _eq(mode, "amount"),
            type(uint256).max
        );
        uint256 seeded = vm.snapshotState();
        bool any;
        for (uint256 i; i <= uint256(type(Strategy).max); ++i) {
            Strategy s = Strategy(i);
            if (!_eq(only, "all") && !_eq(only, _name(s))) continue;
            any = true;
            _run(sw, s);
            _write();
            vm.revertToState(seeded);
        }
        require(any, UnknownStrategy(only));
    }

    /// @notice Seeds, loads the swaps of the first `duration` seconds of `window_` and runs `s`, without writing a
    ///         file. For tests; the results stay readable through the views below.
    /// @param window_ Swaps file name under `demo/swaps/` (without `.json`).
    /// @param layout Layout file, relative to the project root.
    /// @param s The strategy.
    /// @param amount Amount mode instead of price mode.
    /// @param duration Seconds of the window to replay from the seed time.
    function simulate(string calldata window_, string calldata layout, Strategy s, bool amount, uint256 duration)
        external
    {
        _run(_prepare(window_, layout, amount, duration), s);
    }

    // ---------------------------------------------------------------- views

    /// @notice Number of settled epochs in the last run.
    function epochCount() external view returns (uint256) {
        return epochs.length;
    }

    /// @notice The `Settled` result of epoch `i` in the last run.
    function epoch(uint256 i) external view returns (IOathVault.EpochResult memory) {
        return epochs[i];
    }

    /// @notice Number of rebalances in the last run.
    function rebalanceCount() external view returns (uint256) {
        return rebalanceTimes.length;
    }

    /// @notice The time of rebalance `i` in the last run.
    function rebalanceTime(uint256 i) external view returns (uint256) {
        return rebalanceTimes[i];
    }

    /// @notice Number of hourly samples in the last run.
    function sampleCount() external view returns (uint256) {
        return series.length;
    }

    /// @notice Hourly sample `i` of the last run.
    function sample(uint256 i) external view returns (Sample memory) {
        return series[i];
    }

    /// @notice The last run's results file (see the contract notice). USD values have 2 decimals.
    function json() public view returns (string memory) {
        IOathVault.VaultParams memory p = vault.params();
        return string.concat(
            '{"window":"',
            window,
            '","strategy":"',
            _name(strategy),
            '","mode":"',
            amountMode ? "amount" : "price",
            '","params":{"epochDuration":',
            vm.toString(uint256(p.epochDuration)),
            ',"bandBps":',
            vm.toString(uint256(p.bandBps)),
            ',"perfFeeBps":',
            vm.toString(uint256(p.perfFeeBps)),
            ',"capBps":',
            vm.toString(uint256(p.capBps)),
            '},"series":[',
            _seriesJson(),
            '],"epochs":[',
            _epochsJson(),
            '],"totals":',
            _totalsJson(),
            "}"
        );
    }

    // ---------------------------------------------------------------- run

    function _prepare(string memory window_, string memory layout, bool amount, uint256 duration)
        internal
        returns (Swaps memory sw)
    {
        _seed(layout);
        window = window_;
        amountMode = amount;
        sw = _loadSwaps(duration);
        _fundAndApprove(trader, 100_000_000 ether, 1e17, address(swapRouter)); // 100M ETH, 100B USDC
    }

    /// @dev The swaps of `window` after the seed block, up to `duration` seconds after the seed time. The window ends
    ///      there, or at the file's last swap if that is earlier.
    function _loadSwaps(uint256 duration) private returns (Swaps memory sw) {
        string memory file = vm.readFile(string.concat(vm.projectRoot(), "/demo/swaps/", window, ".json"));
        require(vm.parseJsonUint(file, ".fromBlock") == seedBlock, SwapsMismatch());
        sw.prices = vm.parseJsonUintArray(file, ".sqrtPriceX96");
        sw.amounts0 = vm.parseJsonIntArray(file, ".amount0");
        sw.amounts1 = vm.parseJsonIntArray(file, ".amount1");
        sw.blocks = vm.parseJsonUintArray(file, ".blocks");
        sw.timestamps = vm.parseJsonUintArray(file, ".timestamps");
        uint256 n = sw.timestamps.length;
        uint256 until = duration == type(uint256).max ? duration : createdAt + duration;
        while (sw.begin < n && sw.blocks[sw.begin] <= seedBlock) ++sw.begin; // already in the forked state
        sw.end = sw.begin;
        while (sw.end < n && sw.timestamps[sw.end] <= until) ++sw.end;
        require(sw.end > sw.begin, SwapsMismatch());
        windowEnd = until < sw.timestamps[n - 1] ? until : sw.timestamps[n - 1];
    }

    /// @dev One strategy over the whole window, from the seeded state.
    function _run(Swaps memory sw, Strategy s) internal {
        vm.roll(seedBlock);
        vm.warp(createdAt);
        delete series;
        delete epochs;
        delete rebalanceTimes;
        (strategy, cursor, priceMisses, nextSample, bondPosted, centre) =
        (s, sw.begin, 0, createdAt, vault.bondBalance(), 0);

        IOathVault.VaultParams memory p = vault.params();
        while (true) {
            uint256 start = uint256(vault.openSince()) + p.twapWindow;
            uint256 end = start + p.epochDuration;
            if (end > windowEnd) break;
            _advance(sw, start);
            _act(sw, start);
            _startEpoch();
            _advance(sw, end);
            _act(sw, end);
            _settle();
        }
        _advance(sw, windowEnd);
        _samplesUpTo(windowEnd);
        require(amountMode || priceMisses == 0, PricesMissed(priceMisses));
        _log(cursor - sw.begin);
    }

    /// @dev Replays every swap with timestamp ≤ `t`, sampling before each.
    function _advance(Swaps memory sw, uint256 t) internal {
        while (cursor < sw.end && sw.timestamps[cursor] <= t) {
            _samplesUpTo(sw.timestamps[cursor]);
            _replaySwap(sw, cursor);
            ++cursor;
            if (strategy == Strategy.Recentering) _maybeRecentre(sw);
        }
    }

    /// @dev Moves to time `t` in the block after the last replayed swap (or stays in the current block if an
    ///      earlier action already moved past it), after taking the samples due up to `t`.
    function _act(Swaps memory sw, uint256 t) internal {
        _samplesUpTo(t);
        uint256 b = (cursor == sw.begin ? seedBlock : sw.blocks[cursor - 1]) + 1;
        if (vm.getBlockNumber() > b) b = vm.getBlockNumber();
        require(t >= vm.getBlockTimestamp(), TimeWentBack(t, vm.getBlockTimestamp()));
        vm.roll(b);
        vm.warp(t);
    }

    /// @dev Swap `i` at its real block and time, price- or amount-anchored, by the trader.
    function _replaySwap(Swaps memory sw, uint256 i) internal {
        vm.roll(sw.blocks[i]);
        vm.warp(sw.timestamps[i]);
        if (amountMode) {
            bool zeroForOne = sw.amounts0[i] < 0;
            int256 amountIn = zeroForOne ? sw.amounts0[i] : sw.amounts1[i]; // negative: what the swapper paid in
            vm.prank(trader);
            swapRouter.swap{value: zeroForOne ? uint256(-amountIn) : 0}(
                key,
                SwapParams(
                    zeroForOne, amountIn, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                PoolSwapTest.TestSettings(false, false),
                ""
            );
            return;
        }
        (uint160 current,,,) = MANAGER.getSlot0(id);
        uint160 target = uint160(sw.prices[i]);
        if (current == target) return;
        bool down = target < current;
        // 10M ETH or 10B USDC of exact input: the price limit binds first. The router refunds unused ETH.
        vm.prank(trader);
        swapRouter.swap{value: down ? 10_000_000 ether : 0}(
            key,
            SwapParams(down, down ? -int256(10_000_000 ether) : -int256(1e16), target),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        (current,,,) = MANAGER.getSlot0(id);
        if (current != target) ++priceMisses;
    }

    /// @dev Takes every hourly sample at or before `x` (and within the window) not yet taken.
    function _samplesUpTo(uint256 x) internal {
        while (nextSample <= x && nextSample <= windowEnd) {
            (uint160 sqrtPriceX96,,,) = MANAGER.getSlot0(id);
            (uint256 navLive, uint256 benchLive,) = vault.previewLive();
            series.push(Sample(nextSample, sqrtPriceX96, navLive, benchLive));
            nextSample += SAMPLE_INTERVAL;
        }
    }

    // ---------------------------------------------------------------- curator and keeper

    /// @dev Predicts the start tick and NAV as the vault computes them, tops the bond up to the minimum, and starts
    ///      on the strategy's range around the start tick with a ratio swap.
    function _startEpoch() internal {
        uint256 elapsed = vm.getBlockTimestamp() - vault.openSince();
        int24 startTick = DemoLib.twapTick(hook.cumulativeNow(key) - vault.cumAtOpen(), elapsed);
        uint256 navStart = ValuationLib.value(vault.idle0(), vault.idle1(), TickMath.getSqrtPriceAtTick(startTick));
        _topUpBond(navStart);
        (int24 lower, int24 upper) = DemoLib.rangeAround(startTick, _halfWidth(strategy), SPACING);
        DemoCurator.startEpoch(vault, lower, upper);
        centre = lower + _halfWidth(strategy);
        (,,,,, uint256 nav, int24 tick) = vault.benchmark();
        require(tick == startTick && nav == navStart, StartMismatch(startTick, tick, navStart, nav));
    }

    /// @dev The curator posts exactly the shortfall to `minBondBps` of the start NAV, if any.
    function _topUpBond(uint256 navStart) internal {
        uint256 required = FullMath.mulDiv(navStart, vault.params().minBondBps, 10_000);
        uint256 bond = vault.bondBalance();
        if (bond >= required) return;
        uint256 amount = required - bond;
        deal(USDC, curator, IERC20Minimal(USDC).balanceOf(curator) + amount);
        vm.prank(curator);
        vault.postBond(amount);
        bondPosted += amount;
    }

    /// @dev A keeper settles; the result is taken from the `Settled` event.
    function _settle() internal {
        vm.recordLogs();
        vm.prank(keeper);
        vault.settle();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == IOathVault.Settled.selector) {
                epochs.push(abi.decode(logs[i].data, (IOathVault.EpochResult)));
                ++found;
            }
        }
        require(found == 1, SettledEvents(found));
    }

    // ---------------------------------------------------------------- strategies

    /// @dev Recentering, after the last replayed swap: if it ended its block, the epoch is running, the next block's
    ///      slot time is before `E` and past the cooldown, and the spot tick is outside the inner band, rebalance to
    ///      ±300 ticks around that tick with a ratio swap in that next block.
    function _maybeRecentre(Swaps memory sw) internal {
        if (vault.state() != IOathVault.State.ACTIVE) return;
        uint256 last = cursor - 1;
        bool more = cursor < sw.end;
        if (more && sw.blocks[cursor] == sw.blocks[last]) return; // not the block's last swap
        uint256 t = sw.timestamps[last] + SLOT;
        if (more && sw.timestamps[cursor] < t) t = sw.timestamps[cursor];
        if (t >= vault.epochEnd() || t < uint256(vault.lastReposition()) + vault.params().rebalanceCooldown) return;
        (, int24 tick,,) = MANAGER.getSlot0(id);
        if (tick >= centre - RECENTRE_BAND && tick <= centre + RECENTRE_BAND) return;

        _act(sw, t);
        int24 halfWidth = _halfWidth(Strategy.Recentering);
        (int24 lower, int24 upper) = DemoLib.rangeAround(tick, halfWidth, SPACING);
        DemoCurator.rebalance(vault, lower, upper);
        centre = lower + halfWidth;
        rebalanceTimes.push(t);
    }

    function _halfWidth(Strategy s) internal pure returns (int24) {
        if (s == Strategy.Tight) return 200;
        if (s == Strategy.Recentering) return 300;
        return 3_000;
    }

    function _name(Strategy s) internal pure returns (string memory) {
        if (s == Strategy.Tight) return "tight";
        if (s == Strategy.Recentering) return "recentering";
        return "wide";
    }

    // ---------------------------------------------------------------- output

    function _write() internal {
        string memory dir = string.concat(vm.projectRoot(), "/demo/results");
        string memory path = string.concat(dir, "/", window, "_", _name(strategy), amountMode ? "_amount" : "", ".json");
        vm.createDir(dir, true);
        vm.writeFile(path, json());
        console2.log("Wrote", path);
    }

    function _seriesJson() private view returns (string memory out) {
        for (uint256 i; i < series.length; ++i) {
            Sample memory s = series[i];
            out = string.concat(
                out,
                i == 0 ? "" : ",",
                '{"t":',
                vm.toString(s.t),
                ',"price":',
                DemoLib.usd(DemoLib.price(s.sqrtPriceX96)),
                ',"navLive":',
                DemoLib.usd(s.navLive),
                ',"benchLive":',
                DemoLib.usd(s.benchLive),
                "}"
            );
        }
    }

    function _epochsJson() private view returns (string memory out) {
        for (uint256 i; i < epochs.length; ++i) {
            IOathVault.EpochResult memory r = epochs[i];
            out = string.concat(
                out,
                i == 0 ? "" : ",",
                string.concat(
                    '{"index":',
                    vm.toString(i),
                    ',"start":',
                    vm.toString(uint256(r.start)),
                    ',"end":',
                    vm.toString(uint256(r.end)),
                    ',"startPrice":',
                    DemoLib.usd(DemoLib.price(TickMath.getSqrtPriceAtTick(r.startTick))),
                    ',"endPrice":',
                    DemoLib.usd(DemoLib.price(TickMath.getSqrtPriceAtTick(r.endTick)))
                ),
                string.concat(
                    ',"navEnd":',
                    DemoLib.usd(r.navEnd),
                    ',"benchEnd":',
                    DemoLib.usd(r.benchEnd),
                    ',"diff":',
                    DemoLib.usdSigned(r.diff),
                    ',"band":',
                    DemoLib.usd(r.band),
                    ',"payout":',
                    DemoLib.usd(r.payout),
                    ',"fee":',
                    DemoLib.usd(r.fee),
                    ',"bondAfter":',
                    DemoLib.usd(r.bondAfter),
                    "}"
                )
            );
        }
    }

    /// @dev Sums of payouts and fees; the last epoch's NAV and benchmark; HODL = the seed deposit at the last
    ///      epoch's end TWAP price (the same mark).
    function _totalsJson() private view returns (string memory) {
        (uint256 payouts, uint256 fees, uint256 navEnd, uint256 benchEnd, uint256 hodlEnd) = _totals();
        return string.concat(
            '{"payouts":',
            DemoLib.usd(payouts),
            ',"fees":',
            DemoLib.usd(fees),
            ',"bondPosted":',
            DemoLib.usd(bondPosted),
            ',"navEnd":',
            DemoLib.usd(navEnd),
            ',"benchEnd":',
            DemoLib.usd(benchEnd),
            ',"hodlEnd":',
            DemoLib.usd(hodlEnd),
            "}"
        );
    }

    function _totals()
        private
        view
        returns (uint256 payouts, uint256 fees, uint256 navEnd, uint256 benchEnd, uint256 hodlEnd)
    {
        for (uint256 i; i < epochs.length; ++i) {
            payouts += epochs[i].payout;
            fees += epochs[i].fee;
        }
        if (epochs.length == 0) return (0, 0, 0, 0, 0);
        IOathVault.EpochResult memory last = epochs[epochs.length - 1];
        hodlEnd = ValuationLib.value(deposit0, deposit1, TickMath.getSqrtPriceAtTick(last.endTick));
        return (payouts, fees, last.navEnd, last.benchEnd, hodlEnd);
    }

    function _log(uint256 replayed) internal view {
        (uint256 payouts, uint256 fees, uint256 navEnd, uint256 benchEnd,) = _totals();
        uint256[3] memory outcomes; // lost, inside the band, won
        for (uint256 i; i < epochs.length; ++i) {
            ++outcomes[epochs[i].payout > 0 ? 0 : epochs[i].fee > 0 ? 2 : 1];
        }
        console2.log(string.concat("== ", _name(strategy), amountMode ? " (amount mode)" : " (price mode)"));
        console2.log("  swaps replayed / price misses", replayed, priceMisses);
        console2.log("  epochs lost / inside band / won", outcomes[0], outcomes[1], outcomes[2]);
        console2.log("  rebalances", rebalanceTimes.length);
        console2.log(string.concat("  payouts $", DemoLib.usd(payouts), "  fees $", DemoLib.usd(fees)));
        console2.log(string.concat("  bond posted $", DemoLib.usd(bondPosted)));
        console2.log(string.concat("  last navEnd $", DemoLib.usd(navEnd), "  benchEnd $", DemoLib.usd(benchEnd)));
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
