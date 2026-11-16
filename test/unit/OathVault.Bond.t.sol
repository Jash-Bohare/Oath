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
}
