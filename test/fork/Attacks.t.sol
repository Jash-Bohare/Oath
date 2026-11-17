// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {ValuationLib} from "../../src/libraries/ValuationLib.sol";
import {OathForkBase} from "./OathForkBase.sol";

/// @notice Attacks on the measurement, quantified on an Oath pool at B0 with the real ETH/USDC liquidity curve, the
///         $30,000 worked-example vault and its $3,000 bond. Each attack is run against the same epoch without it
///         (two worlds from one snapshot) and settled at `E`.
///         - Wash trading: the curator trades back and forth through its own range to earn the vault fees. The
///           benchmark earns from the same fee growth, the curator pays every fee in full but gets back only the
///           vault's share, and the performance fee is 20% of the excess beyond the band: always a net loss.
///         - Donation griefing: an attacker donates to the pool while the curator's range is out of range, so the
///           benchmark earns fees the vault does not, to trigger a bond payout. The benchmark's share of a donation
///           is `L_b / activeLiquidity` (≤ 0.25% by the cap), so depositors gain at most a sliver of what the
///           attacker gives away to the pool's other LPs.
contract AttacksForkTest is OathForkBase {
    using StateLibrary for IPoolManager;

    PoolDonateTest internal donateRouter;
    uint256 internal start;
    int24 internal startTick;

    function setUp() public {
        _setUpOath(0); // no recorded flow: the attacks are the only activity besides the moves they choose
        donateRouter = new PoolDonateTest(MANAGER);
        vm.deal(address(donateRouter), 0);
        IERC20Minimal(USDC).approve(address(donateRouter), type(uint256).max);
        start = createdAt + TWAP_WINDOW;
        _actAt(start);
        (, startTick,,) = MANAGER.getSlot0(id); // no swaps: the open-window TWAP is the B0 tick
    }

    // ---------------------------------------------------------------- T5 wash trading

    /// @dev For any wash volume (1–20 round trips of 1–500 ETH) and any market move during the epoch (±400 ticks,
    ///      inside or out of the curator's ±200-tick range), what the curator gains through the settlement (the
    ///      performance fee, plus any bond it no longer pays out) is less than what the round trips cost it.
    /// forge-config: default.fuzz.runs = 32
    function testFuzz_washTrading_unprofitable(uint256 tripsSeed, uint256 sizeSeed, int256 moveSeed) public {
        uint256 trips = bound(tripsSeed, 1, 20);
        uint256 size = bound(sizeSeed, 1 ether, 500 ether);
        int24 move = int24(bound(moveSeed, -400, 400));
        (int256 gain, uint256 cost) = _washTrading(trips, size, move);
        assertLt(gain, int256(cost), "curator net P&L from wash trading < 0");
    }

    /// @dev Wash trading that stays inside the curator's range (20 round trips of 50 ETH, no market move) does lift
    ///      the vault past the band and earns the curator a performance fee, yet the fee is a small fraction of
    ///      what the round trips cost.
    function test_washTrading_unprofitable() public {
        (int256 gain, uint256 cost) = _washTrading(20, 50 ether, 0);
        assertGt(gain, 0, "the wash earned the curator a performance fee");
        assertLt(gain, int256(cost), "curator net P&L from wash trading < 0");
        console2.log("T5 curator gain / wash cost (USDC units)", uint256(gain), cost);
    }

    /// @dev Runs the epoch with and without the wash (two worlds from one snapshot) and returns the curator's gain
    ///      through the settlement (extra fee plus bond kept, signed) and the wash's cost.
    function _washTrading(uint256 trips, uint256 size, int24 move) internal returns (int256 gain, uint256 cost) {
        _start(_onSpacing(startTick) - 200, _onSpacing(startTick) + 200);
        uint256 snapshot = vm.snapshotState();
        (IOathVault.EpochResult memory honest,) = _epoch(move, 0, 0);
        vm.revertToState(snapshot);
        IOathVault.EpochResult memory washed;
        (washed, cost) = _epoch(move, trips, size);
        gain = int256(washed.fee) - int256(honest.fee) + int256(washed.bondAfter) - int256(honest.bondAfter);
        assertGt(cost, 0, "wash trading costs the curator");
    }

    // ---------------------------------------------------------------- T6 donation griefing

    /// @dev For any donation while the curator is out of range (up to 2,000 ETH and $5M), the donation costs the
    ///      attacker at least 100× what depositors gain from the extra bond payout it causes.
    /// forge-config: default.fuzz.runs = 32
    function testFuzz_donationGriefing_unprofitable(uint256 ethSeed, uint256 usdcSeed) public {
        uint256 amount0 = bound(ethSeed, 0, 2_000 ether);
        uint256 amount1 = bound(usdcSeed, 0, 5_000_000e6);
        vm.assume(amount0 + amount1 > 0);
        (uint256 cost, uint256 benefit) = _donationGriefing(amount0, amount1);
        assertGe(cost, 100 * benefit, "donation costs >= 100x the depositors' gain");
    }

    /// @dev A donation large enough to matter: 1,000 ETH (about $2.2M) does trigger a payout, and still costs the
    ///      attacker far more than 100× what depositors receive.
    function test_donationGriefing_unprofitable() public {
        (uint256 cost, uint256 benefit) = _donationGriefing(1_000 ether, 0);
        assertGt(benefit, 0, "the donation moved the bond");
        assertGe(cost, 100 * benefit, "donation costs >= 100x the depositors' gain");
        console2.log("T6 donation cost / depositors' gain (USDC units)", cost, benefit);
        console2.log("T6 cost / gain", cost / benefit);
    }

    /// @dev The curator sits out of range (all currency0, 1,000–1,400 ticks above the price) for the whole epoch.
    ///      Returns the donation's value at the end price and the extra payout it caused.
    function _donationGriefing(uint256 amount0, uint256 amount1) internal returns (uint256 cost, uint256 benefit) {
        _start(_onSpacing(startTick) + 1_000, _onSpacing(startTick) + 1_400);
        uint256 snapshot = vm.snapshotState();
        (IOathVault.EpochResult memory honest,) = _epoch(0, 0, 0);
        vm.revertToState(snapshot);

        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(start + 1 hours);
        donateRouter.donate{value: amount0}(key, amount0, amount1, "");
        (IOathVault.EpochResult memory donated,) = _epoch(0, 0, 0);

        cost = ValuationLib.value(amount0, amount1, TickMath.getSqrtPriceAtTick(donated.endTick));
        benefit = donated.payout - honest.payout;
        assertEq(donated.endTick, honest.endTick, "a donation does not move the price");
        assertGe(donated.payout, honest.payout, "a donation can only raise the payout");
    }

    // ---------------------------------------------------------------- epoch helpers

    function _start(int24 lower, int24 upper) internal {
        vm.prank(curator);
        vault.startEpoch(lower, upper, IOathVault.SwapIntent(false, 0, 0));
    }

    /// @dev The rest of the epoch: an optional market move of `move` ticks two hours in (held to `E`), optional
    ///      wash trading by the curator's own wallet (this contract) three hours in, then settlement at `E`.
    ///      Returns the result and the wash's cost: the ETH lost over the round trips, valued at the end price.
    function _epoch(int24 move, uint256 trips, uint256 size)
        internal
        returns (IOathVault.EpochResult memory r, uint256 washCost)
    {
        if (move != 0) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(start + 2 hours);
            _swapToTick(startTick + move);
        }
        uint256 ethLost;
        if (trips > 0) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(start + 3 hours);
            (uint256 ethBefore, uint256 usdcBefore) = _balances();
            for (uint256 i; i < trips; ++i) {
                _swapExactIn(true, size);
                (, uint256 usdcNow) = _balances();
                _swapExactIn(false, usdcNow - usdcBefore);
            }
            (uint256 ethAfter, uint256 usdcAfter) = _balances();
            assertEq(usdcAfter, usdcBefore, "round trips end with the same USDC");
            ethLost = ethBefore - ethAfter;
        }
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vault.epochEnd());
        vm.prank(keeper);
        vault.settle();
        r = vault.getResult(vault.epochCount() - 1);
        washCost = ValuationLib.value(ethLost, 0, TickMath.getSqrtPriceAtTick(r.endTick));
    }

    function _swapExactIn(bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swap{value: zeroForOne ? amountIn : 0}(
            key,
            SwapParams(
                zeroForOne, -int256(amountIn), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _swapToTick(int24 tick) internal {
        (uint160 current,,,) = MANAGER.getSlot0(id);
        uint160 target = TickMath.getSqrtPriceAtTick(tick);
        bool zeroForOne = target < current;
        swapRouter.swap{value: zeroForOne ? 10_000_000 ether : 0}(
            key,
            SwapParams(zeroForOne, zeroForOne ? -int256(10_000_000 ether) : -int256(1e16), target),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    /// @dev `tick` rounded down to the tick spacing.
    function _onSpacing(int24 tick) internal pure returns (int24 c) {
        c = tick / SPACING * SPACING;
        if (tick < 0 && tick % SPACING != 0) c -= SPACING;
    }
}
