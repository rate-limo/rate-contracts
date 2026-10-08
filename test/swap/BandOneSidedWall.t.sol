// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandSingleSidedTest} from "./BandSingleSided.t.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {PoolPositions} from "../../src/swap/PoolPositions.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";

/**
 * ONE-SIDED LIQUIDITY THAT NEVER CONVERTS -- "provide as a wall".
 *
 * The other mode is `mintSingleSided`, which swaps half the input through the ladder
 * on the way in. This one is the ordinary two-sided `mint` with one side left at zero:
 * no swap anywhere in the call, the token stands as the band's whole inventory on its
 * side, and traders convert the position over time while it collects the fee.
 *
 * The matrix below is the whole contract for that mode. Every cell is either "mints,
 * and here is the accounting" or "reverts, and here is why" -- there is no third
 * answer, and a one-sided deposit must never mint a claim on a reserve it did not fund.
 *
 *            band state          |  base only  |  quote only  |  both
 *   ---------------------------- + ----------- + ------------ + -------
 *   empty (no shares)            |    mints    |    mints     | mints
 *   holds base only              |    mints    |   REVERTS    | mints base, refunds quote
 *   holds quote only             |   REVERTS   |    mints     | mints quote, refunds base
 *   holds both                   |   REVERTS   |   REVERTS    | mints (min rule)
 */
contract BandOneSidedWallTest is BandSingleSidedTest {
    /**
     * The no-conversion deposit: the plain `mint`, one side zero.
     *
     * `_wallRaw` is the same call without reading the returned array, so a test that
     * EXPECTS a revert does not then panic indexing an empty return -- which reports
     * as 0x32 and hides whether the revert under test actually happened.
     */
    function _wallRaw(address who, uint8 band, uint256 b, uint256 q) internal {
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

    function _wall(address who, uint8 band, uint256 b, uint256 q)
        internal
        returns (uint256 id, uint128 shares)
    {
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

    // ───────────────────────────── opening an empty band ─────────────────────────

    /// THE CHANGE. Quote alone opens a band, which it could not do before.
    function test_quoteAloneOpensAnEmptyBand() public {
        _fund(alice, 0, 500e18);
        (, uint128 shares) = _wall(alice, 0, 0, 500e18);

        assertEq(shares, 500e18, "the opener mints one share per unit it brought");
        (uint256 rb, uint256 rq) = pool.bandReserves(0);
        assertEq(rb, 0, "no base was invented");
        assertEq(rq, 500e18, "all of it is principal");
        assertEq(quoteTok.balanceOf(alice), 0, "nothing refunded on the defining deposit");
        assertEq(eng.reports(), 0, "and NO swap was reported -- this is the whole point");
        _assertNothingStranded();
    }

    /// The base side still behaves exactly as it did.
    function test_baseAloneStillOpensAnEmptyBand() public {
        _fund(alice, 500e18, 0);
        (, uint128 shares) = _wall(alice, 0, 500e18, 0);
        assertEq(shares, 500e18, "unchanged");
        assertEq(eng.reports(), 0, "no swap");
    }

    /// A two-sided opener is priced on the base leg, as before -- the `> 0` test only
    /// reaches the quote when there is no base at all.
    function test_atwoSidedOpenerIsStillPricedOnBase() public {
        _fund(alice, 300e18, 900e18);
        (, uint128 shares) = _wall(alice, 0, 300e18, 900e18);
        assertEq(shares, 300e18, "base still defines the scale when both are brought");
        (uint256 rb, uint256 rq) = pool.bandReserves(0);
        assertEq(rb, 300e18);
        assertEq(rq, 900e18, "the quote is principal too, not a refund");
    }

    /// Nothing in, nothing out. The one cell that must stay a revert in every row.
    function test_anEmptyDepositIntoAnEmptyBandStillReverts() public {
        _fund(alice, 1e18, 1e18);
        vm.expectRevert(PoolPositions.ZeroLiquidity.selector);
        _wallRaw(alice, 0, 0, 0);
    }

    // ──────────────────────── topping up a one-sided band ────────────────────────

    function test_quoteToppingUpAQuoteOnlyBandMints() public {
        _fund(alice, 0, 500e18);
        _wall(alice, 0, 0, 500e18);

        _fund(bob, 0, 250e18);
        (, uint128 shares) = _wall(bob, 0, 0, 250e18);
        assertEq(shares, 250e18, "pro-rata on the only reserve there is");
        assertEq(eng.reports(), 0, "still no swap");
        _assertNothingStranded();
    }

    function test_baseToppingUpABaseOnlyBandMints() public {
        _fund(alice, 500e18, 0);
        _wall(alice, 0, 500e18, 0);

        _fund(bob, 250e18, 0);
        (, uint128 shares) = _wall(bob, 0, 250e18, 0);
        assertEq(shares, 250e18);
        assertEq(eng.reports(), 0);
    }

    /**
     * THE CELL THAT USED TO BE A REFUSAL, both directions.
     *
     * Adding the token a one-sided band does not hold cannot be priced pro-rata --
     * that would hand the depositor a claim on a reserve they never funded -- so it
     * is priced BY VALUE instead. It mints, nothing is refunded, and the band simply
     * becomes two-sided. Fairness is measured in BandOneSidedValue.t.sol; this pins
     * that the path is open in both directions.
     */
    function test_theOtherTokenJoinsAOneSidedBandByValue() public {
        _fund(alice, 500e18, 0);
        _wall(alice, 0, 500e18, 0);
        _fund(bob, 0, 100e18);
        (, uint128 shares) = _wall(bob, 0, 0, 100e18);
        assertGt(shares, 0, "quote joins a base-only band");
        (uint256 rb, uint256 rq) = pool.bandReserves(0);
        assertEq(rb, 500e18);
        assertEq(rq, 100e18, "it became reserve");
        _assertNothingStranded();
    }

    function test_theOtherTokenJoinsAQuoteOnlyBandToo() public {
        _fund(alice, 0, 500e18);
        _wall(alice, 0, 0, 500e18);
        _fund(bob, 100e18, 0);
        (, uint128 shares) = _wall(bob, 0, 100e18, 0);
        assertGt(shares, 0, "base joins a quote-only band");
        _assertNothingStranded();
    }

    /// Bringing both into a one-sided band mints on the side it holds and REFUNDS the
    /// rest -- it must not quietly become principal, which would be the same theft.
    function test_bothIntoAOneSidedBandRefundsTheSideItDoesNotHold() public {
        _fund(alice, 500e18, 0);
        _wall(alice, 0, 500e18, 0);

        _fund(bob, 100e18, 70e18);
        (, uint128 shares) = _wall(bob, 0, 100e18, 70e18);
        assertEq(shares, 100e18, "priced on the base leg alone");
        (uint256 rb, uint256 rq) = pool.bandReserves(0);
        assertEq(rb, 600e18, "base is principal");
        assertEq(rq, 0, "the quote did NOT become reserve");
        assertEq(quoteTok.balanceOf(bob), 70e18, "it came straight back");
        _assertNothingStranded();
    }

    // ─────────────────────────── the mixed band is unchanged ─────────────────────

    /// A mixed band takes one side too, priced by value. Both directions.
    function test_aMixedBandTakesOneSideByValue() public {
        _fund(alice, 500e18, 500e18);
        _wall(alice, 0, 500e18, 500e18);

        _fund(bob, 100e18, 100e18);
        (, uint128 b1) = _wall(bob, 0, 100e18, 0);
        (, uint128 b2) = _wall(bob, 0, 0, 100e18);
        assertGt(b1, 0, "base alone");
        assertGt(b2, 0, "quote alone");
        _assertNothingStranded();
    }

    // ───────────────────────────────── it actually trades ────────────────────────

    /**
     * The mode's whole promise: no swap on the way in, and traders do the converting.
     * A quote-only band is a standing BID -- it buys base and refuses to sell it.
     */
    function test_aQuoteOnlyWallBuysBaseAndRefusesToSellIt() public {
        _fund(alice, 0, 1_000e18);
        _wall(alice, 0, 0, 1_000e18);

        // Someone selling base hits the wall and is filled.
        _fund(bob, 200e18, 0);
        vm.startPrank(bob);
        baseTok.approve(address(router), type(uint256).max);
        uint256 out = router.swap(address(pool), 200e18, false, bob, 0);
        vm.stopPrank();
        assertGt(out, 0, "the wall paid quote for base");

        (uint256 rb, uint256 rq) = pool.bandReserves(0);
        assertEq(rb, 200e18, "the base it bought is now the band's");
        assertLt(rq, 1_000e18, "and it spent quote doing so");

        /*
         * And a quote-only band is SKIPPED by a buyer, rather than filling at a price
         * it has no inventory for. A swap walks the whole ladder, so this has to be
         * asserted on the band: band 1 is opened quote-only, and a buy that band 0 can
         * satisfy must leave it untouched.
         */
        _fund(alice, 0, 1_000e18);
        _wall(alice, 1, 0, 1_000e18);
        (uint256 b1Base, uint256 b1Quote) = pool.bandReserves(1);
        _fund(bob, 0, 50e18);
        vm.startPrank(bob);
        quoteTok.approve(address(router), type(uint256).max);
        router.swap(address(pool), 50e18, true, bob, 0);
        vm.stopPrank();
        (uint256 b1BaseAfter, uint256 b1QuoteAfter) = pool.bandReserves(1);
        assertEq(b1BaseAfter, b1Base, "the quote-only band sold nothing");
        assertEq(b1QuoteAfter, b1Quote, "and took nothing in");
    }

    /// And the wall earns the fee on that conversion instead of paying one.
    function test_theWallCollectsTheFeeItsConversionGenerated() public {
        _fund(alice, 0, 1_000e18);
        (uint256 id,) = _wall(alice, 0, 0, 1_000e18);

        _fund(bob, 200e18, 0);
        vm.startPrank(bob);
        baseTok.approve(address(router), type(uint256).max);
        router.swap(address(pool), 200e18, false, bob, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days); // past maturity, so it all vests
        uint256 beforeBase = baseTok.balanceOf(alice);
        uint256 beforeQuote = quoteTok.balanceOf(alice);
        vm.prank(alice);
        manager.collect(id, alice);
        assertGt(
            (baseTok.balanceOf(alice) - beforeBase) + (quoteTok.balanceOf(alice) - beforeQuote),
            0,
            "the wall was paid for converting"
        );
    }

    // ──────────────────────────────── getting back out ───────────────────────────

    /// A wall that never traded returns exactly what went in -- no conversion on the
    /// way out either, and no claim on a reserve it never funded.
    function test_anUntradedWallWithdrawsTheSameTokenItBrought() public {
        _fund(alice, 0, 400e18);
        (uint256 id,) = _wall(alice, 0, 0, 400e18);

        vm.prank(alice);
        (uint256 baseOut, uint256 quoteOut) = manager.decreaseLiquidity(id, 10_000, 0, 0, alice, block.timestamp);
        assertEq(baseOut, 0, "no base was ever owed");
        assertEq(quoteOut, 400e18, "all of the quote comes back");
        _assertNothingStranded();
    }

    /// A wall that HAS traded is an ordinary mixed position and exits pro-rata on both.
    function test_aTradedWallWithdrawsBothSides() public {
        _fund(alice, 0, 1_000e18);
        (uint256 id,) = _wall(alice, 0, 0, 1_000e18);

        _fund(bob, 200e18, 0);
        vm.startPrank(bob);
        baseTok.approve(address(router), type(uint256).max);
        router.swap(address(pool), 200e18, false, bob, 0);
        vm.stopPrank();

        vm.prank(alice);
        (uint256 baseOut, uint256 quoteOut) = manager.decreaseLiquidity(id, 10_000, 0, 0, alice, block.timestamp);
        assertGt(baseOut, 0, "converted into base by the trade, exactly as intended");
        assertGt(quoteOut, 0, "and the unconverted remainder comes back too");
        _assertNothingStranded();
    }

    // ───────────────────────────── the ladder, and the position ──────────────────

    /// One token, several bands, no conversion: ONE position holding the whole ladder.
    function test_aWallCanSpanTheLadderInOnePosition() public {
        _fund(alice, 0, 900e18);
        uint8[] memory bands = _bands(3);
        uint256[] memory zero = new uint256[](3);
        uint256[] memory q = new uint256[](3);
        q[0] = 500e18;
        q[1] = 300e18;
        q[2] = 100e18;
        vm.prank(alice);
        (uint256 id, uint128[] memory shares) = manager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: zero,
                quoteAmounts: q,
                minShares: _mins(3, 0),
                recipient: alice,
                deadline: block.timestamp
            })
        );
        assertEq(shares[0], 500e18);
        assertEq(shares[1], 300e18);
        assertEq(shares[2], 100e18);
        assertEq(manager.holderOf(id), alice, "one token for the whole ladder");
        assertEq(eng.reports(), 0, "and not one swap across any of it");
        _assertNothingStranded();
    }

    /// A band at zero in the middle of a wall still takes the whole deposit down, the
    /// same as it does for a converting one. The app drops those bands before signing.
    function test_azeroBandInAWallStillReverts() public {
        _fund(alice, 0, 900e18);
        uint8[] memory bands = _bands(2);
        uint256[] memory q = new uint256[](2);
        q[0] = 500e18;
        q[1] = 0;
        vm.prank(alice);
        vm.expectRevert(PoolPositions.ZeroLiquidity.selector);
        manager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: new uint256[](2),
                quoteAmounts: q,
                minShares: _mins(2, 0),
                recipient: alice,
                deadline: block.timestamp
            })
        );
    }

    /// `minShares` guards a wall exactly as it guards a conversion.
    function test_minSharesStillBindsOnAWall() public {
        _fund(alice, 0, 100e18);
        uint8[] memory bands = _bands(1);
        vm.prank(alice);
        vm.expectPartialRevert(IBandPositionManager.SharesBelowMinimum.selector);
        manager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: _one(0),
                quoteAmounts: _one(100e18),
                minShares: _mins(1, type(uint128).max),
                recipient: alice,
                deadline: block.timestamp
            })
        );
    }

    // ─────────────────────────────── dust and scale ──────────────────────────────

    /**
     * A band opened with a 6-decimal quote mints ~1e6 shares where a base-opened one
     * mints ~1e18. Nothing compares shares across bands, and every rate that reads
     * them is Q128-scaled -- so the smallest opener that can exist still accrues.
     */
    function test_aOneUnitWallStillAccruesAndExits() public {
        _fund(alice, 0, 1);
        (uint256 id, uint128 shares) = _wall(alice, 0, 0, 1);
        assertEq(shares, 1, "one share for one unit");

        vm.prank(alice);
        (, uint256 quoteOut) = manager.decreaseLiquidity(id, 10_000, 0, 0, alice, block.timestamp);
        assertEq(quoteOut, 1, "and it comes back whole");
    }
}
