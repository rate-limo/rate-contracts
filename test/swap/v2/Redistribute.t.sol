// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {V2Base} from "./V2Base.sol";
import {BandPool} from "../../../src/swap/BandPool.sol";
import {PoolPositions} from "../../../src/swap/PoolPositions.sol";
import {IBandPool} from "../../../src/swap/interfaces/IBandPool.sol";
import {IBandPositionManager} from "../../../src/swap/interfaces/IBandPositionManager.sol";

/**
 * Changing a position's distribution without the capital leaving the pool.
 *
 * `moveLiquidity` lifts shares out of one band and prices them into another; only what
 * the receiving band's ratio cannot absorb is refunded, and only that refunded part
 * forfeits (by value at the anchor) -- a move is not a withdrawal, so the rest of the
 * unvested fee travels with the capital, and so does its age. `redistribute` solves a
 * target distribution into such moves.
 */
contract V2RedistributeTest is V2Base {
    uint256 internal constant ONE_SHARE_IN_QUOTE = 100; // 1 base wei at the 100.0 listing price

    function _pairBalances() internal view returns (uint256, uint256) {
        return (token1.balanceOf(address(pool)), token2.balanceOf(address(pool)));
    }

    function _move(uint256 id, uint8 from, uint8 to, uint128 shares) internal returns (uint128 sharesIn, uint256 rb, uint256 rq) {
        vm.prank(alice);
        return positionManager.moveLiquidity(id, from, to, shares, 0, alice, block.timestamp);
    }

    // ------------------------------------------------------------------ move

    function test_aMoveKeepsTheCapitalInThePool() public {
        uint256 id = _mintBase(alice, _b(0, 1), 1_000e18);
        (uint256 pb, uint256 pq) = _pairBalances();
        uint256 bal = token1.balanceOf(alice);

        (uint128 sharesIn, uint256 rb, uint256 rq) = _move(id, 0, 1, 400e18);

        assertEq(sharesIn, 400e18, "same ratio, one for one");
        assertEq(rb + rq, 0, "nothing refunded");
        (uint256 pb2, uint256 pq2) = _pairBalances();
        assertEq(pb2, pb, "no base left the pool");
        assertEq(pq2, pq, "no quote left the pool");
        assertEq(token1.balanceOf(alice), bal);
        assertEq(_sharesIn(id, 0), 600e18);
        assertEq(_sharesIn(id, 1), 1_400e18);
    }

    function test_theCapitalsAgeTravelsWithIt() public {
        _mintBase(bob, _b(2), 1_000e18); // band 2 is live, held by someone else
        uint256 id = _mintBase(alice, _b(0), 1_000e18);
        uint64 born = _slot(id, 0).createdAt;
        vm.warp(block.timestamp + 500);

        _move(id, 0, 2, 1_000e18);
        assertEq(_slot(id, 2).createdAt, born, "moved capital keeps its age, not now");
        assertEq(pool.bandMaskOf(id), 0x4, "the source emptied");

        // Into a band the token already holds: the SOURCE's age blends in, share-weighted.
        uint256 id2 = _mintBase(alice, _b(0), 1_000e18);
        vm.warp(block.timestamp + 400);
        _topUp(alice, id2, _b(1), _u(3_000e18), _u(0)); // band 1 is 400s younger
        vm.warp(block.timestamp + 100);
        uint64 src = _slot(id2, 0).createdAt;
        IBandPool.BandView memory dst = _slot(id2, 1);
        (uint128 minted,,) = _move(id2, 0, 1, 1_000e18);
        uint256 expected = (uint256(dst.createdAt) * dst.shares + uint256(src) * minted) / (dst.shares + minted);
        assertEq(_slot(id2, 1).createdAt, expected);
        assertEq(expected, uint256(src) + 300, "1:3 blend of a 400s gap");
    }

    /**
     * Band 0 holds both sides after a buy; band 1 holds only base, so a move from 0 to 1
     * cannot place the quote and refunds it. That refunded value -- and only it -- forfeits
     * its share of the moved unvested fees, rounded up, to band 0's other shares.
     */
    function test_onlyTheRefundedPartForfeitsByValue() public {
        uint256 id = _mintBase(alice, _b(0, 1), 1_000e18);
        uint256 other = _mintBase(bob, _b(0), 1_000e18);
        _buy(trader1, 10_000e18); // fills band 0 only
        IBandPool.BandView memory src = _slot(id, 0);
        assertGt(src.quoteOwned, 0, "band 0 is two-sided");
        assertGt(src.pendingBase, 0, "and carries unvested fees");
        (, uint256 band1Quote) = pool.bandReserves(1);
        assertEq(band1Quote, 0, "band 1 is base-only");
        (uint256 otherBefore,) = _accrued(other);
        assertEq(_slot(id, 1).pendingBase, 0, "band 1 never traded");
        uint256 quoteBal = token2.balanceOf(alice);

        (, uint256 rb, uint256 rq) = _move(id, 0, 1, src.shares);

        assertEq(rb, 0);
        assertEq(rq, src.quoteOwned, "the quote band 1 cannot hold comes back");
        assertEq(token2.balanceOf(alice) - quoteBal, rq, "to refundTo");

        uint256 price = pool.anchorPrice();
        uint256 valueOut = src.quoteOwned + book.convert(price, src.baseOwned, true);
        uint256 forfeit = Math.mulDiv(src.pendingBase, rq, valueOut, Math.Rounding.Ceil);
        assertGt(forfeit, 0);
        assertLt(forfeit, src.pendingBase, "a partial refund forfeits partially");

        IBandPool.BandView memory landed = _slot(id, 1);
        assertEq(landed.pendingBase, src.pendingBase - forfeit, "the rest travelled with the capital");
        (uint256 otherAfter,) = _accrued(other);
        assertApproxEqAbs(otherAfter - otherBefore, forfeit, 1, "the other LP in band 0 received it");
    }

    function test_moveRefusesTheSameBandAClosedBandAndAShortfall() public {
        uint256 id = _mintBase(alice, _b(0, 1), 1_000e18);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(BandPool.SameBand.selector, uint8(1)));
        positionManager.moveLiquidity(id, 1, 1, 1e18, 0, alice, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(IBandPositionManager.SharesBelowMinimum.selector, uint8(1), uint128(1e18), uint128(1e18 + 1))
        );
        positionManager.moveLiquidity(id, 0, 1, 1e18, 1e18 + 1, alice, block.timestamp);
        vm.stopPrank();

        pool.setBandOpen(2, false); // this contract listed the pair, so it is the creator
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PoolPositions.BandClosed.selector, uint8(2)));
        positionManager.moveLiquidity(id, 0, 2, 1e18, 0, alice, block.timestamp);
    }

    // ------------------------------------------------------------ redistribute

    function _rp(uint256 id, uint8[] memory bands, uint16[] memory targets)
        internal
        view
        returns (IBandPositionManager.RedistributeParams memory)
    {
        return IBandPositionManager.RedistributeParams({
            tokenId: id,
            bands: bands,
            targetBps: targets,
            minSharesAfter: _mins(bands.length),
            refundTo: alice,
            deadline: block.timestamp
        });
    }

    /**
     * Same-ratio bands, so every move is one for one and the only error is the floor on
     * each move's share count: at most one base wei per move, i.e. ONE_SHARE_IN_QUOTE per
     * move in value. Two moves here, so 2 * 100 wei of quote is the whole tolerance.
     */
    function test_redistributeHitsTheTargetsByValue() public {
        uint256 id = _mintBase(alice, _b(0, 1, 2), 1_000e18);
        uint256 total = _positionValue(id);
        (uint256 pb, uint256 pq) = _pairBalances();

        vm.prank(alice);
        (uint256 rb, uint256 rq) = positionManager.redistribute(_rp(id, _b(0, 1, 2), _bps(6_000, 3_000, 1_000)));

        assertEq(rb + rq, 0);
        (uint256 pb2, uint256 pq2) = _pairBalances();
        assertEq(pb2, pb, "capital never left");
        assertEq(pq2, pq);
        uint256[3] memory target = [total * 6_000 / 10_000, total * 3_000 / 10_000, total * 1_000 / 10_000];
        for (uint8 i = 0; i < 3; i++) {
            assertApproxEqAbs(_valueOf(_slot(id, i)), target[i], 2 * ONE_SHARE_IN_QUOTE, "band on target");
        }
        assertApproxEqAbs(_positionValue(id), total, 2 * ONE_SHARE_IN_QUOTE, "value conserved");
    }

    function test_aHeldBandLeftOutIsEmptied() public {
        uint256 id = _mintBase(alice, _b(0, 1, 2), 1_000e18);
        uint256 total = _positionValue(id);
        vm.expectEmit(true, false, false, true, address(positionManager));
        emit IBandPositionManager.Redistributed(id, _b(0, 1), _bps(5_000, 5_000));
        vm.prank(alice);
        positionManager.redistribute(_rp(id, _b(0, 1), _bps(5_000, 5_000)));

        assertEq(pool.bandMaskOf(id), 0x3, "band 2 is gone from the token");
        assertApproxEqAbs(_valueOf(_slot(id, 0)), total / 2, 2 * ONE_SHARE_IN_QUOTE);
        assertApproxEqAbs(_valueOf(_slot(id, 1)), total / 2, 2 * ONE_SHARE_IN_QUOTE);
    }

    function test_redistributeIntoABandNotYetHeld() public {
        _mintBase(bob, _b(2), 1_000e18);
        uint256 id = _mintBase(alice, _b(0), 1_000e18);
        uint256 total = _positionValue(id);
        vm.prank(alice);
        positionManager.redistribute(_rp(id, _b(0, 2), _bps(2_500, 7_500)));
        assertEq(pool.bandMaskOf(id), 0x5);
        assertApproxEqAbs(_valueOf(_slot(id, 2)), total * 3 / 4, ONE_SHARE_IN_QUOTE);
    }

    /**
     * When the bands' ratios differ the solver cannot place everything: the part the
     * destination refuses is refunded, and the result misses the target by that value.
     * This pins the miss and where the value went, rather than widening a tolerance.
     */
    function test_differentRatiosRefundTheUnplaceablePart() public {
        uint256 id = _mintBase(alice, _b(0, 1), 1_000e18);
        _buy(trader1, 10_000e18); // band 0 two-sided, band 1 base-only
        uint256 total = _positionValue(id);
        uint256 quoteBal = token2.balanceOf(alice);

        vm.prank(alice);
        (uint256 rb, uint256 rq) = positionManager.redistribute(_rp(id, _b(1), _toBps(10_000)));

        assertEq(rb, 0);
        assertGt(rq, 0, "band 1 cannot hold quote");
        assertEq(token2.balanceOf(alice) - quoteBal, rq, "refunded to refundTo");
        assertEq(pool.bandMaskOf(id), 0x2, "everything that stayed is in band 1");
        assertApproxEqAbs(_positionValue(id) + rq, total, ONE_SHARE_IN_QUOTE, "stayed + refunded = before");
    }

    function _toBps(uint16 a) internal pure returns (uint16[] memory r) {
        r = new uint16[](1);
        r[0] = a;
    }

    function test_targetsMustSumToTheWhole() public {
        uint256 id = _mintBase(alice, _b(0, 1), 1_000e18);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBandPositionManager.TargetsNotWhole.selector, 9_999));
        positionManager.redistribute(_rp(id, _b(0, 1), _bps(5_000, 4_999)));
        vm.expectRevert(abi.encodeWithSelector(IBandPositionManager.TargetsNotWhole.selector, 10_001));
        positionManager.redistribute(_rp(id, _b(0, 1), _bps(5_000, 5_001)));
        vm.expectRevert(IBandPositionManager.BandsNotAscending.selector);
        positionManager.redistribute(_rp(id, _b(1, 0), _bps(5_000, 5_000)));
        IBandPositionManager.RedistributeParams memory p = _rp(id, _b(0, 1), _bps(5_000, 5_000));
        p.minSharesAfter = _mins(1);
        vm.expectRevert(IBandPositionManager.LengthMismatch.selector);
        positionManager.redistribute(p);
        p = _rp(id, _b(0, 1), _bps(5_000, 5_000));
        p.deadline = block.timestamp - 1;
        vm.expectRevert(
            abi.encodeWithSelector(IBandPositionManager.DeadlinePassed.selector, block.timestamp - 1, block.timestamp)
        );
        positionManager.redistribute(p);
        vm.stopPrank();
    }

    function test_minSharesAfterIsAFloorPerBand() public {
        uint256 id = _mintBase(alice, _b(0, 1), 1_000e18);
        IBandPositionManager.RedistributeParams memory p = _rp(id, _b(0, 1), _bps(2_000, 8_000));
        p.minSharesAfter[1] = 1_600e18 + 1;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBandPositionManager.SharesBelowMinimum.selector, uint8(1), uint128(1_600e18), uint128(1_600e18 + 1)
            )
        );
        positionManager.redistribute(p);

        p.minSharesAfter[1] = 1_600e18;
        vm.prank(alice);
        positionManager.redistribute(p);
        assertEq(_sharesIn(id, 1), 1_600e18);
    }
}
