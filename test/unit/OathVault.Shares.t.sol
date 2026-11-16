// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {OathVault} from "../../src/OathVault.sol";
import {OathVaultTestBase} from "../utils/OathVaultTestBase.sol";

/// @notice OathVault shares (MATH.md §11) on a vault created through the real factory: in-kind, price-free
///         deposits and withdrawals.
contract OathVaultSharesTest is OathVaultTestBase {
    function setUp() public override {
        super.setUp();
        _createVault(currency0);
        _give(alice, 1e30, 1e30);
        _give(bob, 1e30, 1e30);
    }

    // ---------------------------------------------------------------- first deposit

    /// @dev `shares = sqrt(a0·a1) − MIN_SHARES`, `MIN_SHARES` locked at `DEAD`, both amounts taken in full.
    function test_shares_firstDepositLocksDeadShares() public {
        uint256 a0 = 4e18;
        uint256 a1 = 9e18; // sqrt(36e36) = 6e18
        uint256 before0 = _balance0(alice);
        uint256 before1 = _balance1(alice);

        vm.expectEmit(true, true, false, true, address(vault));
        emit IOathVault.Deposit(alice, alice, a0, a1, 6e18 - 1_000);
        (uint256 shares, uint256 used0, uint256 used1) = _deposit(alice, a0, a1);

        assertEq(shares, 6e18 - 1_000, "shares");
        assertEq(used0, a0);
        assertEq(used1, a1);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.balanceOf(vault.DEAD()), vault.MIN_SHARES(), "dead shares");
        assertEq(vault.totalSupply(), 6e18, "supply = sqrt(a0*a1)");
        assertEq(before0 - _balance0(alice), a0, "currency0 taken");
        assertEq(before1 - _balance1(alice), a1, "currency1 taken");
        assertEq(vault.idle0(), a0);
        assertEq(vault.idle1(), a1);
    }

    /// @dev The smallest first deposit: `sqrt(a0·a1)` must exceed `MIN_SHARES`.
    function test_shares_firstDepositMinimum() public {
        vm.prank(alice);
        vm.expectRevert(IOathVault.ZeroShares.selector);
        vault.deposit(1_000, 1_000, 0, alice); // sqrt = 1,000

        (uint256 shares,,) = _deposit(alice, 1_001, 1_001);
        assertEq(shares, 1);
    }

    /// @dev Both currencies are required for the first deposit.
    function test_shares_firstDepositNeedsBothCurrencies() public {
        vm.startPrank(alice);
        vm.expectRevert(IOathVault.ZeroShares.selector);
        vault.deposit(0, 1e18, 0, alice);
        vm.expectRevert(IOathVault.ZeroShares.selector);
        vault.deposit(1e18, 0, 0, alice);
        vm.stopPrank();
    }

    /// @dev Shares go to `receiver`; tokens come from the sender.
    function test_shares_depositToReceiver() public {
        uint256 before1 = _balance1(alice);
        vm.prank(alice);
        (uint256 shares,,) = vault.deposit(1e18, 1e18, 0, bob);
        assertEq(vault.balanceOf(bob), shares);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(before1 - _balance1(alice), 1e18);
    }

    // ---------------------------------------------------------------- later deposits

    /// @dev A later deposit mints `min_i(supply·a_i/h_i)` and takes only `mulDivUp(h_i, shares, supply)`;
    ///      the excess of the more plentiful token is not taken.
    function test_shares_laterDepositIsProportional() public {
        _deposit(alice, 2e18, 8e18); // supply 4e18, holdings 2e18 / 8e18
        uint256 before0 = _balance0(bob);
        uint256 before1 = _balance1(bob);

        (uint256 shares, uint256 used0, uint256 used1) = _deposit(bob, 1e18, 10e18); // currency0 binds
        assertEq(shares, 2e18, "supply*a0/h0 = 4e18*1e18/2e18");
        assertEq(used0, 1e18, "all currency0");
        assertEq(used1, 4e18, "currency1 at the vault ratio, not 10e18");
        assertEq(before0 - _balance0(bob), used0, "only used0 pulled");
        assertEq(before1 - _balance1(bob), used1, "only used1 pulled");
        assertEq(vault.idle0(), 3e18);
        assertEq(vault.idle1(), 12e18);
    }

    /// @dev If the vault holds only one currency, only that one prices the deposit and is taken.
    function test_shares_oneSidedHoldings() public {
        _deposit(alice, 1e18, 1e18);
        _setIdle0(0); // holdings become one-sided, as after an epoch that ends fully in currency1

        uint256 before0 = _balance0(bob);
        (uint256 shares, uint256 used0, uint256 used1) = _deposit(bob, 5e18, 2e18);
        assertEq(shares, 2e18, "priced by currency1 only");
        assertEq(used0, 0, "no currency0 taken");
        assertEq(used1, 2e18);
        assertEq(_balance0(bob), before0);
    }

    /// @dev A deposit too small for one share reverts instead of taking tokens for nothing.
    function test_shares_tooSmallForOneShare() public {
        _deposit(alice, 1e18, 1e18); // supply 1e18 = holdings
        _setIdle0(1e30); // one share now backs 1e12 currency0
        vm.prank(bob);
        vm.expectRevert(IOathVault.ZeroShares.selector);
        vault.deposit(1e11, 1e18, 0, bob);
    }

    /// @dev Supply without holdings cannot price a deposit.
    function test_shares_emptyVaultReverts() public {
        _deposit(alice, 1e18, 1e18);
        _setIdle0(0);
        _setIdle1(0);
        vm.prank(bob);
        vm.expectRevert(IOathVault.EmptyVault.selector);
        vault.deposit(1e18, 1e18, 0, bob);
    }

    /// @dev `minShares` protects the depositor.
    function test_shares_depositSlippage() public {
        _deposit(alice, 1e18, 1e18);
        vm.prank(bob);
        vm.expectRevert(IOathVault.Slippage.selector);
        vault.deposit(1e18, 1e18, 1e18 + 1, bob);

        vm.prank(bob);
        (uint256 shares,,) = vault.deposit(1e18, 1e18, 1e18, bob);
        assertEq(shares, 1e18);
    }

    /// @dev An ERC-20 currency0 vault takes no ETH.
    function test_shares_erc20VaultRejectsEth() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(IOathVault.BadNativeAmount.selector);
        vault.deposit{value: 1}(1e18, 1e18, 0, alice);
    }

    /// @dev Later deposits never take more than offered and never mint more value than they bring:
    ///      `used_i ≤ a_i`, and the depositor's share of holdings after is at most what they paid.
    function testFuzz_shares_laterDepositNeverOverpaysOrOvermints(uint256 h0, uint256 h1, uint256 a0, uint256 a1)
        public
    {
        h0 = bound(h0, 1e6, 1e27);
        h1 = bound(h1, 1e6, 1e27);
        a0 = bound(a0, 1, 1e27);
        a1 = bound(a1, 1, 1e27);
        _deposit(alice, h0, h1);

        vm.prank(bob);
        try vault.deposit(a0, a1, 0, bob) returns (uint256 shares, uint256 used0, uint256 used1) {
            assertLe(used0, a0, "used0 <= a0");
            assertLe(used1, a1, "used1 <= a1");
            uint256 supply = vault.totalSupply();
            // Bob's pro-rata claim on the new holdings never exceeds what he put in.
            assertLe(shares * vault.idle0() / supply, used0, "claim0 <= used0");
            assertLe(shares * vault.idle1() / supply, used1, "claim1 <= used1");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), IOathVault.ZeroShares.selector, "only a too-small deposit fails");
        }
    }

    // ---------------------------------------------------------------- withdrawals

    /// @dev `out_i = mulDiv(h_i, shares, supply)`, sent to the receiver; the shares are burned from the caller.
    function test_shares_withdrawIsProRata() public {
        _deposit(alice, 4e18, 9e18); // supply 6e18
        uint256 shares = 2e18;
        uint256 out0Expected = uint256(4e18) * shares / 6e18; // 1.333…e18, floored
        uint256 out1Expected = uint256(9e18) * shares / 6e18; // 3e18
        uint256 bob0 = _balance0(bob);
        uint256 bob1 = _balance1(bob);

        vm.expectEmit(true, true, false, true, address(vault));
        emit IOathVault.Withdraw(alice, bob, out0Expected, out1Expected, shares);
        vm.prank(alice);
        (uint256 out0, uint256 out1) = vault.withdraw(shares, 0, 0, bob);

        assertEq(out0, out0Expected, "out0");
        assertEq(out1, out1Expected, "out1");
        assertEq(_balance0(bob) - bob0, out0, "receiver got currency0");
        assertEq(_balance1(bob) - bob1, out1, "receiver got currency1");
        assertEq(vault.balanceOf(alice), 6e18 - 1_000 - shares, "burned from caller");
        assertEq(vault.totalSupply(), 4e18);
        assertEq(vault.idle0(), 4e18 - out0);
        assertEq(vault.idle1(), 9e18 - out1);
    }

    /// @dev When every withdrawable share is redeemed, only the dead shares' part stays behind.
    function test_shares_withdrawAllLeavesOnlyDeadShare() public {
        _deposit(alice, 1e18, 1e18); // supply 1e18
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(aliceShares, 0, 0, alice);
        assertEq(vault.totalSupply(), vault.MIN_SHARES());
        assertEq(vault.idle0(), 1_000, "dead share's currency0");
        assertEq(vault.idle1(), 1_000, "dead share's currency1");
    }

    function test_shares_withdrawSlippage() public {
        _deposit(alice, 1e18, 1e18);
        vm.startPrank(alice);
        vm.expectRevert(IOathVault.Slippage.selector);
        vault.withdraw(1e17, 1e17 + 1, 0, alice);
        vm.expectRevert(IOathVault.Slippage.selector);
        vault.withdraw(1e17, 0, 1e17 + 1, alice);
        (uint256 out0, uint256 out1) = vault.withdraw(1e17, 1e17, 1e17, alice);
        vm.stopPrank();
        assertEq(out0, 1e17);
        assertEq(out1, 1e17);
    }

    /// @dev Nobody can burn shares they do not hold.
    function test_shares_withdrawMoreThanHeldReverts() public {
        _deposit(alice, 1e18, 1e18);
        uint256 held = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, held + 1));
        vault.withdraw(held + 1, 0, 0, alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 1));
        vault.withdraw(1, 0, 0, bob);
    }

    /// @dev A deposit followed by withdrawing the same shares returns what was taken, less at most 1 wei per
    ///      currency (MATH.md §11 rounding), and never more.
    function testFuzz_shares_depositWithdrawRoundTrip(uint256 h0, uint256 h1, uint256 a0, uint256 a1) public {
        h0 = bound(h0, 1e6, 1e27);
        h1 = bound(h1, 1e6, 1e27);
        a0 = bound(a0, 1, 1e27);
        a1 = bound(a1, 1, 1e27);
        _deposit(alice, h0, h1);

        vm.prank(bob);
        try vault.deposit(a0, a1, 0, bob) returns (uint256 shares, uint256 used0, uint256 used1) {
            vm.prank(bob);
            (uint256 out0, uint256 out1) = vault.withdraw(shares, 0, 0, bob);
            assertLe(out0, used0, "no profit in currency0");
            assertLe(out1, used1, "no profit in currency1");
            assertGe(out0 + 1, used0, "loses at most 1 wei of currency0");
            assertGe(out1 + 1, used1, "loses at most 1 wei of currency1");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), IOathVault.ZeroShares.selector);
        }
    }
}

/// @notice Receives ETH from the vault and tries to re-enter it; records what the vault answered.
contract Reenterer {
    OathVault internal immutable VAULT;
    bytes4 public caught;

    constructor(OathVault vault_) {
        VAULT = vault_;
    }

    function approveVault(address token) external {
        IERC20(token).approve(address(VAULT), type(uint256).max);
    }

    /// @dev Deposits with more ETH than will be used, so the vault refunds the rest to this contract.
    function depositWithExcess(uint256 amount1) external payable {
        VAULT.deposit{value: msg.value}(msg.value, amount1, 0, address(this));
    }

    receive() external payable {
        try VAULT.withdraw(0, 0, 0, address(this)) {
            caught = bytes4(0xffffffff);
        } catch (bytes memory reason) {
            caught = bytes4(reason);
        }
    }
}

/// @notice OathVault shares with native ETH as currency0, the demo's shape.
contract OathVaultNativeSharesTest is OathVaultTestBase {
    function setUp() public override {
        super.setUp();
        _createVault(CurrencyLibrary.ADDRESS_ZERO);
        _give(alice, 1_000 ether, 1e30);
        _give(bob, 1_000 ether, 1e30);
    }

    /// @dev The first deposit takes all the ETH sent.
    function test_native_firstDeposit() public {
        uint256 before = alice.balance;
        (uint256 shares, uint256 used0,) = _deposit(alice, 4 ether, 9 ether);
        assertEq(shares, 6 ether - 1_000);
        assertEq(used0, 4 ether);
        assertEq(before - alice.balance, 4 ether, "ETH taken");
        assertEq(address(vault).balance, 4 ether);
        assertEq(vault.idle0(), 4 ether);
    }

    /// @dev `msg.value` must equal `amount0Max`, both ways.
    function test_native_valueMustMatchAmount0Max() public {
        vm.startPrank(alice);
        vm.expectRevert(IOathVault.BadNativeAmount.selector);
        vault.deposit{value: 1 ether - 1}(1 ether, 1 ether, 0, alice);
        vm.expectRevert(IOathVault.BadNativeAmount.selector);
        vault.deposit{value: 1 ether + 1}(1 ether, 1 ether, 0, alice);
        vm.stopPrank();
    }

    /// @dev A later deposit prices against holdings that exclude the ETH just sent, takes `used0` and refunds
    ///      the rest to the sender.
    function test_native_laterDepositRefundsUnusedEth() public {
        _deposit(alice, 1 ether, 4 ether); // supply 2e18
        uint256 before = bob.balance;
        (uint256 shares, uint256 used0, uint256 used1) = _deposit(bob, 5 ether, 4 ether); // currency1 binds
        assertEq(shares, 2 ether, "supply*a1/h1 = 2e18*4e18/4e18");
        assertEq(used0, 1 ether, "ETH at the vault ratio");
        assertEq(used1, 4 ether);
        assertEq(before - bob.balance, 1 ether, "4 ETH refunded");
        assertEq(address(vault).balance, 2 ether);
    }

    /// @dev With no ETH in the vault, a deposit takes none and refunds all of it.
    function test_native_noEthHeldRefundsAll() public {
        _deposit(alice, 1 ether, 1 ether);
        _setIdle0(0);
        uint256 before = bob.balance;
        (, uint256 used0,) = _deposit(bob, 3 ether, 1 ether);
        assertEq(used0, 0);
        assertEq(bob.balance, before, "all ETH refunded");
    }

    /// @dev Withdrawals pay ETH to the receiver.
    function test_native_withdrawPaysEth() public {
        _deposit(alice, 2 ether, 2 ether);
        address payable receiver = payable(makeAddr("receiver"));
        vm.prank(alice);
        (uint256 out0, uint256 out1) = vault.withdraw(1 ether, 0, 0, receiver);
        assertEq(out0, 1 ether);
        assertEq(out1, 1 ether);
        assertEq(receiver.balance, 1 ether, "ETH received");
        assertEq(currency1.balanceOf(receiver), 1 ether);
    }

    /// @dev Plain ETH transfers are refused unless they come from the PoolManager.
    function test_native_receiveOnlyFromManager() public {
        vm.prank(alice);
        (bool ok, bytes memory reason) = address(vault).call{value: 1 ether}("");
        assertFalse(ok, "refused");
        assertEq(bytes4(reason), IOathVault.OnlyManager.selector);

        vm.deal(address(manager), 1 ether);
        vm.prank(address(manager));
        (ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok, "accepted from the PoolManager");
    }

    /// @dev Re-entering from the ETH sent by a withdrawal is blocked.
    function test_native_reentryFromWithdrawalBlocked() public {
        _deposit(alice, 2 ether, 2 ether);
        Reenterer attacker = new Reenterer(vault);
        vm.prank(alice);
        vault.withdraw(1 ether, 0, 0, address(attacker));
        assertEq(attacker.caught(), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(address(attacker).balance, 1 ether, "the outer withdrawal still paid");
    }

    /// @dev Re-entering from the ETH refunded by a deposit is blocked.
    function test_native_reentryFromRefundBlocked() public {
        _deposit(alice, 1 ether, 1 ether);
        Reenterer attacker = new Reenterer(vault);
        _fund(currency1, address(attacker), 1 ether);
        attacker.approveVault(Currency.unwrap(currency1));

        uint256 before = address(attacker).balance;
        vm.deal(address(this), 3 ether);
        attacker.depositWithExcess{value: 3 ether}(1 ether); // the vault takes 1 ETH, refunds 2
        assertEq(attacker.caught(), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(address(attacker).balance - before, 2 ether, "refund still paid");
        assertEq(vault.balanceOf(address(attacker)), 1 ether, "shares minted");
    }
}
