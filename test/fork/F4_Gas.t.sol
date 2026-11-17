// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ForkBase} from "./ForkBase.sol";

/// @notice F4: gas of one benchmark checkpoint on the real pool with cold storage: the two pool reads the
///         benchmark needs (global fee growth and the price, MATH.md §6), as the hook's boundary snapshot does.
/// @dev Under Foundry's default `isolate = true` the test body is its own transaction, and `setUp` only creates the
///      fork, so the PoolManager account and its slots are cold here.
contract F4GasForkTest is ForkBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _fork(B1);
    }

    function test_F4_checkpointGasCold() public view {
        uint256 before = gasleft();
        (uint256 g0, uint256 g1) = MANAGER.getFeeGrowthGlobals(realId);
        (uint160 sqrtPriceX96,,,) = MANAGER.getSlot0(realId);
        uint256 used = before - gasleft();
        console2.log("F4 checkpoint gas (cold)", used);
        assertGt(g0, 0);
        assertGt(g1, 0);
        assertGt(sqrtPriceX96, 0);
        assertLt(used, 20_000, "checkpoint < 20,000 gas");
    }
}
