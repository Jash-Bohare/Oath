// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IOathVault} from "../../src/interfaces/IOathVault.sol";
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
}
