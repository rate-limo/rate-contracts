// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandSingleSidedTest} from "./BandSingleSided.t.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {PoolPositions} from "../../src/swap/PoolPositions.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";

/**
 * THE AVAILABILITY MATRIX, measured — which deposit works against which band.
 *
 * Since `_price` learned to price a ONE-SIDED deposit by value, the answer is
 * "all of them" for every band that holds anything: the wall is no longer
 * restricted to empty or same-side bands. What remains interesting here is the
 * SHAPE of each path — what is used, what is refunded, and the one direction
 * that still reverts (`convert now` with nothing in the ladder to convert into).
 *
 * Three deposit paths exist and the UI has to know, per band, which of them the
 * pool will accept:
 *
 *   both tokens   `mint(bands, baseAmounts, quoteAmounts)`, both non-zero
 *   convert now   `mintSingleSided(...)` — swaps half through the LADDER, then deposits
 *   wall          `mint(...)` with the other side left at zero — no swap anywhere
 *
 * Every cell below is a transaction, not a reading of the source. The doc in
 * apps/web/CLAUDE.md is this table in prose; if they ever disagree, this is right.
 */
contract BandModeMatrixTest is BandSingleSidedTest {
    function _mint(address who, uint8 band, uint256 b, uint256 q) internal returns (uint128 shares) {
        uint8[] memory bands = new uint8[](1);
        bands[0] = band;
        uint128[] memory got;
        vm.prank(who);
        (, got) = manager.mint(
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

    function _mintRaw(address who, uint8 band, uint256 b, uint256 q) internal {
        uint8[] memory bands = new uint8[](1);
        bands[0] = band;
        vm.prank(who);
        manager.mint(
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
    }

    // ───────────────────────── an EMPTY band takes anything ─────────────────────

    /// And the two one-token modes are IDENTICAL here: there is nothing to convert
    /// against, so `_singleSidedAmounts` sets half = 0 and skips the swap entirely.
    function test_emptyBand_convertNowDoesNotActuallyConvert() public {
        _fund(bob, 0, 100e18);
        vm.prank(bob);
        manager.mintSingleSided(address(pool), _bands(1), _one(100e18), false, _mins(1, 0), bob, block.timestamp);
        assertEq(eng.reports(), 0, "no swap ran -- convert-now on an empty band IS a wall");
        (uint256 rb, uint256 rq) = pool.bandReserves(0);
        assertEq(rb, 0);
        assertEq(rq, 100e18);
    }

    function test_emptyBand_wallEitherToken() public {
        _fund(alice, 100e18, 0);
        assertGt(_mint(alice, 0, 100e18, 0), 0, "base alone opens it");
        _fund(bob, 0, 100e18);
        assertGt(_mint(bob, 1, 0, 100e18), 0, "quote alone opens it too");
    }

    function test_emptyBand_bothTokens() public {
        _fund(alice, 100e18, 300e18);
        assertGt(_mint(alice, 0, 100e18, 300e18), 0);
        (uint256 rb, uint256 rq) = pool.bandReserves(0);
        assertEq(rb, 100e18, "both become principal, the opener sets the ratio");
        assertEq(rq, 300e18);
    }

    // ───────────────────── a ONE-SIDED band takes its own side ──────────────────

    function test_oneSidedBand_wallOnItsOwnSideMints() public {
        _fund(alice, 100e18, 0);
        _mint(alice, 0, 100e18, 0);
        _fund(bob, 50e18, 0);
        assertGt(_mint(bob, 0, 50e18, 0), 0, "more of the side it holds is pro-rata");
    }

    function test_oneSidedBand_wallOnTheOtherSideMintsByValue() public {
        _fund(alice, 100e18, 0);
        _mint(alice, 0, 100e18, 0);
        _fund(bob, 0, 50e18);
        assertGt(_mint(bob, 0, 0, 50e18), 0, "priced by value, not refused");
    }

    /// Both tokens into a one-sided band: mints on the side it holds, REFUNDS the other.
    /// It does not become principal -- that would be the same dilution the wall rule stops.
    function test_oneSidedBand_bothTokensRefundsTheSideItLacks() public {
        _fund(alice, 100e18, 0);
        _mint(alice, 0, 100e18, 0);
        _fund(bob, 50e18, 70e18);
        assertGt(_mint(bob, 0, 50e18, 70e18), 0);
        (uint256 rb, uint256 rq) = pool.bandReserves(0);
        assertEq(rb, 150e18);
        assertEq(rq, 0, "the quote never became reserve");
        assertEq(quoteTok.balanceOf(bob), 70e18, "it came straight back");
    }

    // ───────────────────────── a MIXED band refuses one side ────────────────────

    function test_mixedBand_wallMintsFromEitherSide() public {
        _fund(alice, 100e18, 100e18);
        _mint(alice, 0, 100e18, 100e18);
        _fund(bob, 50e18, 50e18);
        assertGt(_mint(bob, 0, 50e18, 0), 0, "base alone");
        assertGt(_mint(bob, 0, 0, 50e18), 0, "quote alone");
    }

    function test_mixedBand_convertNowWorks() public {
        _fund(alice, 1_000e18, 1_000e18);
        _mint(alice, 0, 1_000e18, 1_000e18);
        _fund(bob, 0, 100e18);
        vm.prank(bob);
        (, uint128[] memory got) =
            manager.mintSingleSided(address(pool), _bands(1), _one(100e18), false, _mins(1, 0), bob, block.timestamp);
        assertGt(got[0], 0, "the swap gives it the other side, so the min rule is satisfied");
    }

    function test_mixedBand_bothTokensWorks() public {
        _fund(alice, 1_000e18, 1_000e18);
        _mint(alice, 0, 1_000e18, 1_000e18);
        _fund(bob, 100e18, 100e18);
        assertGt(_mint(bob, 0, 100e18, 100e18), 0);
    }

    // ────────────────── convert-now is NOT universally available ────────────────

    /**
     * The half the UI used to get wrong in the other direction: converting needs a
     * COUNTERPARTY. With no band holding the token being converted into, the swap
     * fills nothing and the whole deposit reverts — so neither mode is available
     * everywhere, and their conditions are near opposites.
     */
    function test_convertNowRevertsWhenTheLadderCannotPayOut() public {
        _fund(alice, 0, 1_000e18);
        _mint(alice, 0, 0, 1_000e18); // quote-only ladder: nothing can pay out base
        _fund(bob, 0, 100e18);
        vm.prank(bob);
        vm.expectRevert(BandPool.NoLiquidity.selector);
        manager.mintSingleSided(address(pool), _bands(1), _one(100e18), false, _mins(1, 0), bob, block.timestamp);
    }

    /// And in exactly that state the WALL works, because it needs no counterparty.
    function test_theWallWorksWhereConvertNowCannot() public {
        _fund(alice, 0, 1_000e18);
        _mint(alice, 0, 0, 1_000e18);
        _fund(bob, 0, 100e18);
        assertGt(_mint(bob, 0, 0, 100e18), 0, "same band, same token, no swap needed");
    }
}
