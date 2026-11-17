// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IOathVault} from "../../src/interfaces/IOathVault.sol";
import {OathVaultTestBase} from "../utils/OathVaultTestBase.sol";

/// @notice The curator's currency1 bond: posted by the curator at any time, withdrawn only in the open window,
///         and never part of depositors' holdings.
contract OathVaultBondTest is OathVaultTestBase {
    function setUp() public override {
        super.setUp();
        _createVault(currency0);
        _give(curator, 0, 1e30);
        _give(alice, 1e30, 1e30);
        _give(bob, 1e30, 1e30);
    }

    // ---------------------------------------------------------------- postBond

    function test_bond_postPullsCurrency1() public {
        uint256 before = _balance1(curator);
        vm.expectEmit(false, false, false, true, address(vault));
        emit IOathVault.BondPosted(3_000e6, 3_000e6);
        vm.prank(curator);
        vault.postBond(3_000e6);

        assertEq(vault.bondBalance(), 3_000e6);
        assertEq(before - _balance1(curator), 3_000e6, "pulled from the curator");
        assertEq(currency1.balanceOf(address(vault)), 3_000e6, "held by the vault");
        assertEq(vault.idle1(), 0, "not idle");
    }

    function test_bond_postAccumulates() public {
        vm.startPrank(curator);
        vault.postBond(1_000e6);
        vm.expectEmit(false, false, false, true, address(vault));
        emit IOathVault.BondPosted(500e6, 1_500e6);
        vault.postBond(500e6);
        vm.stopPrank();
        assertEq(vault.bondBalance(), 1_500e6);
    }

    function testFuzz_bond_postOnlyCurator(address caller) public {
        vm.assume(caller != curator);
        vm.prank(caller);
        vm.expectRevert(IOathVault.NotCurator.selector);
        vault.postBond(1);
    }

    // ---------------------------------------------------------------- withdrawBond

    function test_bond_withdrawPaysCurator() public {
        vm.startPrank(curator);
        vault.postBond(3_000e6);
        uint256 before = _balance1(curator);
        vm.expectEmit(false, false, false, true, address(vault));
        emit IOathVault.BondWithdrawn(1_000e6, 2_000e6);
        vault.withdrawBond(1_000e6);
        vm.stopPrank();

        assertEq(vault.bondBalance(), 2_000e6);
        assertEq(_balance1(curator) - before, 1_000e6, "paid to the curator");
        assertEq(currency1.balanceOf(address(vault)), 2_000e6);
    }

    function test_bond_withdrawAll() public {
        vm.startPrank(curator);
        vault.postBond(3_000e6);
        vault.withdrawBond(3_000e6);
        vm.stopPrank();
        assertEq(vault.bondBalance(), 0);
        assertEq(currency1.balanceOf(address(vault)), 0);
    }

    /// @dev The curator cannot take more than the bond, even when the vault holds depositors' currency1.
    function test_bond_withdrawNoMoreThanBond() public {
        _deposit(alice, 1e18, 1e18);
        vm.startPrank(curator);
        vault.postBond(3_000e6);
        vm.expectRevert(IOathVault.InsufficientBond.selector);
        vault.withdrawBond(3_000e6 + 1);
        vm.stopPrank();
    }

    function testFuzz_bond_withdrawOnlyCurator(address caller) public {
        vm.assume(caller != curator);
        vm.prank(curator);
        vault.postBond(1_000e6);
        vm.prank(caller);
        vm.expectRevert(IOathVault.NotCurator.selector);
        vault.withdrawBond(1);
    }

    // ---------------------------------------------------------------- the bond is never depositors' money

    /// @dev A bond posted before any deposit plays no part in pricing: the first deposit is `sqrt(a0·a1)` and the
    ///      next one is priced against holdings without the bond.
    function test_bond_excludedFromDepositPricing() public {
        vm.prank(curator);
        vault.postBond(5e18);
        (uint256 first,,) = _deposit(alice, 1e18, 4e18);
        assertEq(first, 2e18 - 1_000, "first deposit ignores the bond");

        (uint256 shares,, uint256 used1) = _deposit(bob, 1e18, 4e18);
        assertEq(shares, 2e18, "priced on holdings 1e18 / 4e18, not on 9e18 currency1");
        assertEq(used1, 4e18);
    }

    /// @dev Redeeming every share pays out depositors' holdings only; the bond stays whole.
    function test_bond_untouchedByWithdrawals() public {
        _deposit(alice, 1e18, 1e18);
        vm.prank(curator);
        vault.postBond(3_000e6);
        uint256 held = vault.balanceOf(alice);

        vm.prank(alice);
        (, uint256 out1) = vault.withdraw(held, 0, 0, alice);
        assertEq(out1, 1e18 - 1_000, "only depositors' currency1");
        assertEq(vault.bondBalance(), 3_000e6);
        assertEq(currency1.balanceOf(address(vault)), 3_000e6 + 1_000, "bond + dead share's part");
    }

    /// @dev The curator can also be a depositor; deposits never add to the bond and bond withdrawals never touch
    ///      the curator's shares.
    function test_bond_separateFromCuratorShares() public {
        _give(curator, 1e30, 0);
        (uint256 shares,,) = _deposit(curator, 1e18, 1e18);
        vm.startPrank(curator);
        vault.postBond(2e18);
        vault.withdrawBond(2e18);
        vm.stopPrank();
        assertEq(vault.bondBalance(), 0, "deposit did not become bond");
        assertEq(vault.balanceOf(curator), shares, "shares untouched");
        assertEq(vault.idle1(), 1e18);
    }

    /// @dev currency1 sent straight to the vault belongs to depositors, not to the bond.
    function test_bond_donationIsNotBond() public {
        vm.prank(curator);
        vault.postBond(1_000e6);
        vm.prank(bob);
        currency1.transfer(address(vault), 7e6);
        assertEq(vault.bondBalance(), 1_000e6);
        assertEq(vault.idle1(), 7e6);

        vm.prank(curator);
        vm.expectRevert(IOathVault.InsufficientBond.selector);
        vault.withdrawBond(1_000e6 + 1);
    }

    /// @dev Over random deposits, withdrawals, bond posts and bond withdrawals: the vault always holds at least
    ///      the bond (I1), `idle1` is exactly the rest, and the curator never gets back more than was posted.
    function testFuzz_bond_alwaysCovered(uint256 seed) public {
        uint256 posted;
        uint256 returned;
        for (uint256 i; i < 24; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 action = r % 4;
            if (action == 0) {
                vm.prank(r % 8 == 0 ? bob : alice);
                try vault.deposit(1 + (r >> 8) % 1e24, 1 + (r >> 96) % 1e24, 0, alice) {} catch {}
            } else if (action == 1) {
                uint256 held = vault.balanceOf(alice);
                if (held != 0) {
                    vm.prank(alice);
                    vault.withdraw(1 + (r >> 8) % held, 0, 0, alice);
                }
            } else if (action == 2) {
                uint256 amount = (r >> 8) % 1e24;
                vm.prank(curator);
                vault.postBond(amount);
                posted += amount;
            } else {
                uint256 bond = vault.bondBalance();
                uint256 amount = bond == 0 ? 0 : (r >> 8) % (bond + 1);
                vm.prank(curator);
                vault.withdrawBond(amount);
                returned += amount;
            }

            uint256 balance1 = currency1.balanceOf(address(vault));
            assertGe(balance1, vault.bondBalance(), "I1: balance1 >= bond");
            assertEq(vault.idle1(), balance1 - vault.bondBalance(), "idle1 = balance1 - bond");
            assertEq(vault.bondBalance(), posted - returned, "bond = posted - returned");
        }
    }
}
