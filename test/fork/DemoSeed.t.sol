// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {ValuationLib} from "../../src/libraries/ValuationLib.sol";
import {OathVault} from "../../src/OathVault.sol";
import {Seed} from "../../script/demo/Seed.s.sol";

/// @notice The demo seed script on mainnet at B0: the Oath pool carries the real pool's price and liquidity
///         curve, and the vault holds exactly $30,000 split 50/50 by value plus the $3,000 bond, in its first
///         open window.
/// @dev Not isolated: the script runs as one call, which isolation would cap at the block gas limit.
/// forge-config: default.isolate = false
contract DemoSeedForkTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager internal constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    PoolId internal constant REAL_POOL_ID =
        PoolId.wrap(0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27);
    uint256 internal constant B0 = 26_367_600;

    Seed internal seed;

    function setUp() public {
        vm.skip(block.chainid != 1, "fork test: run with --fork-url $ETH_RPC_URL");
        seed = new Seed();
        vm.makePersistent(address(seed)); // the script forks mainnet at the layout's block itself
        seed.run();
    }

    function test_seed_clonesRealPoolAtB0() public view {
        assertEq(seed.seedBlock(), B0, "default layout is B0");
        assertEq(vm.getBlockNumber(), B0, "forked at the layout's block");
        OathVault vault = seed.vault();
        PoolId id = vault.poolId();
        (uint160 sqrtOath, int24 tickOath,,) = MANAGER.getSlot0(id);
        (uint160 sqrtReal, int24 tickReal,,) = MANAGER.getSlot0(REAL_POOL_ID);
        assertEq(sqrtOath, sqrtReal, "Oath pool at the real price");
        assertEq(tickOath, tickReal);
        assertEq(seed.sqrtStart(), sqrtReal);
        assertEq(MANAGER.getLiquidity(id), MANAGER.getLiquidity(REAL_POOL_ID), "active liquidity = real pool's");
        assertEq(address(vault.hook()), address(seed.hook()));
        assertEq(vault.factory(), address(seed.factory()));
        assertEq(Currency.unwrap(vault.poolKey().currency0), address(0), "native ETH");
        assertEq(Currency.unwrap(vault.poolKey().currency1), USDC);
    }

    function test_seed_fundsVault() public view {
        OathVault vault = seed.vault();
        (uint256 d0, uint256 d1) = (seed.deposit0(), seed.deposit1());
        assertEq(vault.idle0(), d0, "ETH deposited");
        assertEq(vault.idle1(), d1, "USDC deposited");
        assertEq(ValuationLib.value(d0, d1, seed.sqrtStart()), 30_000e6, "$30,000 at the start price");
        uint256 ethValue = ValuationLib.value(d0, 0, seed.sqrtStart());
        assertApproxEqAbs(ethValue, 15_000e6, 1, "50/50 by value");
        assertEq(vault.bondBalance(), 3_000e6, "bond");
        assertEq(IERC20Minimal(USDC).balanceOf(address(vault)), d1 + 3_000e6);
        assertEq(uint8(vault.state()), uint8(IOathVault.State.OPEN));
        assertEq(vault.openSince(), seed.createdAt(), "open window from creation");
        assertEq(vault.params().epochDuration, 1 days, "demo epochs");
    }
}
