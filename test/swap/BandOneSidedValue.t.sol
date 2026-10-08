// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandSingleSidedTest} from "./BandSingleSided.t.sol";
import {IBandPool} from "../../src/swap/interfaces/IBandPool.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";

/**
 * ONE TOKEN, ANY BAND — and nobody is diluted.
 *
 * `_price` prices a one-sided deposit by VALUE when the pro-rata rule cannot
 * serve it. The rule is only worth having if it is FAIR, so that is what these
 * measure: what the depositor receives against what they paid, and what the LPs
 * already in the band are worth before and after.
 */
contract BandOneSidedValueTest is BandSingleSidedTest {
    function _mint(address who, uint8 band, uint256 b, uint256 q) internal returns (uint256 id, uint128 shares) {
        uint8[] memory bands = new uint8[](1);
        bands[0] = band;
        uint128[] memory got;
        vm.prank(who);
        (id, got) = manager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: _one(b),
                quoteAmounts: _one(q),
                minShares: _mins(1, 0),
                recipient: who,
                deadline: block.timestamp
            })
        );
        shares = got[0];
    }

    /// What a position's slice of the band is worth, in quote, at the anchor.
    function _valueOf(uint256 id) internal view returns (uint256) {
        (IBandPool.BandView[] memory v,,) = pool.positionView(id);
        uint256 price = pool.anchorPrice();
        uint256 total;
        for (uint256 i = 0; i < v.length; i++) {
            total += v[i].quoteOwned + (v[i].baseOwned * price) / 1e8;
        }
        return total;
    }

    // ───────────────────────────── it just works now ────────────────────────────

    function test_quoteOnlyIntoAMixedBandMints() public {
        _fund(alice, 1_000e18, 1_000e18);
        _mint(alice, 0, 1_000e18, 1_000e18);

        _fund(bob, 0, 100e18);
        (, uint128 shares) = _mint(bob, 0, 0, 100e18);
        assertGt(shares, 0, "one token into a band holding both");
        assertEq(quoteTok.balanceOf(bob), 0, "all of it was used -- nothing refunded");
        assertEq(eng.reports(), 0, "and no swap ran");
    }

    function test_baseOnlyIntoAMixedBandMints() public {
        _fund(alice, 1_000e18, 1_000e18);
        _mint(alice, 0, 1_000e18, 1_000e18);

        _fund(bob, 100e18, 0);
        (, uint128 shares) = _mint(bob, 0, 100e18, 0);
        assertGt(shares, 0, "the mirror works too");
        assertEq(baseTok.balanceOf(bob), 0, "all of it was used");
    }

    function test_theTokenABandDoesNotHoldCanJoinIt() public {
        _fund(alice, 1_000e18, 0);
        _mint(alice, 0, 1_000e18, 0); // base-only band
        _fund(bob, 0, 100e18);
        (, uint128 shares) = _mint(bob, 0, 0, 100e18);
        assertGt(shares, 0, "quote into a base-only band");
        (uint256 rb, uint256 rq) = pool.bandReserves(0);
        assertEq(rb, 1_000e18);
        assertEq(rq, 100e18, "it became reserve rather than coming back");
    }

    // ──────────────────────────────── and it is FAIR ────────────────────────────

    /**
     * THE PROPERTY THE WHOLE THING RESTS ON.
     *
     * The depositor gets back what they put in, and the LP already there is worth
     * what they were worth. A pro-rata mint on one leg would have handed the
     * depositor ~2x and taken the difference from alice.
     */
    function test_aOneSidedDepositTakesNothingFromTheLpsAlreadyThere() public {
        _fund(alice, 1_000e18, 1_000e18);
        (uint256 aliceId,) = _mint(alice, 0, 1_000e18, 1_000e18);
        uint256 aliceBefore = _valueOf(aliceId);

        _fund(bob, 0, 100e18);
        (uint256 bobId,) = _mint(bob, 0, 0, 100e18);

        uint256 aliceAfter = _valueOf(aliceId);
        uint256 bobValue = _valueOf(bobId);
        emit log_named_uint("alice value before", aliceBefore);
        emit log_named_uint("alice value after ", aliceAfter);
        emit log_named_uint("bob paid           ", 100e18);
        emit log_named_uint("bob value          ", bobValue);

        // Within a share's worth of rounding, which rounds against the depositor.
        assertApproxEqRel(aliceAfter, aliceBefore, 1e12, "alice is not diluted");
        assertApproxEqRel(bobValue, 100e18, 1e12, "bob gets what he paid for");
        assertLe(bobValue, 100e18 + 1, "and never MORE than he paid");
    }

    /// The same, from the base side and against a lopsided band.
    function test_fairnessHoldsOnALopsidedBandFromTheBaseSide() public {
        _fund(alice, 1_000e18, 50e18);
        (uint256 aliceId,) = _mint(alice, 0, 1_000e18, 50e18);
        uint256 aliceBefore = _valueOf(aliceId);

        _fund(bob, 200e18, 0);
        (uint256 bobId,) = _mint(bob, 0, 200e18, 0);

        assertApproxEqRel(_valueOf(aliceId), aliceBefore, 1e12, "alice is not diluted");
        uint256 paid = (200e18 * pool.anchorPrice()) / 1e8;
        assertApproxEqRel(_valueOf(bobId), paid, 1e12, "bob gets what he paid for");
        assertLe(_valueOf(bobId), paid + 1, "and never more");
    }

    /// Two one-sided deposits in a row, opposite sides, still add up.
    function test_repeatedOneSidedDepositsStayFair() public {
        _fund(alice, 1_000e18, 1_000e18);
        (uint256 aliceId,) = _mint(alice, 0, 1_000e18, 1_000e18);
        uint256 aliceBefore = _valueOf(aliceId);

        _fund(bob, 0, 100e18);
        (uint256 bobId,) = _mint(bob, 0, 0, 100e18);
        _fund(charlieAddr(), 100e18, 0);
        (uint256 charlieId,) = _mint(charlieAddr(), 0, 100e18, 0);

        assertApproxEqRel(_valueOf(aliceId), aliceBefore, 1e12, "alice still whole");
        assertApproxEqRel(_valueOf(bobId), 100e18, 1e12, "bob still whole");
        uint256 paid = (100e18 * pool.anchorPrice()) / 1e8;
        assertApproxEqRel(_valueOf(charlieId), paid, 1e12, "charlie too");
    }

    function charlieAddr() internal pure returns (address) {
        return address(0xC4A12);
    }

    // ────────────────────────────── it still refuses ────────────────────────────

    /// Nothing in, nothing out. Value pricing does not make an empty deposit valid.
    function test_anEmptyDepositStillReverts() public {
        _fund(alice, 1_000e18, 1_000e18);
        _mint(alice, 0, 1_000e18, 1_000e18);
        uint8[] memory bands = new uint8[](1);
        bands[0] = 0;
        vm.prank(alice);
        vm.expectRevert();
        manager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: _one(0),
                quoteAmounts: _one(0),
                minShares: _mins(1, 0),
                recipient: alice,
                deadline: block.timestamp
            })
        );
    }

    /// A two-sided deposit keeps the V2 rule, refund and all -- unchanged.
    function test_twoSidedDepositsStillTakeTheLesserLegAndRefund() public {
        _fund(alice, 1_000e18, 1_000e18);
        _mint(alice, 0, 1_000e18, 1_000e18);

        _fund(bob, 100e18, 500e18);
        (, uint128 shares) = _mint(bob, 0, 100e18, 500e18);
        assertGt(shares, 0);
        assertGt(quoteTok.balanceOf(bob), 0, "the excess quote came back, as before");
    }
}
