// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IOathHook} from "../../src/interfaces/IOathHook.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {BenchmarkLib} from "../../src/libraries/BenchmarkLib.sol";
import {ValuationLib} from "../../src/libraries/ValuationLib.sol";
import {OathFactory} from "../../src/OathFactory.sol";
import {OathVault} from "../../src/OathVault.sol";

/// @title DemoSeed
/// @notice The demo's starting state, on an Ethereum-mainnet fork at the block of a recorded liquidity layout
///         (`demo/pool_tvl.py`): Oath deployed (hook at a flagged address, factory), a native-ETH/USDC Oath vault
///         and pool created at the real ETH/USDC 0.05% pool's price with the demo parameters (1-day epochs), the
///         real pool's liquidity curve cloned into the Oath pool, a $30,000 deposit split 50/50 by value, and a
///         $3,000 curator bond.
/// @dev Simulation only (cheatcodes: `deal`, `deployCodeTo`, `prank`); nothing is broadcast. Forge scripts may not
///      hold funds or be called back, so the cloned liquidity comes from a `seeder` address funded with `deal`.
abstract contract DemoSeed is Script, StdCheats {
    using StateLibrary for IPoolManager;

    /// @dev Uniswap v4 PoolManager on Ethereum mainnet.
    IPoolManager internal constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    /// @dev USDC on Ethereum mainnet.
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// @dev The real ETH/USDC 0.05% pool (native ETH, USDC, fee 500, tick spacing 10, no hook).
    bytes32 internal constant REAL_POOL_ID = 0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27;
    uint24 internal constant FEE = 500;
    int24 internal constant SPACING = 10;
    /// @dev OathHook's permission flags (0x2AA0) under arbitrary high bits.
    address internal constant HOOK_ADDRESS = address(
        uint160(0x4f41544800000000000000000000000000000000)
            | (Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_DONATE_FLAG)
    );
    /// @dev The depositors' $30,000 and the curator's $3,000 bond (USDC units).
    uint256 internal constant NAV_START = 30_000e6;
    uint256 internal constant BOND = 3_000e6;
    /// @dev The B0 layout (Nov 8 2026, block 26,367,600), relative to the project root.
    string internal constant DEFAULT_LAYOUT = "demo/layout_B0.json";

    address internal curator = makeAddr("curator");
    address internal depositor = makeAddr("depositor");
    address internal seeder = makeAddr("seeder");

    IOathHook public hook;
    OathFactory public factory;
    OathVault public vault;
    PoolKey internal key;
    PoolId internal id;
    PoolKey internal realKey;
    PoolModifyLiquidityTest internal lpRouter;
    PoolSwapTest internal swapRouter;
    /// @notice The fork block (the layout's block) and its timestamp, when the vault and its pool were created.
    uint256 public seedBlock;
    uint256 public createdAt;
    /// @notice The real pool's price at `seedBlock`, at which the Oath pool was created.
    uint160 public sqrtStart;
    /// @notice The depositors' deposit (ETH wei, USDC units).
    uint256 public deposit0;
    uint256 public deposit1;

    /// @notice The layout file's block or price does not match the real pool at that block.
    error LayoutMismatch();
    /// @notice The cloned liquidity curve differs from the real pool's (`cloned` vs `real` active liquidity).
    error CloneMismatch(uint128 cloned, uint128 real);
    /// @notice The layout's liquidityNet does not sum to zero over all initialized ticks.
    error LayoutNotClosed(int256 remaining);
    /// @notice The seeded vault's value at the start price is not exactly $30,000.
    error SeedValueMismatch(uint256 value);

    /// @dev Forks mainnet at the layout's block and builds the starting state (see the contract notice).
    /// @param layoutPath Layout JSON written by `demo/pool_tvl.py`, relative to the project root.
    function _seed(string memory layoutPath) internal {
        string memory layout = vm.readFile(string.concat(vm.projectRoot(), "/", layoutPath));
        seedBlock = vm.parseJsonUint(layout, ".block");
        vm.createSelectFork("mainnet", seedBlock);
        createdAt = vm.getBlockTimestamp();

        realKey = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(USDC), FEE, SPACING, IHooks(address(0)));
        (sqrtStart,,,) = MANAGER.getSlot0(realKey.toId());
        require(PoolId.unwrap(realKey.toId()) == REAL_POOL_ID, LayoutMismatch());
        require(sqrtStart == vm.parseJsonUint(layout, ".sqrtPriceX96"), LayoutMismatch());

        _deployOath();
        _routers();
        _cloneLayout(layout);
        _fund();
    }

    /// @dev The demo parameters: the defaults with 1-day epochs (MATH.md §12).
    function _demoParams() internal pure returns (IOathVault.VaultParams memory) {
        return IOathVault.VaultParams({
            epochDuration: 1 days,
            twapWindow: 30 minutes,
            maxOpen: 6 hours,
            rebalanceCooldown: 1 hours,
            maxIntraBlockTicks: 50,
            bandBps: 35,
            perfFeeBps: 2_000,
            minBondBps: 1_000,
            capBps: 25
        });
    }

    /// @dev The hook at its flagged address and the factory (each needs the other's address), then the vault and
    ///      its pool through the factory at the real pool's price.
    function _deployOath() private {
        address factoryAddress = makeAddr("OathFactory");
        deployCodeTo("OathHook.sol:OathHook", abi.encode(MANAGER, factoryAddress), HOOK_ADDRESS);
        hook = IOathHook(HOOK_ADDRESS);
        deployCodeTo("OathFactory.sol:OathFactory", abi.encode(MANAGER, hook), factoryAddress);
        factory = OathFactory(factoryAddress);
        vault = OathVault(
            payable(factory.createVault(
                    CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(USDC), FEE, SPACING, sqrtStart, curator, _demoParams()
                ))
        );
        key = vault.poolKey();
        id = key.toId();
    }

    /// @dev v4-core's test routers. They refund their whole ETH balance to the caller, so their stray mainnet ETH
    ///      (if any) is zeroed.
    function _routers() private {
        lpRouter = new PoolModifyLiquidityTest(MANAGER);
        swapRouter = new PoolSwapTest(MANAGER);
        vm.deal(address(lpRouter), 0);
        vm.deal(address(swapRouter), 0);
    }

    /// @dev Funds `who` with `eth` and `usdc` (on top of nothing: balances are set) and approves `spender` for USDC.
    function _fundAndApprove(address who, uint256 eth, uint256 usdc, address spender) internal {
        vm.deal(who, eth);
        deal(USDC, who, usdc);
        vm.prank(who);
        IERC20Minimal(USDC).approve(spender, type(uint256).max);
    }

    /// @dev One position per segment between consecutive initialized ticks of the real pool, with the segment's
    ///      active liquidity, so the Oath pool's liquidity curve equals the real pool's: the active liquidity must
    ///      match exactly.
    function _cloneLayout(string memory layout) private {
        int256[] memory ticks = vm.parseJsonIntArray(layout, ".ticks");
        int256[] memory nets = vm.parseJsonIntArray(layout, ".liquidityNet");
        _fundAndApprove(seeder, 100_000_000 ether, 1e17, address(lpRouter)); // 100M ETH, 100B USDC
        vm.startPrank(seeder);
        int256 liquidity;
        for (uint256 i; i + 1 < ticks.length; ++i) {
            liquidity += nets[i];
            if (liquidity == 0) continue;
            lpRouter.modifyLiquidity{value: 10_000 ether}( // the router refunds what the pool does not take
                key, ModifyLiquidityParams(int24(ticks[i]), int24(ticks[i + 1]), liquidity, bytes32(0)), ""
            );
        }
        vm.stopPrank();
        require(liquidity + nets[ticks.length - 1] == 0, LayoutNotClosed(liquidity + nets[ticks.length - 1]));
        uint128 cloned = MANAGER.getLiquidity(id);
        uint128 real = MANAGER.getLiquidity(realKey.toId());
        require(cloned == real && cloned == vm.parseJsonUint(layout, ".activeLiquidity"), CloneMismatch(cloned, real));
    }

    /// @dev The depositor deposits the 50/50-by-value split of $30,000 at the start price (the ETH half from
    ///      `BenchmarkLib.split`, and the USDC that makes exactly $30,000); the curator posts the $3,000 bond.
    function _fund() private {
        (deposit0,) = BenchmarkLib.split(NAV_START, sqrtStart);
        deposit1 = NAV_START - ValuationLib.value(deposit0, 0, sqrtStart);
        _fundAndApprove(depositor, deposit0, deposit1, address(vault));
        vm.prank(depositor);
        vault.deposit{value: deposit0}(deposit0, deposit1, 0, depositor);

        _fundAndApprove(curator, 0, BOND, address(vault));
        vm.prank(curator);
        vault.postBond(BOND);

        uint256 seeded = ValuationLib.value(vault.idle0(), vault.idle1(), sqrtStart);
        require(seeded == NAV_START, SeedValueMismatch(seeded));
    }
}

/// @title Seed
/// @notice Builds the demo's starting state and prints it. `Replay.s.sol` runs the same seed before replaying.
///         Run: `forge script script/demo/Seed.s.sol` (forks mainnet itself through `ETH_RPC_URL`).
///         `LAYOUT` (default `demo/layout_B0.json`) selects the layout file.
contract Seed is DemoSeed {
    using StateLibrary for IPoolManager;

    /// @notice Seeds and logs the result.
    function run() external {
        _seed(vm.envOr("LAYOUT", string(DEFAULT_LAYOUT)));
        console2.log("Fork block / timestamp", seedBlock, createdAt);
        console2.log("Oath vault", address(vault));
        console2.log("Pool active liquidity (= real pool)", MANAGER.getLiquidity(id));
        console2.log("Deposit ETH wei / USDC units", deposit0, deposit1);
        console2.log(
            "Vault value / bond (USDC units)",
            ValuationLib.value(vault.idle0(), vault.idle1(), sqrtStart),
            vault.bondBalance()
        );
    }
}
