// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {OathVaultTestBase} from "../utils/OathVaultTestBase.sol";
import {OathHandler} from "./handlers/OathHandler.sol";

/// @notice Oath's invariants under random sequences of every action (see `OathHandler`), on a vault created
///         through the real factory in a pool as deep as the real ETH/USDC pool.
contract OathInvariantsTest is OathVaultTestBase {
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
}
