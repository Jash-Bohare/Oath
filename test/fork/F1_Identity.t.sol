// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {BenchmarkLib} from "../../src/libraries/BenchmarkLib.sol";
import {ValuationLib} from "../../src/libraries/ValuationLib.sol";
import {ForkBase} from "./ForkBase.sol";

/// @notice F1: the benchmark identity on the real mainnet PoolManager and the real ETH/USDC 0.05% pool (MATH.md §6,
///         §13). A real full-range position of the benchmark's liquidity `L_b` is charged exactly the costs
///         `BenchmarkLib.create` computes; after 100 real-size swaps its fee growth inside equals global fee growth,
///         its fees equal `ValuationLib.feesOwed` and its withdrawal equals `ValuationLib.principal`, so
///         `BenchmarkLib.valueAt` equals the value of what the real position returns, to the wei.
contract F1IdentityForkTest is ForkBase {
    using StateLibrary for IPoolManager;

    PoolModifyLiquidityTest internal lpRouter;
    PoolSwapTest internal swapRouter;

    function setUp() public {
        _fork(B1);
        (lpRouter, swapRouter) = _routers();
    }

    function test_F1_benchmarkEqualsRealPosition() public {
        (uint160 sqrtStart,,,) = MANAGER.getSlot0(realId);
        // A benchmark worth two ETH at the start price, split 50/50 by value (MATH.md §6.1).
        uint256 navStart = 2 * ValuationLib.value(1 ether, 0, sqrtStart);
        (uint128 liquidity, uint256 r0, uint256 r1) = BenchmarkLib.create(navStart, sqrtStart, SPACING);
        (uint256 x, uint256 y) = BenchmarkLib.split(navStart, sqrtStart);
        bytes32 salt = keccak256("oath-F1");

        // Charged exactly the benchmark's costs: x − r0 and y − r1.
        (uint256 eth0, uint256 usdc0) = _balances();
        _modify(int256(uint256(liquidity)), salt, x);
        (uint256 eth1, uint256 usdc1) = _balances();
        assertEq(eth0 - eth1, x - r0, "charged currency0 = cost0");
        assertEq(usdc0 - usdc1, y - r1, "charged currency1 = cost1");

        (uint256 g0Start, uint256 g1Start) = MANAGER.getFeeGrowthGlobals(realId);
        (uint256 in0Start, uint256 in1Start) = MANAGER.getFeeGrowthInside(realId, tickMin, tickMax);
        uint256 crossings = _swaps(100);

        (uint160 sqrtEnd,,,) = MANAGER.getSlot0(realId);
        (uint256 g0End, uint256 g1End) = MANAGER.getFeeGrowthGlobals(realId);
        (uint256 in0End, uint256 in1End) = MANAGER.getFeeGrowthInside(realId, tickMin, tickMax);
        unchecked {
            assertEq(in0End - in0Start, g0End - g0Start, "full-range fee growth inside = global (0)");
            assertEq(in1End - in1Start, g1End - g1Start, "full-range fee growth inside = global (1)");
        }

        // Fees: a zero-liquidity poke collects fees only.
        (eth0, usdc0) = _balances();
        _modify(0, salt, 0);
        (eth1, usdc1) = _balances();
        uint256 fees0 = ValuationLib.feesOwed(liquidity, g0Start, g0End);
        uint256 fees1 = ValuationLib.feesOwed(liquidity, g1Start, g1End);
        assertGt(fees0, 0);
        assertGt(fees1, 0);
        assertEq(eth1 - eth0, fees0, "fees0 = feesOwed");
        assertEq(usdc1 - usdc0, fees1, "fees1 = feesOwed");

        // Principal: the withdrawal at the end price.
        (eth0, usdc0) = _balances();
        _modify(-int256(uint256(liquidity)), salt, 0);
        (eth1, usdc1) = _balances();
        (uint256 p0, uint256 p1) = ValuationLib.principal(liquidity, tickMin, tickMax, sqrtEnd);
        assertEq(eth1 - eth0, p0, "withdrawn currency0 = principal");
        assertEq(usdc1 - usdc0, p1, "withdrawn currency1 = principal");

        // The benchmark's value at E is the value of everything the real position returned plus the leftovers.
        IOathVault.Benchmark memory b;
        (b.L, b.r0, b.r1, b.G0, b.G1) = (liquidity, r0, r1, g0Start, g1Start);
        (uint256 benchEnd,,) = BenchmarkLib.valueAt(b, g0End, g1End, sqrtEnd, SPACING);
        assertEq(benchEnd, ValuationLib.value(p0 + fees0 + r0, p1 + fees1 + r1, sqrtEnd), "valueAt = real position");

        console2.log("F1 L_b", liquidity);
        console2.log("F1 tick-spacing boundaries crossed", crossings);
        console2.log("F1 fees ETH wei / USDC", fees0, fees1);
        console2.log("F1 principal ETH wei / USDC", p0, p1);
    }

    /// @dev `n` exact-input swaps, mixed direction, 0.01 to ~300 ETH equivalent each. Returns the number of
    ///      tick-spacing boundaries moved through.
    function _swaps(uint256 n) internal returns (uint256 crossings) {
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode("F1", i)));
            bool zeroForOne = r & 1 == 0;
            uint256 ethSize = 0.01 ether + (r >> 8) % 300 ether;
            (uint160 sqrtP, int24 before,,) = MANAGER.getSlot0(realId);
            uint256 amountIn = zeroForOne ? ethSize : ValuationLib.value(ethSize, 0, sqrtP);
            swapRouter.swap{value: zeroForOne ? amountIn : 0}(
                realKey,
                SwapParams(
                    zeroForOne,
                    -int256(amountIn),
                    zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                PoolSwapTest.TestSettings(false, false),
                ""
            );
            (, int24 afterwards,,) = MANAGER.getSlot0(realId);
            int24 moved = afterwards > before ? afterwards - before : before - afterwards;
            crossings += uint256(int256(moved / SPACING));
        }
    }

    function _modify(int256 liquidityDelta, bytes32 salt, uint256 value) internal {
        lpRouter.modifyLiquidity{value: value}(
            realKey, ModifyLiquidityParams(tickMin, tickMax, liquidityDelta, salt), ""
        );
    }
}
