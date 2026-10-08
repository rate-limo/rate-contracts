// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {BandSwapRouter} from "../../src/swap/BandSwapRouter.sol";
import {BandPoolFactory} from "../../src/swap/BandPoolFactory.sol";
import {BandPositionManager} from "../../src/swap/BandPositionManager.sol";
import {IBandPool} from "../../src/swap/interfaces/IBandPool.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";
import {WalkTok, PricedBook, CountEngine} from "./GasBandCount.t.sol";

/**
 * The ladder: what a band's tolerance is, what it is not, and why bands do not nest.
 *
 * Two questions this pins, both of which look like bugs until the answer is written
 * down as a test:
 *
 *  1. "Band 0 is +/-0.10%, so how did my trade execute 0.5% away from the TWAP?"
 *     Because a tolerance is the PRICE that band's liquidity trades at, not a cap on
 *     the trade. Exhaust the tight band and the fill moves up the ladder. The taker's
 *     cap is `minAmountOut`, which is a different parameter belonging to a different
 *     party.
 *
 *  2. "Shouldn't the wide band contain the tight ones, like a DLMM position spanning
 *     bins?" No -- and DLMM does not do that either. A DLMM position spanning many
 *     bins holds liquidity IN each bin at that bin's own price, and the swap still
 *     takes the best bin first. Liquidity that asked for +0.50% filling at +0.10%
 *     would hand the better price to whoever asked for the worse one.
 *
 * A third, new with v2: a band stores a FRACTION of the pair's limit, not a tolerance.
 * The factory's default ladder is 20 / 60 / 100% of the limit, so under the 0.5% limit
 * this setup gives the engine it is exactly the 0.10 / 0.30 / 0.50% ladder the cases
 * above were written against. The last section pins what that buys and what it costs.
 */
contract BandLadderTest is Test {
    BandPoolFactory factory;
    BandPositionManager manager;
    BandPool pool;
    BandSwapRouter router;
    WalkTok baseTok;
    WalkTok quoteTok;
    CountEngine eng;

    address alice = address(0xA11CE);
    address wide = address(0x1D1E);
    address taker = address(0xABCD);

    /// 0.5%: the default fractions 20 / 60 / 100% of it are 0.10 / 0.30 / 0.50%.
    uint32 constant LIMIT = 500000;

    function setUp() public {
        router = new BandSwapRouter();
        baseTok = new WalkTok();
        quoteTok = new WalkTok();
        eng = new CountEngine();
        eng.setSwapRouter(address(router));
        eng.setSpread_(LIMIT);
        manager = new BandPositionManager();
        manager.initialize("");
        factory = new BandPoolFactory();
        factory.initialize(address(eng), address(manager), address(new BandPool()), address(0xC0FFEE));
        eng.setPoolFactory(address(factory));
        manager.setPoolFactory(address(factory));
        // The book is deployed BEFORE the prank: vm.prank applies to the next call,
        // and `new PricedBook()` inside the argument list would consume it.
        address book = address(new PricedBook());
        vm.prank(address(eng));
        pool = BandPool(factory.createPool(address(baseTok), address(quoteTok), book, address(0)));
        // A stub engine does not push its spread the way the real one does on addPair.
        pool.syncLimit();
        vm.warp(1_000_000);
    }

    function _seed(address who, uint8 band, uint256 baseAmt) internal returns (uint256 id) {
        uint8[] memory bands = new uint8[](1);
        uint256[] memory baseAmts = new uint256[](1);
        bands[0] = band;
        baseAmts[0] = baseAmt;
        id = _mint(who, bands, baseAmts, new uint256[](1));
    }

    function _mint(address who, uint8[] memory bands, uint256[] memory baseAmts, uint256[] memory quoteAmts)
        internal
        returns (uint256 id)
    {
        uint256 total;
        for (uint256 i = 0; i < baseAmts.length; i++) total += baseAmts[i];
        baseTok.mint(who, total);
        vm.startPrank(who);
        baseTok.approve(address(manager), type(uint256).max);
        (id,) = manager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: baseAmts,
                quoteAmounts: quoteAmts,
                minShares: new uint128[](bands.length),
                recipient: who,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    function _buy(uint256 quoteIn, uint256 minOut) internal returns (uint256 out) {
        quoteTok.mint(taker, quoteIn);
        vm.startPrank(taker);
        quoteTok.approve(address(pool), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        out = router.swap(address(pool), quoteIn, true, taker, minOut);
        vm.stopPrank();
    }

    /// Everything the position has accrued, vested or not -- v1's `rawOwed`.
    function _accrued(uint256 id) internal view returns (uint256 ab, uint256 aq) {
        (IBandPool.BandView[] memory all, uint256 ob, uint256 oq) = pool.positionView(id);
        ab = ob;
        aq = oq;
        for (uint256 i = 0; i < all.length; i++) {
            ab += all[i].pendingBase;
            aq += all[i].pendingQuote;
        }
    }

    // ---- 1. tolerance is the LP's price, not the taker's cap ----------------

    /// A trade larger than the tight band executes past the tight band's tolerance.
    function test_aTradeCanSettleFarPastTheTightestBandsTolerance() public {
        _seed(alice, 0, 1e18); // a very thin tight band
        _seed(wide, 2, 1_000e18);

        // Book price is 2 quote per base. Band 0 (+0.10%) can absorb ~2.002 quote.
        // Everything past that fills in band 2 at +0.50%.
        uint256 out = _buy(200e18, 0);
        // Blended price is far worse than band 0's bound, which is the point.
        uint256 blended = (uint256(200e18) * 1e18) / out;
        assertGt(blended, 2_002_000_000_000_000_000, "settled beyond band 0's tolerance");
        // The widest bound is 2.010, plus band 2's own fee -- which is 3x the engine
        // rate, because a band that only fills on oversized trades has to be paid for
        // it. The fee comes out of the output, not out of the bound.
        assertLe(blended, 2_016_100_000_000_000_000, "no further than the widest bound plus that band's fee");
    }

    /// The taker's own bound is what stops that, and it is a separate parameter.
    function test_theTakerSetsTheirOwnBoundAndItIsEnforced() public {
        _seed(alice, 0, 1e18);
        _seed(wide, 2, 1_000e18);

        // What band 0's price alone would have produced for the whole 200.
        uint256 demandTightPricing = (uint256(200e18) * 1e18) / 2_002_000_000_000_000_000;
        quoteTok.mint(taker, 200e18);
        vm.startPrank(taker);
        quoteTok.approve(address(pool), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(BandPool.SlippageExceeded.selector, demandTightPricing, 99209948258706467662)
        );
        router.swap(address(pool), 200e18, true, taker, demandTightPricing);
        vm.stopPrank();
    }

    /// And a bound the ladder can satisfy goes through untouched.
    function test_aReachableBoundDoesNotBlockTheTrade() public {
        _seed(alice, 0, 1e18);
        _seed(wide, 2, 1_000e18);
        uint256 out = _buy(200e18, 98e18);
        assertGt(out, 98e18, "a bound the ladder can meet is simply met");
    }

    // ---- 2. bands do not nest ----------------------------------------------

    /**
     * The nesting question, answered as an assertion. A small trade fills entirely in
     * band 0. The band 2 provider put up 1,000 base and earns NOTHING from it -- their
     * liquidity was offered at a worse price and was not needed.
     */
    function test_aWideBandEarnsNothingFromATradeThatNeverReachesIt() public {
        uint256 tight = _seed(alice, 0, 1_000e18);
        uint256 far = _seed(wide, 2, 1_000e18);

        _buy(100e18, 0); // small: band 0 absorbs all of it

        (uint256 tightBase,) = _accrued(tight);
        (uint256 farBase,) = _accrued(far);
        assertGt(tightBase, 0, "the tight band did the work and earned");
        assertEq(farBase, 0, "the wide band did not fill, so it did not earn");
    }

    /// Once the tight band is exhausted, the wide band starts earning -- at its price.
    function test_theWideBandEarnsOnceTheLadderReachesIt() public {
        uint256 tight = _seed(alice, 0, 1e18);
        uint256 far = _seed(wide, 2, 1_000e18);

        _buy(200e18, 0);

        (uint256 farBase,) = _accrued(far);
        (uint256 tightBase,) = _accrued(tight);
        assertGt(farBase, 0, "reached, so it earned");
        assertGt(tightBase, 0, "and the tight band earned on its own slice");
    }

    // ---- 3. one deposit across the whole ladder ------------------------------

    /**
     * What a token launcher actually wants: depth at every price, in one transaction.
     * This is the DLMM-shaped answer -- place across the range in one action -- without
     * changing how the pool fills. In v2 that one action is also ONE token: the
     * position holds every band, each band still its own share pool inside the pool.
     */
    function test_aLauncherSeedsEveryBandInOneCall() public {
        uint8[] memory bands = new uint8[](3);
        bands[0] = 0; bands[1] = 1; bands[2] = 2;
        uint256[] memory baseAmts = new uint256[](3);
        baseAmts[0] = 40e18; baseAmts[1] = 25e18; baseAmts[2] = 60e18;
        uint256[] memory quoteAmts = new uint256[](3);

        uint256 id = _mint(alice, bands, baseAmts, quoteAmts);

        assertEq(manager.balanceOf(alice, id), 1, "one token for the whole ladder");
        assertEq(manager.nextTokenId(), id + 1, "and no other token was minted");
        assertEq(pool.bandMaskOf(id), 0x07, "holding all three bands");
        (IBandPool.BandView[] memory held,,) = pool.positionView(id);
        assertEq(held.length, 3);
        for (uint256 i = 0; i < 3; i++) {
            assertEq(held[i].band, uint8(i));
            assertEq(held[i].shares, baseAmts[i], "each band priced on its own");
            // All age from now: no band inherits another's vesting clock.
            assertEq(held[i].createdAt, 1_000_000);
        }
        (uint256 r0,) = pool.bandReserves(0);
        (uint256 r2,) = pool.bandReserves(2);
        assertEq(r0, 40e18);
        assertEq(r2, 60e18);
    }

    function test_mismatchedArraysAreRefused() public {
        uint8[] memory bands = new uint8[](2);
        bands[1] = 1;
        uint256[] memory one = new uint256[](1);
        uint256[] memory two = new uint256[](2);
        vm.expectRevert(IBandPositionManager.LengthMismatch.selector);
        manager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: one,
                quoteAmounts: two,
                minShares: new uint128[](2),
                recipient: alice,
                deadline: block.timestamp
            })
        );
    }

    // ---- 4. bands are fractions of the pair's limit ----------------------------

    function _tolerances() internal view returns (uint32[3] memory buy, uint32[3] memory sell) {
        for (uint8 i = 0; i < 3; i++) {
            (buy[i], sell[i]) = pool.bandTolerances(i);
        }
    }

    /**
     * One spread change and one sync move EVERY band, and the ladder keeps its shape.
     * Until the sync, swaps keep pricing off the stored limit: the pool never reads the
     * engine's spread on the swap path.
     */
    function test_aSpreadChangeMovesEveryBandOnSync() public {
        _seed(alice, 0, 1_000e18);
        (uint32[3] memory buy, uint32[3] memory sell) = _tolerances();
        assertEq(buy[0], 100000, "0.10%");
        assertEq(buy[1], 300000, "0.30%");
        assertEq(buy[2], 500000, "0.50%");
        assertEq(sell[2], 500000);

        eng.setSpread_(1000000); // the pair's limit doubles to 1%
        assertEq(pool.liveLimit(true), 1000000, "the engine says 1%");
        assertEq(pool.pairLimit(true), LIMIT, "the pool has not heard yet");

        _buy(10e18, 0);
        assertEq(eng.lastReported(), 200200000, "before the sync, band 0 still fills at +0.10%");

        pool.syncLimit();
        (buy, sell) = _tolerances();
        assertEq(buy[0], 200000, "band 0 doubled");
        assertEq(buy[1], 600000, "band 1 doubled");
        assertEq(buy[2], 1000000, "band 2 doubled, still exactly the limit");
        assertEq(sell[0], 200000);
        assertEq(sell[1], 600000);
        assertEq(sell[2], 1000000);

        _buy(10e18, 0);
        assertEq(eng.lastReported(), 200400000, "and the next fill prices at +0.20%");
    }

    /**
     * A limit too small to express a band's fraction at 8 decimals rounds that band's
     * tolerance to zero. The band is idle -- not priced at the anchor with no spread --
     * and the trade falls through to the next band that can quote.
     */
    function test_aBandWhoseToleranceRoundsToZeroIsSkipped() public {
        _seed(alice, 0, 1_000e18); // deep, so a fill would have been easy
        _seed(wide, 1, 1_000e18);

        // Limit 4 (4e-8): band 0 is 20% of it = 0.8 -> 0, band 1 is 60% = 2.4 -> 2.
        eng.setSpread_(4);
        pool.syncLimit();
        (uint32 b0buy, uint32 b0sell) = pool.bandTolerances(0);
        (uint32 b1buy,) = pool.bandTolerances(1);
        assertEq(b0buy, 0, "band 0 cannot be expressed");
        assertEq(b0sell, 0);
        assertEq(b1buy, 2, "band 1 can, just");

        (, , uint256 g0Before,,) = pool.bands(0);
        uint256 out = _buy(10e18, 0);
        assertGt(out, 0, "the trade still fills");

        (uint256 r0,) = pool.bandReserves(0);
        (uint256 r1, uint256 q1) = pool.bandReserves(1);
        (, , uint256 g0After,,) = pool.bands(0);
        assertEq(r0, 1_000e18, "band 0 was never touched");
        assertEq(g0After, g0Before, "and earned nothing");
        assertLt(r1, 1_000e18, "band 1 took the whole trade");
        assertEq(q1, 10e18, "all of it");
        // ceil(2e8 × (1e8 + 2) / 1e8) = 200000004: band 1's bound, rounded up.
        assertEq(eng.lastReported(), 200000004, "priced at band 1's bound");
    }
}
