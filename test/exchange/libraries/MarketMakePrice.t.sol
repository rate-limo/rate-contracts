// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MarketMakePriceLib} from "../../../src/exchange/libraries/MarketMakePriceLib.sol";

/**
 * The make-price rule, pinned as numbers.
 *
 * Every existing assertion on a make price -- LimitOrder.t.sol and MarketOrder.t.sol --
 * compares the engine's answer against a SECOND COPY of the branch tree written inside
 * the test file. That copy has drifted: on a two-sided book its `_detLimitBuyMakePrice`
 * computes `max(lp, lmp)` capped at askHead and never applies the spread at all, where
 * MarketMakePriceLib caps `lp` at `lmp * (1 + spread)` first. Those suites still pass
 * because the cases they run land in the single-sided branches, where the two agree.
 *
 * A test that re-derives the answer cannot catch a wrong rule, only an inconsistent one.
 * These are literals: 100 with a 2% spread makes at 102, and if that ever stops being
 * true a person decided it, rather than a helper quietly agreeing with the change.
 *
 * The four functions are the whole rule. `_detMarketBuyMakePrice` and friends in
 * MatchingEngine read `lmp` and call straight through.
 */
contract MarketMakePriceTest is Test {
    uint256 private constant DENOM = 100_000_000;
    /// 2% of DENOM -- the default both spreads are listed at.
    uint32 private constant SPREAD = 2_000_000;

    uint256 private constant P100 = 100e8;

    // ---- market buy: pay up to one spread above the reference ------------------

    /// Nothing resting: the spread is measured off `lmp`, which is the only price there is.
    function test_buy_emptyBook_isLmpPlusSpread() public pure {
        assertEq(MarketMakePriceLib.buy(P100, 0, 0, SPREAD), 102e8);
    }

    /// No lmp and no book is no price. A zero answer is the signal not to make at all.
    function test_buy_emptyBookAndNoLmp_isZero() public pure {
        assertEq(MarketMakePriceLib.buy(0, 0, 0, SPREAD), 0);
    }

    /// Bids only: the reference is whichever of lmp and the bid head is HIGHER. A bid
    /// above lmp is a live price somebody is standing behind; lmp may be stale.
    function test_buy_bidsOnly_referenceIsTheHigherOfLmpAndBidHead() public pure {
        assertEq(MarketMakePriceLib.buy(P100, 105e8, 0, SPREAD), 107.1e8);
        assertEq(MarketMakePriceLib.buy(P100, 95e8, 0, SPREAD), 102e8);
        assertEq(MarketMakePriceLib.buy(0, 95e8, 0, SPREAD), 96.9e8);
    }

    /// Asks resting: the make price never crosses the ask head. Making above it would
    /// print a crossed book -- an order that should have matched instead resting.
    function test_buy_asksOnly_neverCrossesTheAskHead() public pure {
        assertEq(MarketMakePriceLib.buy(P100, 0, 101e8, SPREAD), 101e8, "spread would reach 102; the ask caps it");
        assertEq(MarketMakePriceLib.buy(P100, 0, 110e8, SPREAD), 102e8, "ask is out of reach; the spread binds");
        assertEq(MarketMakePriceLib.buy(0, 0, 110e8, SPREAD), 110e8, "no lmp: the ask head IS the price");
    }

    /// Two-sided: both rules apply, spread first and the ask head last.
    function test_buy_twoSided_takesTheTighterOfSpreadAndAskHead() public pure {
        assertEq(MarketMakePriceLib.buy(P100, 99e8, 110e8, SPREAD), 102e8);
        assertEq(MarketMakePriceLib.buy(P100, 99e8, 101e8, SPREAD), 101e8);
        assertEq(MarketMakePriceLib.buy(0, 99e8, 110e8, SPREAD), 110e8);
    }

    // ---- market sell: the mirror, floored rather than capped --------------------

    function test_sell_emptyBook_isLmpMinusSpread() public pure {
        assertEq(MarketMakePriceLib.sell(P100, 0, 0, SPREAD), 98e8);
        assertEq(MarketMakePriceLib.sell(0, 0, 0, SPREAD), 0);
    }

    /// A price of 1 rather than 0 when the spread would round the whole way down: zero
    /// is the "do not make" signal, so the floor must never accidentally produce it.
    function test_sell_neverFloorsToZero() public pure {
        assertEq(MarketMakePriceLib.sell(1, 0, 0, DENOM_MINUS_ONE()), 1);
    }

    function DENOM_MINUS_ONE() private pure returns (uint32) {
        return uint32(DENOM) - 1;
    }

    /// Bids resting: the make price never falls through the bid head, for the same
    /// reason the buy side never crosses the ask.
    function test_sell_bidsOnly_neverCrossesTheBidHead() public pure {
        assertEq(MarketMakePriceLib.sell(P100, 99e8, 0, SPREAD), 99e8, "spread reaches 98; the bid holds it at 99");
        assertEq(MarketMakePriceLib.sell(P100, 95e8, 0, SPREAD), 98e8, "bid is out of reach; the spread binds");
        assertEq(MarketMakePriceLib.sell(0, 95e8, 0, SPREAD), 95e8, "no lmp: the bid head IS the price");
    }

    /// Asks only: the reference is the LOWER of lmp and the ask head, mirroring the
    /// buy side's higher-of.
    function test_sell_asksOnly_referenceIsTheLowerOfLmpAndAskHead() public pure {
        assertEq(MarketMakePriceLib.sell(P100, 0, 99e8, SPREAD), 97.02e8);
        assertEq(MarketMakePriceLib.sell(P100, 0, 110e8, SPREAD), 98e8);
        assertEq(MarketMakePriceLib.sell(0, 0, 110e8, SPREAD), 107.8e8);
    }

    function test_sell_twoSided_takesTheTighterOfSpreadAndBidHead() public pure {
        assertEq(MarketMakePriceLib.sell(P100, 99e8, 110e8, SPREAD), 99e8);
        assertEq(MarketMakePriceLib.sell(P100, 90e8, 110e8, SPREAD), 98e8);
        assertEq(MarketMakePriceLib.sell(0, 90e8, 110e8, SPREAD), 90e8);
    }

    // ---- limit orders: the trader's own price, then the same two rails ----------

    /// The limit price is honoured when it sits inside the spread, and clipped to the
    /// spread when it does not. This is the difference between a limit and a market
    /// order here: the trader supplies the price, the venue supplies the bounds.
    function test_limitBuy_clipsTheTradersPriceToTheSpread() public pure {
        assertEq(MarketMakePriceLib.limitBuy(P100, 110e8, 0, 0, SPREAD), 102e8, "asked 110, allowed 102");
        assertEq(MarketMakePriceLib.limitBuy(P100, 101e8, 0, 0, SPREAD), 101e8, "asked inside the spread, kept");
        assertEq(MarketMakePriceLib.limitBuy(0, 110e8, 0, 0, SPREAD), 110e8, "no reference price, no clip");
    }

    /// With no lmp the bid head stands in as the reference -- the case the stale copy in
    /// LimitOrder.t.sol applies unconditionally.
    function test_limitBuy_bidsOnly_fallsBackToTheBidHeadOnlyWhenLmpIsZero() public pure {
        assertEq(MarketMakePriceLib.limitBuy(P100, 110e8, 99e8, 0, SPREAD), 102e8, "lmp is the reference");
        assertEq(MarketMakePriceLib.limitBuy(0, 110e8, 99e8, 0, SPREAD), 100.98e8, "bid head is the fallback");
    }

    function test_limitBuy_neverCrossesTheAskHead() public pure {
        assertEq(MarketMakePriceLib.limitBuy(P100, 110e8, 0, 101e8, SPREAD), 101e8);
        assertEq(MarketMakePriceLib.limitBuy(P100, 110e8, 99e8, 105e8, SPREAD), 102e8);
        assertEq(MarketMakePriceLib.limitBuy(0, 110e8, 99e8, 105e8, SPREAD), 105e8);
    }

    function test_limitSell_clipsTheTradersPriceToTheSpread() public pure {
        assertEq(MarketMakePriceLib.limitSell(P100, 90e8, 0, 0, SPREAD), 98e8, "asked 90, allowed 98");
        assertEq(MarketMakePriceLib.limitSell(P100, 99e8, 0, 0, SPREAD), 99e8, "asked inside the spread, kept");
        assertEq(MarketMakePriceLib.limitSell(0, 90e8, 0, 0, SPREAD), 90e8, "no reference price, no clip");
    }

    function test_limitSell_neverCrossesTheBidHead() public pure {
        assertEq(MarketMakePriceLib.limitSell(P100, 90e8, 99e8, 0, SPREAD), 99e8);
        assertEq(MarketMakePriceLib.limitSell(P100, 90e8, 99e8, 110e8, SPREAD), 98e8);
        assertEq(MarketMakePriceLib.limitSell(0, 90e8, 99e8, 110e8, SPREAD), 99e8);
    }

    // ---- the worked ETH/USDC example --------------------------------------------

    /// The seven cases in the ETH/USDC walkthrough, at a 3,000 print and a 2% spread.
    /// Pinned here so the explainer and the contract cannot drift apart: if one of these
    /// numbers changes, the walkthrough is wrong and this test says so.
    function test_ethUsdcWorkedExamples() public pure {
        uint256 lmp = 3000e8;
        assertEq(MarketMakePriceLib.buy(lmp, 0, 0, SPREAD), 3060e8, "quiet book");
        assertEq(MarketMakePriceLib.buy(lmp, 3050e8, 0, SPREAD), 3111e8, "bid above the print");
        assertEq(MarketMakePriceLib.buy(lmp, 0, 3020e8, SPREAD), 3020e8, "an ask in the way");
        assertEq(MarketMakePriceLib.buy(lmp, 2950e8, 3100e8, SPREAD), 3060e8, "both sides resting");
        assertEq(MarketMakePriceLib.sell(lmp, 2985e8, 3100e8, SPREAD), 2985e8, "selling into a bid");
        assertEq(MarketMakePriceLib.limitBuy(lmp, 3200e8, 2940e8, 3040e8, SPREAD), 3040e8, "bidding too high");
        assertEq(MarketMakePriceLib.limitSell(lmp, 2970e8, 0, 0, SPREAD), 2970e8, "a fair ask stands");
    }

    // ---- the property that motivates all of it ---------------------------------

    /// One order can never move the reference by more than one spread, in either
    /// direction, for any limit price a trader supplies. This is the same bound the swap
    /// rail applies to a pool report -- the venue has ONE circuit breaker and both the
    /// book and the pool are behind it.
    function testFuzz_aMakePriceStaysWithinOneSpreadOfLmp(uint256 lp) public pure {
        lp = bound(lp, 1, 1e18);
        uint256 buyPrice = MarketMakePriceLib.limitBuy(P100, lp, 0, 0, SPREAD);
        uint256 sellPrice = MarketMakePriceLib.limitSell(P100, lp, 0, 0, SPREAD);
        assertLe(buyPrice, (P100 * (DENOM + SPREAD)) / DENOM);
        assertGe(sellPrice, (P100 * (DENOM - SPREAD)) / DENOM);
    }
}
