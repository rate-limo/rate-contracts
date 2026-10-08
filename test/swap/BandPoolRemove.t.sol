// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandPoolBase} from "./BandPoolBase.sol";

contract BandPoolRemoveTest is BandPoolBase {
    function test_soleLpGetsTheWholeBandBack() public {
        uint256 id = _addTo(0, 1_000e18);
        (uint256 br,) = pool.bandReserves(0);
        assertEq(br, 1_000e18);

        (uint256 baseOut,) = _decrease(id, 10_000, pm);
        assertEq(baseOut, 1_000e18, "sole LP takes the whole reserve");
        (uint256 after_,) = pool.bandReserves(0);
        assertEq(after_, 0);
    }

    function test_exitAfterASwapReturnsBothSides() public {
        uint256 id = _addTo(0, 1_000e18);
        _swap(100e18);
        (uint256 br, uint256 qr) = pool.bandReserves(0);
        assertLt(br, 1_000e18, "base was sold");
        assertGt(qr, 0, "quote came in");

        (uint256 baseOut, uint256 quoteOut) = _decrease(id, 10_000, pm);
        assertEq(baseOut, br, "the LP owns all of both reserves");
        assertEq(quoteOut, qr);
    }

    function test_halfTheSharesTakeHalfOfEach() public {
        uint256 a = _addTo(0, 1_000e18);
        _addTo(0, 1_000e18);
        _swap(100e18);
        (uint256 br, uint256 qr) = pool.bandReserves(0);

        (uint256 baseOut, uint256 quoteOut) = _decrease(a, 10_000, pm);
        assertApproxEqRel(baseOut, uint256(br) / 2, 1e12);
        assertApproxEqRel(quoteOut, uint256(qr) / 2, 1e12);
    }

    /// v1 forfeited through the claim an exit forced; v2 forfeits on the withdrawal itself.
    function test_exitingEarlyForfeitsToTheHolder() public {
        uint256 holder = _addTo(0, 1_000e18);
        uint256 jit = _addTo(0, 1_000e18);
        _swap(100e18);
        uint256 holderBefore = _rawOwedBase(holder);

        _decrease(jit, 10_000, pm); // age 0
        assertGt(_rawOwedBase(holder), holderBefore, "the exit's fees went to the holder");
    }

    /**
     * What is left to check after the level list went is that an exit returns the
     * position's slice of the band and touches nobody else's.
     */
    function test_anExitTakesOnlyItsOwnSliceOfTheBand() public {
        uint256 a = _addTo(0, 1_000e18);
        uint256 other = _addTo(0, 3_000e18);
        (, uint256 sharesBefore,,,) = pool.bands(0);

        (uint256 baseOut,) = _decrease(a, 10_000, pm);

        (, uint256 sharesAfter,,,) = pool.bands(0);
        assertEq(sharesBefore - sharesAfter, 1_000e18, "only its own shares burned");
        assertApproxEqRel(baseOut, 1_000e18, 1e12, "and only its own quarter of the base");

        (uint256 otherBase,) = _decrease(other, 10_000, pm);
        assertApproxEqRel(otherBase, 3_000e18, 1e12, "the other position is untouched");
    }

    function test_removingTwiceIsHarmless() public {
        uint256 id = _addTo(0, 1_000e18);
        _decrease(id, 10_000, pm);
        (uint256 b2, uint256 q2) = _decrease(id, 10_000, pm);
        assertEq(b2, 0);
        assertEq(q2, 0);
        assertEq(pool.bandMaskOf(id), 0, "the emptied position holds no band");
    }

    /// One token holds the whole ladder, so one full exit empties every band it holds.
    function test_oneExitEmptiesEveryBandThePositionHolds() public {
        uint256 id = _addTo(0, 1_000e18);
        _topUp(id, 1, 2_000e18);
        assertEq(pool.bandMaskOf(id), 3);

        (uint256 baseOut,) = _decrease(id, 10_000, pm);
        assertEq(baseOut, 3_000e18, "both bands paid out in one call");
        (uint256 r0,) = pool.bandReserves(0);
        (uint256 r1,) = pool.bandReserves(1);
        assertEq(r0 + r1, 0);
        assertEq(pool.bandMaskOf(id), 0);
    }
}
