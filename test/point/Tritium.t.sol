// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Tritium} from "../../src/point/Tritium.sol";

contract TritiumTest is Test {
    Tritium internal t;
    address internal alice = address(0xA11CE);

    function setUp() public {
        t = new Tritium();
    }

    function test_NameAndSymbol() public view {
        assertEq(t.name(), "Tritium");
        assertEq(t.symbol(), "T");
    }

    /// The bug this contract exists to fix: ITERXP.mint() set penalties[to] = 0
    /// BEFORE subtracting it, so `amount - penalties[to]` subtracted nothing and
    /// the penalty silently vanished.
    function test_PartialPenaltyIsDeductedNotForgiven() public {
        t.fine(alice, 100);
        uint256 minted = t.mint(alice, 150);
        assertEq(minted, 50, "150 earned against a 100 penalty must mint 50");
        assertEq(t.balanceOf(alice), 50);
        assertEq(t.penaltyOf(alice), 0, "the penalty is consumed");
    }

    function test_PenaltyLargerThanEarningsMintsNothing() public {
        t.fine(alice, 200);
        uint256 minted = t.mint(alice, 50);
        assertEq(minted, 0);
        assertEq(t.balanceOf(alice), 0);
        assertEq(t.penaltyOf(alice), 150, "the remaining penalty carries forward");
    }

    function test_NoPenaltyMintsFullAmount() public {
        uint256 minted = t.mint(alice, 300);
        assertEq(minted, 300);
        assertEq(t.balanceOf(alice), 300);
    }

    function test_OnlyMinterCanMint() public {
        vm.prank(alice);
        vm.expectRevert();
        t.mint(alice, 1);
    }

    function test_BurnReducesSupply() public {
        t.mint(alice, 100);
        t.grantRole(t.BURNER_ROLE(), address(this));
        t.burn(alice, 40);
        assertEq(t.balanceOf(alice), 60);
        assertEq(t.totalSupply(), 60);
    }
}
