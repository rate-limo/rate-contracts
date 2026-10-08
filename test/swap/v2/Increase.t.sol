// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {V2Base} from "./V2Base.sol";
import {IBandPool} from "../../../src/swap/interfaces/IBandPool.sol";
import {IBandPositionManager} from "../../../src/swap/interfaces/IBandPositionManager.sol";

/**
 * A top-up lands in the SAME token. The band's clock blends share-weighted, and fees the
 * old capital already vested are locked into `owed` first, so the blend can neither
 * re-age them nor let fresh capital borrow the old capital's vesting.
 */
contract V2IncreaseTest is V2Base {
    function test_aTopUpGoesIntoTheSameToken() public {
        uint256 id = _mintBase(alice, _b(0, 1), 100e18);
        uint256 next = positionManager.nextTokenId();
        uint128 before0 = _sharesIn(id, 0);

        uint128[] memory added = _topUp(alice, id, _b(0), _u(50e18), _u(0));

        assertEq(positionManager.nextTokenId(), next, "no new id");
        assertEq(positionManager.balanceOf(alice, id), 1, "still one token");
        assertEq(_sharesIn(id, 0), before0 + added[0], "the slot grew by what was minted");
        assertEq(added[0], 50e18);
        assertEq(_sharesIn(id, 1), 100e18, "the band not topped up is untouched");
    }

    function test_aTopUpMayAddABandTheTokenDidNotHold() public {
        uint256 id = _mintBase(alice, _b(0), 100e18);
        assertEq(pool.bandMaskOf(id), 0x1);

        _topUp(alice, id, _b(1, 2), _fill(2, 10e18), _fill(2, 0));

        assertEq(pool.bandMaskOf(id), 0x7);
        IBandPositionManager.PositionView memory v = positionManager.positionOf(id);
        assertEq(v.bands.length, 3);
        assertEq(v.bands[2].shares, 10e18);
        assertEq(v.bands[2].createdAt, block.timestamp, "a new band starts its own clock");
    }

    /// createdAt = (c*S + t*dS) / (S + dS), exactly.
    function test_theClockBlendsShareWeighted() public {
        uint256 id = _mintBase(alice, _b(0), 1_000e18);
        uint64 c = _slot(id, 0).createdAt;
        uint256 s = _sharesIn(id, 0);

        vm.warp(block.timestamp + 400);
        uint128[] memory added = _topUp(alice, id, _b(0), _u(3_000e18), _u(0));

        uint256 expected = (uint256(c) * s + block.timestamp * added[0]) / (s + added[0]);
        assertEq(_slot(id, 0).createdAt, expected);
        assertEq(expected, c + 300, "a 3x top-up 400s later lands 3/4 of the way to now");
    }

    function test_aBigFreshTopUpCannotBorrowTheOldCapitalsVesting() public {
        uint256 id = _mintBase(alice, _b(0), 10e18);
        vm.warp(block.timestamp + 600); // fully vested
        assertEq(_slot(id, 0).vestedNum, 1e8);
        _topUp(alice, id, _b(0), _u(990e18), _u(0));
        assertLt(_slot(id, 0).vestedNum, 2e6, "99% fresh capital sits near the start of the ramp");
    }

    /// The vested part of pending is locked into owed BEFORE the clock moves.
    function test_vestedFeesAreLockedIntoOwedBeforeTheBlend() public {
        uint256 id = _mintBase(alice, _b(0), 1_000e18);
        _buy(trader1, 1_000e18);
        vm.warp(block.timestamp + 300); // half-way up the ramp

        IBandPool.BandView memory v0 = _slot(id, 0);
        assertGt(v0.pendingBase, 0, "the band earned");
        assertGt(v0.vestedBase, 0, "and some of it vested");
        assertLt(v0.vestedBase, v0.pendingBase, "and some did not");
        (uint256 owed0,) = _owed(id);
        assertEq(owed0, 0);

        // The swap left quote in the band, so the top-up is two-sided at its ratio.
        (uint256 rb, uint256 rq) = pool.bandReserves(0);
        _topUp(alice, id, _b(0), _u(rb * 3), _u(rq * 3 + 1));

        IBandPool.BandView memory v1 = _slot(id, 0);
        (uint256 owed1,) = _owed(id);
        assertEq(owed1, v0.vestedBase, "exactly the vested part moved to owed");
        assertEq(v1.pendingBase, v0.pendingBase - v0.vestedBase, "the unvested part stays pending");
        assertLt(v1.vestedNum, v0.vestedNum, "the blend moved the clock back");
        assertEq(owed1 + v1.pendingBase, v0.pendingBase, "a top-up forfeits nothing");
    }

    function test_aTopUpAcrossBandsIsOneTransaction() public {
        uint256 id = _mintBase(alice, _b(0, 1, 2), 100e18);
        uint256 spent = token1.balanceOf(alice);
        uint128[] memory added = _topUp(alice, id, _b(0, 1, 2), _u(1e18, 2e18, 3e18), _fill(3, 0));
        assertEq(spent - token1.balanceOf(alice), 6e18);
        assertEq(added[0], 1e18);
        assertEq(added[2], 3e18);
        assertEq(_sharesIn(id, 2), 103e18);
    }

    function test_aTopUpHonoursMinSharesAndDeadline() public {
        uint256 id = _mintBase(alice, _b(0), 100e18);
        uint128[] memory mins = _mins(1);
        mins[0] = 10e18 + 1;
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBandPositionManager.SharesBelowMinimum.selector, uint8(0), uint128(10e18), uint128(10e18 + 1)
            )
        );
        positionManager.increaseLiquidity(id, _b(0), _u(10e18), _u(0), mins, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(IBandPositionManager.DeadlinePassed.selector, block.timestamp - 1, block.timestamp)
        );
        positionManager.increaseLiquidity(id, _b(0), _u(10e18), _u(0), _mins(1), block.timestamp - 1);

        vm.expectRevert(IBandPositionManager.BandsNotAscending.selector);
        positionManager.increaseLiquidity(id, _b(1, 0), _fill(2, 1e18), _fill(2, 0), _mins(2), block.timestamp);
        vm.stopPrank();
    }

    /// Topping up a token that was never minted has no holder, so nobody is approved.
    function test_aTopUpOfAnUnmintedTokenIsRefused() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBandPositionManager.NotOwnerOrApproved.selector, alice, 42));
        positionManager.increaseLiquidity(42, _b(0), _u(1e18), _u(0), _mins(1), block.timestamp);
    }
}
