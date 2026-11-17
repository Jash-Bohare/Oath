// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IOathHook} from "../../../src/interfaces/IOathHook.sol";
import {IOathVault} from "../../../src/interfaces/IOathVault.sol";
import {ValuationLib} from "../../../src/libraries/ValuationLib.sol";
import {OathVault} from "../../../src/OathVault.sol";

/// @title OathHandler
/// @notice Drives random sequences of every Oath action for the invariant suite: depositors deposit and withdraw,
///         the curator posts and withdraws bond, starts epochs and rebalances, a keeper settles, and the outside
///         world swaps, donates, adds and removes liquidity, transfers tokens to the vault, pokes the hook, refreshes
///         the open window and lets time pass (0–2 days per step).
/// @dev Runs with `fail_on_revert = true`. Outside-world pool actions are never wrapped in try/catch, so a hook revert
///      on a swap, donation or liquidity change by anyone other than the vault fails the run (I5). Vault actions
///      tolerate only the errors their precondition cannot rule out; any other revert is re-thrown and fails the run.
///      Ghost state records what the invariants compare against:
///      - a brute-force Σ tick·dt, accrued before every time step and every price change (I6);
///      - shares minted by deposits and settlements and burned by withdrawals (I3);
///      - whether any outside-world action in OPEN lowered a depositor's redeemable amounts (I4);
///      - whether settling with and without extra swaps after `E` gave different results (I7).
///      Outside-world swaps keep the price within ±2,000 ticks of the start tick, and deposits keep the vault
///      small enough for the 0.25% cap, so epochs actually start and settle.
contract OathHandler is Test {
    using StateLibrary for IPoolManager;

    /// @dev An outside-world liquidity position (owned by the liquidity router under its own salt).
    struct Lp {
        int24 lower;
        int24 upper;
        uint128 liquidity;
        bytes32 salt;
    }

    int24 internal constant START_TICK = -199196;
    int24 internal constant SPACING = 10;
    /// @dev The outside world keeps the price within this many ticks of the start tick.
    int24 internal constant PRICE_BAND = 2_000;
    /// @dev Deposits stop once the idle vault is worth this much (raw currency1, $20,000), well inside the cap.
    uint256 internal constant MAX_VAULT_VALUE = 20_000e6;

    OathVault public immutable vault;
    IOathHook public immutable hook;
    IPoolManager public immutable manager;
    PoolSwapTest public immutable swapRouter;
    PoolModifyLiquidityTest public immutable lpRouter;
    PoolDonateTest public immutable donateRouter;
    MockERC20 public immutable token0;
    MockERC20 public immutable token1;
    PoolId public immutable id;
    address public immutable curator;
    address public immutable keeper;
    PoolKey internal key;
    address[3] internal depositors;
    Lp[] internal lps;

    // ---------------------------------------------------------------- ghost state

    /// @notice Brute-force Σ tick·dt since pool creation, up to `ghostLastTime` (I6).
    int256 public ghostCumulative;
    /// @notice Time up to which `ghostCumulative` is accrued.
    uint256 public ghostLastTime;
    /// @notice The tick that has held since `ghostLastTime`.
    int24 public ghostLastTick;
    /// @notice Shares minted by deposits (including the dead shares), burned by withdrawals, and minted as fees (I3).
    uint256 public ghostMinted;
    uint256 public ghostBurned;
    uint256 public ghostFeeShares;
    /// @notice Set if an outside-world action in OPEN lowered a depositor's redeemable amounts (I4).
    bool public i4Violated;
    /// @notice Set if settling with extra swaps after `E` gave a different `EpochResult` than without (I7).
    bool public i7Violated;
    /// @notice Successful actions, to show the suite exercises every path.
    mapping(bytes32 => uint256) public calls;

    constructor(
        OathVault vault_,
        PoolSwapTest swapRouter_,
        PoolModifyLiquidityTest lpRouter_,
        PoolDonateTest donateRouter_,
        address[3] memory depositors_,
        address keeper_
    ) {
        vault = vault_;
        hook = vault_.hook();
        manager = vault_.manager();
        swapRouter = swapRouter_;
        lpRouter = lpRouter_;
        donateRouter = donateRouter_;
        key = vault_.poolKey();
        id = vault_.poolId();
        token0 = MockERC20(Currency.unwrap(key.currency0));
        token1 = MockERC20(Currency.unwrap(key.currency1));
        curator = vault_.curator();
        keeper = keeper_;
        depositors = depositors_;

        // The outside world: effectively unlimited tokens, approved to every router.
        token0.mint(address(this), 1e40);
        token1.mint(address(this), 1e40);
        address[3] memory routers = [address(swapRouter_), address(lpRouter_), address(donateRouter_)];
        for (uint256 i; i < routers.length; ++i) {
            token0.approve(routers[i], type(uint256).max);
            token1.approve(routers[i], type(uint256).max);
        }
        // Depositors and the curator approve the vault once.
        for (uint256 i; i < 4; ++i) {
            address who = i < 3 ? depositors_[i] : curator;
            vm.startPrank(who);
            token0.approve(address(vault_), type(uint256).max);
            token1.approve(address(vault_), type(uint256).max);
            vm.stopPrank();
        }

        // The pool was created at the vault's open-window start with cumulative 0 (MATH.md §4).
        ghostLastTime = vault_.openSince();
        ghostLastTick = _tick();
    }

    // ---------------------------------------------------------------- depositors

    /// @notice A depositor deposits in kind during the open window.
    function deposit(uint256 actorSeed, uint256 amount0, uint256 amount1) external tracked {
        if (!_open()) return;
        if (ValuationLib.value(vault.idle0(), vault.idle1(), _sqrtPrice()) >= MAX_VAULT_VALUE) return;
        address who = depositors[actorSeed % 3];
        amount0 = _bound(amount0, 1e15, 2e18);
        amount1 = _bound(amount1, 1e7, 5_000e6);
        token0.mint(who, amount0);
        token1.mint(who, amount1);
        bool first = vault.totalSupply() == 0;
        vm.prank(who);
        try vault.deposit(amount0, amount1, 0, who) returns (uint256 shares, uint256, uint256) {
            ghostMinted += shares + (first ? vault.MIN_SHARES() : 0);
            ++calls["deposit"];
        } catch (bytes memory err) {
            // A vault holding nothing to price against, or a deposit too small for one share.
            _allow(err, IOathVault.EmptyVault.selector, IOathVault.ZeroShares.selector, bytes4(0));
        }
    }

    /// @notice A depositor withdraws part or all of its shares during the open window.
    function withdraw(uint256 actorSeed, uint256 sharesSeed) external tracked {
        if (!_open()) return;
        address who = depositors[actorSeed % 3];
        uint256 shares = _bound(sharesSeed, 0, vault.balanceOf(who));
        if (shares == 0) return;
        vm.prank(who);
        vault.withdraw(shares, 0, 0, who);
        ghostBurned += shares;
        ++calls["withdraw"];
    }

    // ---------------------------------------------------------------- curator

    /// @notice The curator adds to the bond (any state).
    function postBond(uint256 amount) external tracked {
        amount = _bound(amount, 1, 2_000e6);
        token1.mint(curator, amount);
        vm.prank(curator);
        vault.postBond(amount);
        ++calls["postBond"];
    }

    /// @notice The curator withdraws part of the bond during the open window.
    function withdrawBond(uint256 amount) external tracked {
        if (!_open() || vault.bondBalance() == 0) return;
        amount = _bound(amount, 1, vault.bondBalance());
        vm.prank(curator);
        vault.withdrawBond(amount);
        ++calls["withdrawBond"];
    }

    /// @notice The curator starts an epoch on a range around the current price, with an optional small swap. The
    ///         handler first waits for a valid open window (refreshing an expired one) and usually tops the bond up
    ///         to the minimum, so most starts succeed.
    function startEpoch(uint256 widthSeed, uint256 swapSeed, uint256 waitSeed) external tracked {
        if (!_open()) return;
        IOathVault.VaultParams memory p = vault.params();
        if (_now() - vault.openSince() > p.maxOpen) vault.refreshOpenWindow();
        uint256 earliest = vault.openSince() + p.twapWindow;
        uint256 target = earliest + _bound(waitSeed, 0, p.maxOpen - p.twapWindow);
        if (_now() < earliest) _warpTo(target);
        _nextBlock();

        if (swapSeed % 5 != 0) _topUpBond(); // one start in five keeps the bond as it is
        (int24 lower, int24 upper) = _rangeAroundPrice(widthSeed);
        IOathVault.SwapIntent memory intent = _smallSwap(swapSeed, vault.idle0(), vault.idle1());

        vm.prank(curator);
        try vault.startEpoch(lower, upper, intent) {
            ++calls["startEpoch"];
        } catch (bytes memory err) {
            _allow(
                err, IOathVault.EmptyVault.selector, IOathVault.VaultTooLarge.selector, IOathVault.BondTooSmall.selector
            );
        }
    }

    /// @notice The curator rebalances to a range around the current price, with an optional small swap, once the
    ///         cooldown allows and before `E`. Must not revert.
    function rebalance(uint256 widthSeed, uint256 swapSeed) external tracked {
        if (vault.state() != IOathVault.State.ACTIVE) return;
        uint256 end = vault.epochEnd();
        uint256 ready = uint256(vault.lastReposition()) + vault.params().rebalanceCooldown;
        if (ready >= end || _now() >= end) return;
        if (_now() < ready) _warpTo(ready);
        _nextBlock();

        (int24 oldLower, int24 oldUpper, uint128 liquidity) = vault.positionInfo();
        (uint256 p0, uint256 p1) = ValuationLib.principal(liquidity, oldLower, oldUpper, _sqrtPrice());
        (int24 lower, int24 upper) = _rangeAroundPrice(widthSeed);
        IOathVault.SwapIntent memory intent = _smallSwap(swapSeed, vault.idle0() + p0, vault.idle1() + p1);

        vm.prank(curator);
        vault.rebalance(lower, upper, intent);
        ++calls["rebalance"];
    }

    // ---------------------------------------------------------------- settlement

    /// @notice A keeper settles once `E` has passed (waiting for it if needed). Checks I7 on the way: the same
    ///         state is settled twice, once directly and once after 1–3 outside-world swaps in later blocks, and the
    ///         two `EpochResult`s must be identical. The second path is the one kept.
    function settle(uint256 waitSeed, uint256 swapSeed) external tracked {
        if (vault.state() != IOathVault.State.ACTIVE) return;
        uint256 settleAt = uint256(vault.epochEnd()) + _bound(waitSeed, 0, 2 hours);
        if (_now() < settleAt) _warpTo(settleAt);
        _nextBlock();
        uint256 epoch = vault.epochCount();

        uint256 snapshot = vm.snapshotState();
        vm.prank(keeper);
        vault.settle();
        IOathVault.EpochResult memory direct = vault.getResult(epoch);
        vm.revertToStateAndDelete(snapshot);

        uint256 extraSwaps = 1 + swapSeed % 3;
        for (uint256 i; i < extraSwaps; ++i) {
            _nextBlock();
            _warpTo(_now() + 12 + _bound(uint256(keccak256(abi.encode(swapSeed, i))), 0, 10 minutes));
            _swapTo(_targetTick(uint256(keccak256(abi.encode(swapSeed, i, "tick")))));
        }
        _nextBlock();
        vm.prank(keeper);
        vault.settle();
        IOathVault.EpochResult memory afterSwaps = vault.getResult(epoch);

        if (keccak256(abi.encode(direct)) != keccak256(abi.encode(afterSwaps))) i7Violated = true;
        ghostFeeShares += afterSwaps.feeShares;
        ++calls["settle"];
        if (afterSwaps.payout > 0) ++calls["settle:payout"];
        if (afterSwaps.feeShares > 0) ++calls["settle:fee"];
    }

    // ---------------------------------------------------------------- outside world

    /// @notice Someone swaps the price to a random tick within ±2,000 ticks of the start.
    function swap(uint256 tickSeed) external tracked outsideWorld {
        _swapTo(_targetTick(tickSeed));
        ++calls["swap"];
    }

    /// @notice Someone donates to the pool's in-range liquidity.
    function donate(uint256 amount0, uint256 amount1) external tracked outsideWorld {
        donateRouter.donate(key, _bound(amount0, 1, 1e18), _bound(amount1, 1, 1_000e6), "");
        ++calls["donate"];
    }

    /// @notice Someone adds liquidity on a random range near the start price, under a fresh salt.
    function addLiquidity(uint256 lowerSeed, uint256 widthSeed, uint256 liquiditySeed) external tracked outsideWorld {
        int24 base = (START_TICK - PRICE_BAND) / SPACING * SPACING - SPACING * 100; // on the spacing
        int24 lower = base + int24(int256(_bound(lowerSeed, 0, 500))) * SPACING;
        int24 upper = lower + int24(int256(_bound(widthSeed, 1, 500))) * SPACING;
        uint128 liquidity = uint128(_bound(liquiditySeed, 1e12, 1e16));
        bytes32 salt = bytes32(lps.length + 1);
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), salt), "");
        lps.push(Lp(lower, upper, liquidity, salt));
        ++calls["addLiquidity"];
    }

    /// @notice Someone removes one of the outside-world positions in full.
    function removeLiquidity(uint256 indexSeed) external tracked outsideWorld {
        if (lps.length == 0) return;
        uint256 i = indexSeed % lps.length;
        Lp memory lp = lps[i];
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams(lp.lower, lp.upper, -int256(uint256(lp.liquidity)), lp.salt), ""
        );
        lps[i] = lps[lps.length - 1];
        lps.pop();
        ++calls["removeLiquidity"];
    }

    /// @notice Someone sends tokens straight to the vault (not a deposit).
    function transferToVault(bool currency0, uint256 amount) external tracked outsideWorld {
        if (currency0) token0.transfer(address(vault), _bound(amount, 1, 1e17));
        else token1.transfer(address(vault), _bound(amount, 1, 100e6));
        ++calls["transferToVault"];
    }

    /// @notice Someone pokes the hook.
    function poke() external tracked outsideWorld {
        hook.poke(key);
        ++calls["poke"];
    }

    /// @notice Someone refreshes an expired open window.
    function refreshOpenWindow() external tracked outsideWorld {
        if (!_open() || _now() - vault.openSince() <= vault.params().maxOpen) return;
        vault.refreshOpenWindow();
        ++calls["refreshOpenWindow"];
    }

    /// @notice Time passes: 0–2 days, in a new block.
    function warp(uint256 dt) external tracked outsideWorld {
        _nextBlock();
        _warpTo(_now() + _bound(dt, 0, 2 days));
        ++calls["warp"];
    }

    // ---------------------------------------------------------------- views for the invariants

    /// @notice The brute-force tick cumulative at the current time (I6).
    function bruteForceCumulative() external view returns (int256) {
        return ghostCumulative + int256(ghostLastTick) * int256(_now() - ghostLastTime);
    }

    /// @notice The depositors.
    function getDepositors() external view returns (address[3] memory) {
        return depositors;
    }

    // ---------------------------------------------------------------- ghost bookkeeping

    /// @dev Accrues the brute-force cumulative to now before the action, and records the tick after it (the tick
    ///      only changes inside swaps, and every price change in the suite happens inside a handler action).
    modifier tracked() {
        _accrue();
        _;
        _accrue();
        ghostLastTick = _tick();
    }

    /// @dev I4: an outside-world action in OPEN must not lower any depositor's redeemable amounts
    ///      (`mulDiv(idle_i, shares, supply)`, MATH.md §11).
    modifier outsideWorld() {
        bool wasOpen = _open();
        uint256[2][3] memory before = _redeemable();
        _;
        if (wasOpen && _open()) {
            uint256[2][3] memory afterwards = _redeemable();
            for (uint256 i; i < 3; ++i) {
                if (afterwards[i][0] < before[i][0] || afterwards[i][1] < before[i][1]) i4Violated = true;
            }
        }
    }

    function _accrue() internal {
        uint256 nowTs = _now();
        ghostCumulative += int256(ghostLastTick) * int256(nowTs - ghostLastTime);
        ghostLastTime = nowTs;
    }

    /// @dev Every warp goes through here so the brute-force sum accrues the old tick up to the new time first.
    function _warpTo(uint256 t) internal {
        _accrue();
        vm.warp(t);
        _accrue();
    }

    function _nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Swaps exact input until the price is exactly at `tick` (no-op if already there). The price change is
    ///      recorded for I6 right away, since this can run several times within one action.
    function _swapTo(int24 tick) internal {
        _accrue();
        (uint160 current,,,) = manager.getSlot0(id);
        uint160 target = TickMath.getSqrtPriceAtTick(tick);
        if (current != target) {
            swapRouter.swap(
                key,
                SwapParams({zeroForOne: target < current, amountSpecified: -1e36, sqrtPriceLimitX96: target}),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }
        ghostLastTick = _tick();
    }

    /// @dev Tops the bond up to exactly the minimum for the start NAV `startEpoch` will compute now (MATH.md §10).
    function _topUpBond() internal {
        uint256 elapsed = _now() - vault.openSince();
        int256 delta = hook.cumulativeNow(key) - vault.cumAtOpen();
        int256 tick = delta / int256(elapsed);
        if (delta < 0 && delta % int256(elapsed) != 0) tick -= 1;
        uint256 navStart = ValuationLib.value(vault.idle0(), vault.idle1(), TickMath.getSqrtPriceAtTick(int24(tick)));
        uint256 required = FullMath.mulDiv(navStart, vault.params().minBondBps, 10_000);
        uint256 bond = vault.bondBalance();
        if (bond >= required) return;
        token1.mint(curator, required - bond);
        vm.prank(curator);
        vault.postBond(required - bond);
    }

    /// @dev A range of 1–300 tick spacings either side of the current tick, on the spacing.
    function _rangeAroundPrice(uint256 widthSeed) internal view returns (int24 lower, int24 upper) {
        int24 center = _tick() / SPACING * SPACING;
        int24 half = int24(int256(_bound(widthSeed, 1, 300))) * SPACING;
        (lower, upper) = (center - half, center + half);
    }

    /// @dev Two starts or rebalances in three swap at most a quarter of what the vault can spend in that currency
    ///      (exact input), small enough to stay well inside the hook's guard on this deep pool.
    function _smallSwap(uint256 seed, uint256 available0, uint256 available1)
        internal
        pure
        returns (IOathVault.SwapIntent memory s)
    {
        if (seed % 3 == 0) return s;
        bool zeroForOne = seed % 2 == 0;
        uint256 cap = (zeroForOne ? available0 : available1) / 4;
        if (cap == 0) return s;
        s.zeroForOne = zeroForOne;
        s.amountSpecified = -int256(_bound(uint256(keccak256(abi.encode(seed))), 1, cap));
        s.sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _targetTick(uint256 seed) internal pure returns (int24) {
        return int24(_bound(int256(seed), int256(START_TICK - PRICE_BAND), int256(START_TICK + PRICE_BAND)));
    }

    /// @dev Each depositor's redeemable `(currency0, currency1)` in OPEN (MATH.md §11).
    function _redeemable() internal view returns (uint256[2][3] memory r) {
        uint256 supply = vault.totalSupply();
        if (supply == 0) return r;
        (uint256 idle0, uint256 idle1) = (vault.idle0(), vault.idle1());
        for (uint256 i; i < 3; ++i) {
            uint256 shares = vault.balanceOf(depositors[i]);
            r[i] = [FullMath.mulDiv(idle0, shares, supply), FullMath.mulDiv(idle1, shares, supply)];
        }
    }

    /// @dev Re-throws `err` unless its selector is one of the allowed ones (`bytes4(0)` = unused slot).
    function _allow(bytes memory err, bytes4 a, bytes4 b, bytes4 c) internal pure {
        bytes4 selector = err.length >= 4 ? bytes4(err) : bytes4(0);
        if (err.length >= 4 && (selector == a || selector == b || (c != bytes4(0) && selector == c))) return;
        assembly ("memory-safe") {
            revert(add(err, 32), mload(err))
        }
    }

    function _open() internal view returns (bool) {
        return vault.state() == IOathVault.State.OPEN;
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(id);
    }

    function _sqrtPrice() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = manager.getSlot0(id);
    }

    /// @dev Live block time (via_ir may treat `block.timestamp` as constant within a test transaction).
    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }
}
