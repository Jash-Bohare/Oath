// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC6909Claims} from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {OathVaultTestBase} from "../utils/OathVaultTestBase.sol";
import {OathHandler} from "./handlers/OathHandler.sol";

/// @notice Oath's invariants under random sequences of every action (see `OathHandler`), on a vault created
///         through the real factory in a pool as deep as the real ETH/USDC pool.
contract OathInvariantsTest is OathVaultTestBase {
    using StateLibrary for IPoolManager;

    OathHandler internal handler;

    function setUp() public override {
        super.setUp();
        _createVault(currency0);
        _seedPool(POOL_LIQUIDITY);
        handler = new OathHandler(
            vault, swapRouter, modifyLiquidityRouter, donateRouter, [alice, bob, makeAddr("carol")], keeper
        );

        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = OathHandler.deposit.selector;
        selectors[1] = OathHandler.withdraw.selector;
        selectors[2] = OathHandler.postBond.selector;
        selectors[3] = OathHandler.withdrawBond.selector;
        selectors[4] = OathHandler.startEpoch.selector;
        selectors[5] = OathHandler.rebalance.selector;
        selectors[6] = OathHandler.settle.selector;
        selectors[7] = OathHandler.swap.selector;
        selectors[8] = OathHandler.donate.selector;
        selectors[9] = OathHandler.addLiquidity.selector;
        selectors[10] = OathHandler.removeLiquidity.selector;
        selectors[11] = OathHandler.transferToVault.selector;
        selectors[12] = OathHandler.poke.selector;
        selectors[13] = OathHandler.refreshOpenWindow.selector;
        selectors[14] = OathHandler.warp.selector;
        targetContract(address(handler));
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev The vault's lifecycle and the hook's epoch agree: an epoch is open in the hook exactly while the vault
    ///      is ACTIVE (opened by `startEpoch`, closed by `settle`).
    function invariant_lifecycleMatchesHook() public view {
        bool active = vault.state() == IOathVault.State.ACTIVE;
        assertEq(hook.epochData(key).active, active, "hook epoch active iff vault ACTIVE");
    }

    // ---------------------------------------------------------------- I1–I7 (threat model invariants)

    /// @dev I1: the vault always holds at least the bond in currency1; no action spends it except a settlement
    ///      payout, which moves it to the depositors' idle balance inside the vault.
    function invariant_I1_bondCovered() public view {
        assertGe(c1.balanceOf(address(vault)), vault.bondBalance(), "currency1 balance >= bond");
    }

    /// @dev I2: in OPEN the vault has no liquidity in the pool. While ACTIVE the pool holds exactly the recorded
    ///      `L_v` under the vault's salt.
    function invariant_I2_noLiquidityWhileOpen() public view {
        (int24 lower, int24 upper, uint128 liquidity) = vault.positionInfo();
        (uint128 inPool,,) = manager.getPositionInfo(key.toId(), address(vault), lower, upper, vault.POSITION_SALT());
        if (vault.state() == IOathVault.State.OPEN) {
            assertEq(liquidity, 0, "L_v = 0 in OPEN");
            assertEq(inPool, 0, "no pool liquidity in OPEN");
        } else {
            assertEq(inPool, liquidity, "pool position = L_v while ACTIVE");
        }
    }

    /// @dev I3: total supply is the sum of all balances and changes only through deposits (including the dead
    ///      shares), withdrawals and settlement fee shares.
    function invariant_I3_supplyAccounting() public view {
        uint256 supply = vault.totalSupply();
        assertEq(
            supply,
            handler.ghostMinted() - handler.ghostBurned() + handler.ghostFeeShares(),
            "supply = deposits - withdrawals + fee shares"
        );
        address[3] memory depositors = handler.getDepositors();
        uint256 sum = vault.balanceOf(vault.DEAD()) + vault.balanceOf(curator);
        for (uint256 i; i < 3; ++i) {
            sum += vault.balanceOf(depositors[i]);
        }
        assertEq(supply, sum, "supply = sum of balances");
    }

    /// @dev I4: no outside-world action (swap, donation, liquidity change, transfer to the vault, poke, window
    ///      refresh, time passing) lowered any depositor's redeemable amounts while the vault was OPEN.
    function invariant_I4_outsideWorldCannotReduceRedeemable() public view {
        assertFalse(handler.i4Violated(), "a depositor's redeemable amounts fell in OPEN");
    }

    /// @dev I5: the hook never returns deltas (its address carries no return-delta permission, so the PoolManager
    ///      never applies one) and never holds funds or claims. That it never reverts an outside-world swap,
    ///      donation or liquidity change is enforced by the handler: those calls are not wrapped and the suite runs
    ///      with `fail_on_revert = true`.
    function invariant_I5_hookNeutral() public view {
        uint160 returnDeltaFlags = Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
        assertEq(uint160(address(hook)) & returnDeltaFlags, 0, "no return-delta permission");
        assertEq(c0.balanceOf(address(hook)), 0, "hook holds no currency0");
        assertEq(c1.balanceOf(address(hook)), 0, "hook holds no currency1");
        assertEq(address(hook).balance, 0, "hook holds no ETH");
        IERC6909Claims claims = IERC6909Claims(address(manager));
        assertEq(claims.balanceOf(address(hook), c0.toId()), 0, "no currency0 claims");
        assertEq(claims.balanceOf(address(hook), c1.toId()), 0, "no currency1 claims");
    }

    /// @dev I6: the hook's tick cumulative equals the brute-force Σ tick·dt since pool creation (MATH.md §4).
    function invariant_I6_cumulativeIsBruteForce() public view {
        assertEq(handler.ghostLastTick(), _tick(), "ghost tick is the pool tick");
        assertEq(hook.cumulativeNow(key), handler.bruteForceCumulative(), "cumulative = brute force");
    }

    /// @dev I7: every settlement gave the same `EpochResult` with and without extra swaps after `E`.
    function invariant_I7_settlementDeterministic() public view {
        assertFalse(handler.i7Violated(), "post-E swaps changed an EpochResult");
    }
}
