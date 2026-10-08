// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {V2Base} from "./V2Base.sol";
import {IBandPool} from "../../../src/swap/interfaces/IBandPool.sol";
import {IBandPositionManager} from "../../../src/swap/interfaces/IBandPositionManager.sol";

/**
 * `collect` pays `owed` plus the vested part of every band's pending, and NEVER forfeits:
 * the unvested remainder stays on the slot and keeps vesting. `burn` destroys a token
 * only once nothing is left in it.
 */
contract V2CollectTest is V2Base {
    function _earning() internal returns (uint256 id) {
        id = _mintBase(alice, _b(0, 1), 1_000e18);
        // Large enough to walk out of band 0 into band 1, so both slots earn.
        _buy(trader1, 150_000e18);
        assertGt(_slot(id, 0).pendingBase, 0, "band 0 earned");
        assertGt(_slot(id, 1).pendingBase, 0, "band 1 earned");
    }

    function test_collectPaysTheVestedPartAndForfeitsNothing() public {
        uint256 id = _earning();
        (uint256 accrued,) = _accrued(id);
        vm.warp(block.timestamp + 300);
        (uint256 claimable,) = _claimable(id);
        assertGt(claimable, 0);
        assertLt(claimable, accrued);

        uint256 bal = token1.balanceOf(alice);
        uint256 protocolBefore = pool.protocolFeesBase();
        vm.prank(alice);
        (uint256 paid,) = positionManager.collect(id, alice);
        assertEq(paid, claimable, "exactly what was vested");
        assertEq(token1.balanceOf(alice) - bal, paid);

        (uint256 left,) = _accrued(id);
        assertEq(left, accrued - paid, "the unvested rest is still there");
        assertEq(pool.protocolFeesBase(), protocolBefore, "and none of it went to the protocol");

        // It keeps vesting, and a later collect pays it.
        vm.warp(block.timestamp + 600);
        vm.prank(alice);
        (uint256 paid2,) = positionManager.collect(id, alice);
        assertApproxEqAbs(paid + paid2, accrued, 2, "over time collect pays everything accrued");
        (uint256 none,) = _accrued(id);
        assertLe(none, 2, "only rounding dust can remain");
    }

    function test_collectPaysOwedPlusTheVestedPending() public {
        uint256 id = _earning();
        vm.warp(block.timestamp + 300);
        // A top-up locks the vested part into owed.
        (uint256 rb, uint256 rq) = pool.bandReserves(0);
        _topUp(alice, id, _b(0), _u(rb / 10), _u(rq / 10 + 1));
        (uint256 owed,) = _owed(id);
        assertGt(owed, 0, "owed is non-zero");

        vm.warp(block.timestamp + 100);
        (uint256 claimable,) = _claimable(id);
        assertGt(claimable, owed, "and pending vested further on top of it");

        vm.prank(alice);
        (uint256 paid,) = positionManager.collect(id, alice);
        assertEq(paid, claimable);
        (uint256 owedAfter,) = _owed(id);
        assertEq(owedAfter, 0);
    }

    function test_collectCanPayAnotherRecipientAndEmitsCollect() public {
        uint256 id = _earning();
        vm.warp(block.timestamp + 601);
        (uint256 cb, uint256 cq) = _claimable(id);
        vm.expectEmit(true, true, false, true, address(pool));
        emit IBandPool.Collect(id, bob, cb, cq);
        uint256 bal = token1.balanceOf(bob);
        vm.prank(alice);
        positionManager.collect(id, bob);
        assertEq(token1.balanceOf(bob) - bal, cb);
    }

    // ------------------------------------------------------------------- burn

    function test_burnRevertsWhileAnyBandRemains() public {
        uint256 id = _mintBase(alice, _b(0, 1, 2), 100e18);
        vm.prank(alice);
        positionManager.decreaseBand(id, 0, type(uint128).max, 0, 0, alice, block.timestamp);
        vm.prank(alice);
        positionManager.decreaseBand(id, 1, type(uint128).max, 0, 0, alice, block.timestamp);
        assertEq(pool.bandMaskOf(id), 0x4, "one band left");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBandPositionManager.PositionNotEmpty.selector, id));
        positionManager.burn(id);
    }

    /**
     * `burn` also refuses a token whose `owed` is non-zero, but no manager path reaches
     * mask == 0 with owed > 0: `decrease` and `decreaseBand` pay owed as they finish, and
     * `move` never empties a position (it lands the capital in another band). So that
     * branch is defensive; this pins the reachable half and the exit that clears both.
     */
    function test_aFullExitLeavesNothingOwedSoTheBurnSucceeds() public {
        uint256 id = _earning();
        vm.warp(block.timestamp + 300);
        _decreaseAll(alice, id, 10_000);
        (uint256 ob, uint256 oq) = _owed(id);
        assertEq(ob + oq, 0, "the exit paid owed");
        vm.prank(alice);
        positionManager.collect(id, alice); // a no-op, and harmless
        vm.prank(alice);
        positionManager.burn(id);

        assertEq(positionManager.balanceOf(alice, id), 0);
        assertEq(positionManager.poolOf(id), address(0));
        assertEq(positionManager.holderOf(id), address(0));
        assertEq(positionManager.positionOf(id).pool, address(0));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBandPositionManager.NotOwnerOrApproved.selector, alice, id));
        positionManager.collect(id, alice);
    }

    function test_aBurntIdIsNeverReissued() public {
        uint256 id = _mintBase(alice, _b(0), 1e18);
        _decreaseAll(alice, id, 10_000);
        vm.prank(alice);
        positionManager.burn(id);
        uint256 next = _mintBase(alice, _b(0), 1e18);
        assertGt(next, id);
    }
}
