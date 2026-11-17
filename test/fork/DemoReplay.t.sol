// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {ValuationLib} from "../../src/libraries/ValuationLib.sol";
import {OathVault} from "../../src/OathVault.sol";
import {DemoLib} from "../../script/demo/DemoLib.sol";
import {Replay} from "../../script/demo/Replay.s.sol";

/// @notice The demo replay script on mainnet: the first epoch of the Nov 8–15 2026 window (30-minute open window,
///         1-day epoch) with each flow model. The recorded results must be exactly what the vault stored and
///         emitted, the series must sample every hour, and the results file must carry the same numbers.
/// @dev Not isolated: the script runs as one call, which isolation would cap at the block gas limit.
/// forge-config: default.isolate = false
contract DemoReplayForkTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager internal constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    string internal constant WINDOW = "2026-11-08_2026-11-15";
    string internal constant LAYOUT = "demo/layout_B0.json";
    uint256 internal constant ONE_EPOCH = 30 minutes + 1 days;

    Replay internal replay;

    function setUp() public {
        vm.skip(block.chainid != 1, "fork test: run with --fork-url $ETH_RPC_URL");
        replay = new Replay();
        vm.makePersistent(address(replay)); // the script forks mainnet at the layout's block itself
    }

    function test_replay_tightPriceAnchored() public {
        replay.simulate(WINDOW, LAYOUT, Replay.Strategy.Tight, false, ONE_EPOCH);
        OathVault vault = replay.vault();
        assertEq(replay.priceMisses(), 0, "every recorded price reached");
        assertGt(replay.cursor(), 1_000, "over a thousand real swaps");
        _assertOneEpoch(vault);

        // The epoch's range: ±200 ticks around the start TWAP tick.
        IOathVault.EpochResult memory r = replay.epoch(0);
        (int24 lower, int24 upper) = DemoLib.rangeAround(r.startTick, 200, 10);
        (int24 l, int24 u,) = vault.positionInfo();
        assertEq(l, lower, "Tight range lower");
        assertEq(u, upper, "Tight range upper");

        // Price mode leaves the Oath pool at the last recorded price of the replayed span.
        (uint160 sqrtPriceX96,,,) = MANAGER.getSlot0(vault.poolId());
        assertEq(sqrtPriceX96, _lastRecordedPrice(replay.createdAt() + ONE_EPOCH), "at the market price");
    }

    function _lastRecordedPrice(uint256 until) internal view returns (uint256 price) {
        string memory file = vm.readFile(string.concat(vm.projectRoot(), "/demo/swaps/", WINDOW, ".json"));
        uint256[] memory prices = vm.parseJsonUintArray(file, ".sqrtPriceX96");
        uint256[] memory timestamps = vm.parseJsonUintArray(file, ".timestamps");
        for (uint256 i; i < timestamps.length && timestamps[i] <= until; ++i) {
            price = prices[i];
        }
    }

    function test_replay_tightAmountAnchored() public {
        replay.simulate(WINDOW, LAYOUT, Replay.Strategy.Tight, true, ONE_EPOCH);
        assertTrue(replay.amountMode());
        _assertOneEpoch(replay.vault());
    }

    /// @dev One settled epoch whose recorded result is the vault's stored result; the bond reconciles; hourly
    ///      samples from the seed time; and the JSON carries the same numbers.
    function _assertOneEpoch(OathVault vault) internal view {
        assertEq(replay.epochCount(), 1, "one epoch fits the window");
        assertEq(vault.epochCount(), 1);
        IOathVault.EpochResult memory r = replay.epoch(0);
        assertEq(abi.encode(r), abi.encode(vault.getResult(0)), "Settled event = stored result");
        assertEq(r.start, replay.createdAt() + 30 minutes, "start after the open window");
        assertEq(r.end, uint256(r.start) + 1 days);
        assertEq(uint8(vault.state()), uint8(IOathVault.State.OPEN), "settled and reopened");
        assertEq(vault.bondBalance(), r.bondAfter, "bond after the epoch");
        assertEq(replay.bondPosted() - r.payout, r.bondAfter, "bond posted - payouts = bond");
        assertGe(replay.bondPosted(), 1_500e6, "seed bond plus any top-up");
        assertGe(r.bondAfter + r.payout, r.navStart / 10, "bond at the start >= 10% of the start NAV");

        // Hourly samples over [seed time, window end]: 25 for 24.5 hours.
        assertEq(replay.sampleCount(), 25, "hourly samples");
        assertEq(replay.windowEnd(), replay.createdAt() + ONE_EPOCH);
        Replay.Sample memory first = replay.sample(0);
        assertEq(first.t, replay.createdAt());
        assertEq(first.sqrtPriceX96, replay.sqrtStart(), "first sample before any swap");
        assertEq(first.navLive, 15_000e6, "seeded value");
        assertEq(first.benchLive, first.navLive, "no epoch yet: benchmark = NAV");
        for (uint256 i = 1; i < 25; ++i) {
            assertEq(replay.sample(i).t, replay.createdAt() + i * 1 hours);
        }

        string memory json = replay.json();
        assertEq(vm.parseJsonString(json, ".window"), WINDOW);
        assertEq(vm.parseJsonString(json, ".strategy"), "tight");
        assertEq(vm.parseJsonString(json, ".mode"), replay.amountMode() ? "amount" : "price");
        assertEq(vm.parseJsonUint(json, ".params.epochDuration"), 1 days);
        assertEq(vm.parseJsonUint(json, ".params.bandBps"), 35);
        assertEq(vm.parseJsonUint(json, ".params.perfFeeBps"), 2_000);
        assertEq(vm.parseJsonUint(json, ".params.capBps"), 25);
        assertEq(vm.parseJsonUint(json, ".epochs[0].index"), 0);
        assertEq(vm.parseJsonUint(json, ".epochs[0].start"), r.start);
        assertEq(vm.parseJsonUint(json, ".epochs[0].end"), r.end);
        assertFalse(vm.keyExistsJson(json, ".epochs[1]"), "one epoch");
        assertEq(vm.parseJsonUint(json, ".series[24].t"), replay.createdAt() + 24 hours);
        assertFalse(vm.keyExistsJson(json, ".series[25]"), "25 samples");
        // USD values (2 decimals) are checked as the exact strings DemoLib formats.
        assertTrue(_contains(json, string.concat('"navEnd":', DemoLib.usd(r.navEnd), ",")), "navEnd");
        assertTrue(_contains(json, string.concat('"benchEnd":', DemoLib.usd(r.benchEnd), ",")), "benchEnd");
        assertTrue(_contains(json, string.concat('"diff":', DemoLib.usdSigned(r.diff), ",")), "diff");
        assertTrue(_contains(json, string.concat('"payout":', DemoLib.usd(r.payout), ",")), "payout");
        assertTrue(_contains(json, string.concat('"bondAfter":', DemoLib.usd(r.bondAfter), "}")), "bondAfter");
        string memory startPrice = DemoLib.usd(DemoLib.price(TickMath.getSqrtPriceAtTick(r.startTick)));
        assertTrue(_contains(json, string.concat('"startPrice":', startPrice, ",")), "startPrice");
        uint256 hodl = ValuationLib.value(replay.deposit0(), replay.deposit1(), TickMath.getSqrtPriceAtTick(r.endTick));
        assertTrue(_contains(json, string.concat('"hodlEnd":', DemoLib.usd(hodl), "}")), "hodlEnd");
        assertTrue(_contains(json, string.concat('"bondPosted":', DemoLib.usd(replay.bondPosted()), ",")), "bondPosted");
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        for (uint256 i; i + n.length <= h.length; ++i) {
            bool found = true;
            for (uint256 j; j < n.length && found; ++j) {
                found = h[i + j] == n[j];
            }
            if (found) return true;
        }
        return false;
    }
}
