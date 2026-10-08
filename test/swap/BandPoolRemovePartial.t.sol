// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandPool} from "../../src/swap/BandPool.sol";
import {IBandPool} from "../../src/swap/interfaces/IBandPool.sol";
import {BandPoolBase} from "./BandPoolBase.sol";

/**
 * Withdrawing part of a position, without leaving it.
 *
 * An LP who wants a tenth back must not have to exit and deposit again: two
 * transactions, a band ratio that moved between them, and capital whose age restarts
 * the vesting ramp the first deposit had already served. v2 has two partial paths --
 * `decrease(bps)` takes the same fraction of EVERY band, `decreaseBand(shares)` takes a
 * share count from one band.
 *
 * These pin the arithmetic that makes it safe: it never pays more than the position
 * owns, it leaves the rest of the band untouched, and the position survives with its
 * token so its age survives with it.
 *
 * The boundary cases run in OPPOSITE directions on purpose. On `decreaseBand`,
 * `type(uint128).max` is everything (clamped) and `0` is nothing. On `decrease`, 10,000
 * bps is everything and 0 bps REVERTS. Either way a caller whose percentage arithmetic
 * rounds down must never get an emptied position.
 */
contract BandPoolRemovePartialTest is BandPoolBase {
    function _decreaseBand(uint256 id, uint8 band, uint128 shares) internal returns (uint256 b, uint256 q) {
        vm.prank(pm);
        return pool.decreaseBand(id, band, shares, pm);
    }

    function test_halfTheSharesPayHalfTheReserve() public {
        uint256 id = _addTo(0, 1_000e18);
        (uint256 br,) = pool.bandReserves(0);
        uint128 half = _view(id).shares / 2;

        (uint256 baseOut,) = _decreaseBand(id, 0, half);

        assertApproxEqRel(baseOut, br / 2, 1e12, "half the shares, half the reserve");
        (uint256 left,) = pool.bandReserves(0);
        assertApproxEqRel(left, br / 2, 1e12, "the rest stays in the band");
    }

    function test_halfTheBpsPayHalfOfEveryBand() public {
        uint256 id = _addTo(0, 1_000e18);
        _topUp(id, 1, 3_000e18);

        (uint256 baseOut,) = _decrease(id, 5_000, pm);

        assertEq(baseOut, 2_000e18, "half of each band, in one call");
        (uint256 r0,) = pool.bandReserves(0);
        (uint256 r1,) = pool.bandReserves(1);
        assertEq(r0, 500e18);
        assertEq(r1, 1_500e18);
        assertEq(pool.bandMaskOf(id), 3, "both bands still held");
    }

    function test_thePositionSurvivesAndKeepsItsRemainder() public {
        uint256 id = _addTo(0, 1_000e18);
        IBandPool.BandView memory before = _view(id);

        _decreaseBand(id, 0, before.shares / 4);

        IBandPool.BandView memory after_ = _view(id);
        assertEq(after_.shares, before.shares - before.shares / 4, "three quarters still held");
        assertEq(after_.createdAt, before.createdAt, "and its age with them");
    }

    function test_askingForMoreThanYouHoldTakesWhatYouHold() public {
        // Clamped rather than reverted: a caller computing a fraction off a view
        // races the fills that move the band between the read and the send, and
        // failing a withdrawal for being a share too large is the most annoying
        // possible refusal.
        uint256 id = _addTo(0, 1_000e18);
        (uint256 br,) = pool.bandReserves(0);

        (uint256 baseOut,) = _decreaseBand(id, 0, type(uint128).max);

        assertEq(baseOut, br, "it paid the whole position, not more");
        assertEq(_view(id).shares, 0, "and closed it");
        assertEq(pool.bandMaskOf(id), 0);
    }

    function test_zeroSharesMovesNothing() public {
        uint256 id = _addTo(0, 1_000e18);
        (uint256 br,) = pool.bandReserves(0);

        (uint256 baseOut, uint256 quoteOut) = _decreaseBand(id, 0, 0);

        assertEq(baseOut, 0);
        assertEq(quoteOut, 0);
        (uint256 after_,) = pool.bandReserves(0);
        assertEq(after_, br, "the band is untouched");
        assertEq(_view(id).shares, 1_000e18);
    }

    function test_zeroBpsRevertsRatherThanEmptying() public {
        uint256 id = _addTo(0, 1_000e18);
        vm.prank(pm);
        vm.expectRevert(abi.encodeWithSelector(BandPool.BadBps.selector, uint16(0)));
        pool.decrease(id, 0, pm);
        assertEq(_view(id).shares, 1_000e18, "the position is whole");
    }

    function test_oneLpPartialExitDoesNotTouchAnother() public {
        uint256 a = _addTo(0, 1_000e18);
        uint256 b = _addTo(0, 1_000e18);
        uint128 bShares = _view(b).shares;
        // Read BEFORE the prank: an argument is evaluated first, so a view call
        // here would consume the prank and the write would arrive unpranked.
        uint128 halfOfA = _view(a).shares / 2;

        _decreaseBand(a, 0, halfOfA);

        assertEq(_view(b).shares, bShares, "the other LP is untouched");
    }

    function test_partialThenFullPaysTheSameTotalAsOneFullExit() public {
        // The property that matters for a money path: splitting a withdrawal must
        // not create or destroy value against taking it in one go.
        uint256 split = _addTo(0, 1_000e18);
        uint256 whole = _addTo(1, 1_000e18);

        (uint256 firstOut,) = _decreaseBand(split, 0, _view(split).shares / 3);
        (uint256 restOut,) = _decreaseBand(split, 0, type(uint128).max);
        (uint256 wholeOut,) = _decreaseBand(whole, 1, type(uint128).max);

        assertApproxEqRel(firstOut + restOut, wholeOut, 1e12, "split exit pays the same as one exit");
    }

    function test_partialExitAfterASwapReturnsBothSides() public {
        uint256 id = _addTo(0, 1_000e18);
        _swap(100e18);
        (uint256 br, uint256 qr) = pool.bandReserves(0);

        (uint256 baseOut, uint256 quoteOut) = _decrease(id, 5_000, pm);

        assertApproxEqRel(baseOut, br / 2, 1e12, "half of what the band now holds in base");
        assertApproxEqRel(quoteOut, qr / 2, 1e12, "and half of the quote the swap brought in");
    }

    function test_oneFunctionTakesTheRestAndSaysWhatIsLeftEachTime() public {
        // Two calls to one function on one position: the first reduces it, the second
        // closes it, and the event distinguishes them by the shares it reports burning.
        uint256 id = _addTo(0, 1_000e18);
        uint128 held = _view(id).shares;
        uint128 third = held / 3;

        uint8[] memory bands = new uint8[](1);
        uint128[] memory removed = new uint128[](1);
        removed[0] = third;
        vm.expectEmit(true, false, false, true, address(pool));
        emit IBandPool.DecreaseLiquidity(id, bands, removed, _baseShareOf(0, third), 0, 0, 0, false);
        _decreaseBand(id, 0, third);

        uint128 rest = _view(id).shares;
        assertEq(rest, held - third, "the remainder is exactly what was not taken");

        _decreaseBand(id, 0, type(uint128).max);
        (IBandPool.BandView[] memory all,,) = pool.positionView(id);
        assertEq(all.length, 0, "the second call closed it");

        // And a third call on an empty position pays nothing -- the repeat case a
        // single function makes reachable by ordinary use rather than by misuse.
        (uint256 baseOut, uint256 quoteOut) = _decreaseBand(id, 0, type(uint128).max);
        assertEq(baseOut, 0);
        assertEq(quoteOut, 0);
    }

    /// What `shares` of a band is worth right now, by the same floor the pool uses.
    function _baseShareOf(uint8 band, uint256 shares) internal view returns (uint256) {
        (uint256 br,) = pool.bandReserves(band);
        (, uint256 total,,,) = pool.bands(band);
        return (br * shares) / total;
    }
}
