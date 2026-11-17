// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @title ForkBase
/// @notice Shared Ethereum-mainnet fork setup: the real v4 PoolManager, USDC, the real hookless ETH/USDC 0.05%
///         pool and the pinned blocks. Adapted from our own pre-hookathon fork-test feasibility study.
/// @dev Fork tests run only when invoked against mainnet, e.g.
///      `forge test --match-path "test/fork/*" --fork-url $ETH_RPC_URL`: `_fork` skips the test unless the chain
///      id is 1, so a plain `forge test` (including on a fresh clone without an RPC) stays local. Every fork is
///      pinned to a block through the `mainnet` RPC endpoint (`ETH_RPC_URL`).
abstract contract ForkBase is Test {
    using StateLibrary for IPoolManager;

    IPoolManager internal constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// @dev The real ETH/USDC 0.05% pool (native ETH, USDC, fee 500, tick spacing 10, no hook).
    bytes32 internal constant REAL_POOL_ID = 0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27;

    /// @dev Sun Nov 8 2026, 03:56:11 UTC. Start of the demo window and of the F2/F3 history.
    uint256 internal constant B0 = 26_367_600;
    /// @dev Sun Nov 15 2026, 04:26:47 UTC (B0 + 50,400 blocks).
    uint256 internal constant B1 = 26_418_000;

    uint24 internal constant FEE = 500;
    int24 internal constant SPACING = 10;

    /// @dev Real-data files (written by `demo/fetch_swaps.py` and `demo/pool_tvl.py`).
    string internal constant SWAPS_FILE = "/demo/swaps/2026-11-08_2026-11-15.json";
    string internal constant LAYOUT_FILE = "/demo/layout_B0.json";

    PoolKey internal realKey;
    PoolId internal realId;
    int24 internal tickMin;
    int24 internal tickMax;

    /// @dev Skips unless running against mainnet, then forks it at `blockNumber` and checks the real pool.
    function _fork(uint256 blockNumber) internal {
        vm.skip(block.chainid != 1, "fork test: run with --fork-url $ETH_RPC_URL");
        vm.createSelectFork("mainnet", blockNumber);
        realKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDC), FEE, SPACING, IHooks(address(0)));
        realId = realKey.toId();
        assertEq(PoolId.unwrap(realId), REAL_POOL_ID, "real pool id");
        (tickMin, tickMax) = (TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING));
        (uint160 sqrtPriceX96,,,) = MANAGER.getSlot0(realId);
        assertGt(sqrtPriceX96, 0, "real pool initialized");
        assertGt(MANAGER.getLiquidity(realId), 0, "real pool has active liquidity");
    }

    /// @dev Fresh v4-core test routers on the fork; this contract is funded with ETH and USDC and approves them.
    ///      The routers refund their whole ETH balance to the caller after each call, and a fresh address can hold
    ///      stray ETH on mainnet, so their balances are zeroed: balance changes then measure only the pool.
    function _routers() internal returns (PoolModifyLiquidityTest lpRouter, PoolSwapTest swapRouter) {
        lpRouter = new PoolModifyLiquidityTest(MANAGER);
        swapRouter = new PoolSwapTest(MANAGER);
        vm.deal(address(lpRouter), 0);
        vm.deal(address(swapRouter), 0);
        vm.deal(address(this), 100_000_000 ether);
        deal(USDC, address(this), 1e17); // 100B USDC
        IERC20Minimal(USDC).approve(address(lpRouter), type(uint256).max);
        IERC20Minimal(USDC).approve(address(swapRouter), type(uint256).max);
    }

    /// @dev This contract's ETH and USDC balances.
    function _balances() internal view returns (uint256 eth, uint256 usdc) {
        return (address(this).balance, IERC20Minimal(USDC).balanceOf(address(this)));
    }

    /// @dev `|a − b| / b` in hundredths of a basis point (1 = 0.01 bps).
    function _bps100(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 d = a > b ? a - b : b - a;
        return d * 1_000_000 / b;
    }

    /// @dev Accepts ETH from the PoolManager and the routers.
    receive() external payable {}
}
