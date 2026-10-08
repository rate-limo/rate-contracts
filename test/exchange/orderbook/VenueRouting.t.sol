// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {MarketMakePriceLib} from "../../../src/exchange/libraries/MarketMakePriceLib.sol";
import {StopLimitOrderbook} from "../../../src/exchange/orderbooks/StopLimitOrderbook.sol";
import {Orderbook} from "../../../src/exchange/orderbooks/Orderbook.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";
import {StopOrderEngine} from "../../../src/exchange/StopOrderEngine.sol";

/// Records any call at all. Wired in as the pair's pool so a book order that touched
/// it would be caught -- proving a negative needs something that can notice.
contract RecordingPool {
    uint256 public calls;
    fallback() external payable { calls++; }
    receive() external payable { calls++; }
}

/**
 * WHICH venue does what, pinned.
 *
 * A pair has three of them and only one can match anything:
 *
 *   Orderbook           bids and asks. Every fill in the system happens here.
 *   StopLimitOrderbook  custody and a trigger queue. It matches NOTHING -- when a
 *                       stop crosses, `activate` moves the tokens into the Orderbook
 *                       (or, for a stop-market, to the engine) and the fill happens
 *                       there, on a second pass.
 *   BandPool            settles on its own, through BandSwapRouter. The engine never
 *                       routes an order into it; the only thing that flows back is a
 *                       price report.
 *
 * The swap side of this is already covered -- BandSpreadSide and BandLadder pin how a
 * band ladder fills and when the rail clamps its report. What had no coverage is the
 * exchange side: that a dormant stop is genuinely absent from the book, what price it
 * arrives at when it stops being dormant, and that a book order never reaches the pool.
 */
contract VenueRoutingTest is BaseSetup {
    uint256 private constant INITIAL_PRICE = 100e8;
    /// 20% of DENOM. Wide enough that the spread is never the thing under test.
    uint32 private constant WIDE = 20_000_000;

    StopOrderEngine private stopEngine;
    address private pair;
    address private stopBook;

    function setUp() public override {
        super.setUp();
        stopEngine = new StopOrderEngine(address(matchingEngine));
        matchingEngine.setStopOrderEngine(address(stopEngine));
        matchingEngine.addPair(
            address(token1), address(token2), INITIAL_PRICE, 0, address(token1),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        pair = matchingEngine.getPair(address(token1), address(token2));
        stopBook = stopEngine.stopOrderbooks(pair);
        matchingEngine.setSpread(address(token1), address(token2), WIDE, WIDE, true);
        matchingEngine.setSpread(address(token1), address(token2), WIDE, WIDE, false);
        vm.startPrank(trader1);
        token1.approve(address(stopEngine), type(uint256).max);
        token2.approve(address(stopEngine), type(uint256).max);
        vm.stopPrank();
    }

    function _heads() private view returns (uint256 bidHead, uint256 askHead) {
        return matchingEngine.heads(address(token1), address(token2));
    }

    function _ask(address who, uint256 price, uint256 amount, bool maker, uint32 n) private {
        vm.prank(who);
        matchingEngine.limitSell(IMatchingEngine.LimitOrderInput({
            base: address(token1), quote: address(token2), price: price,
            amount: amount, isMaker: maker, n: n, recipient: who
        }));
    }

    function _bid(address who, uint256 price, uint256 amount, bool maker, uint32 n) private {
        vm.prank(who);
        matchingEngine.limitBuy(IMatchingEngine.LimitOrderInput({
            base: address(token1), quote: address(token2), price: price,
            amount: amount, isMaker: maker, n: n, recipient: who
        }));
    }

    // ---- the stop book holds; it does not quote -------------------------------

    /// A dormant stop is not an order. Its tokens are in StopLimitOrderbook's custody
    /// and the only thing exposed is a trigger price, so there is nothing in the book
    /// for a taker to hit -- which is the whole reason the second venue exists.
    function test_aDormantStopIsNotInTheBook() public {
        vm.prank(trader1);
        uint32 id = stopEngine.placeStopLimit(
            address(token1), address(token2), false, 90e8, 80e8, 1e18, trader1
        );

        (uint256 bidHead, uint256 askHead) = _heads();
        assertEq(bidHead, 0, "no bid");
        assertEq(askHead, 0, "and no ask -- the stop is not resting at 80");

        assertEq(token1.balanceOf(stopBook), 1e18, "the stop book holds the base");
        assertEq(token1.balanceOf(pair), 0, "the orderbook holds nothing");
        assertEq(StopLimitOrderbook(stopBook).triggerHead(false), 90e8, "only a trigger price is exposed");
        assertEq(stopEngine.getOrder(address(token1), address(token2), false, id).owner, trader1);
    }

    /// Activation is a custody transfer, not a match: the base leaves the stop book for
    /// the Orderbook, and the fill that follows is an ordinary Orderbook fill on the
    /// taker's second pass.
    function test_activationMovesCustodyAndTheOrderbookDoesTheFilling() public {
        vm.prank(trader1);
        uint32 id = stopEngine.placeStopLimit(
            address(token1), address(token2), false, 90e8, 80e8, 1e18, trader1
        );

        // Drive lmp under the trigger without touching the stop: an ask at 80 that a
        // taker consumes. The stop is crossed from here on, and still dormant.
        _ask(trader1, 80e8, 1e18, true, 2);
        _bid(trader2, 80e8, 80e18, false, 1);
        assertEq(stopEngine.getOrder(address(token1), address(token2), false, id).owner, trader1,
            "still dormant: that taker's single match went to the regular book");

        uint256 stopBookBefore = token1.balanceOf(stopBook);
        uint256 baseBefore = token1.balanceOf(trader2);

        // A taker with budget to spare. The regular book is empty, so pass 1 matches
        // nothing and the whole order reaches the handoff.
        _bid(trader2, 80e8, 80e18, false, 2);

        assertEq(stopBookBefore - token1.balanceOf(stopBook), 1e18, "the stop book gave up custody");
        assertGt(token1.balanceOf(trader2) - baseBefore, 0, "and the taker was filled");
        assertEq(stopEngine.getOrder(address(token1), address(token2), false, id).owner, address(0),
            "the stop is gone from the trigger queue");
    }

    // ---- the price an activated stop arrives at -------------------------------

    /// **The fix, and what it replaced.** An activated stop-limit used to be handed
    /// straight to `placeBid` at its raw `limitPrice`, skipping both bounds every other
    /// resting order passes. A buy stop with a limit of 200 activating over an ask at 120
    /// rested at 200 and left `bidHead > askHead` — a crossed book the ordinary path
    /// cannot produce, because `MarketMakePriceLib.limitBuy` caps a make price at the ask
    /// head precisely to prevent it.
    ///
    /// `StopOrderMatchingLib._restingPrice` now applies the same rule, so the order lands
    /// ON the ask head rather than through it. Locked, not crossed — which is exactly what
    /// the ordinary path produces in the same situation.
    function test_anActivatedStopLimitIsClampedToTheAskHead() public {
        vm.prank(trader1);
        stopEngine.placeStopLimit(
            address(token1), address(token2), true, 110e8, 200e8, 200e18, trader1
        );
        _ask(trader1, 120e8, 1e18, true, 2);
        _ask(trader1, 110e8, 1e18, true, 2);
        _bid(trader2, 110e8, 200e18, false, 3);

        (uint256 bidHead, uint256 askHead) = _heads();
        assertEq(bidHead, 120e8, "clamped to the ask head, not resting at 200");
        assertEq(askHead, 120e8, "and the ask is still there");
        assertLe(bidHead, askHead, "the book is not crossed");
        assertEq(
            bidHead, MarketMakePriceLib.limitBuy(110e8, 200e8, 0, 120e8, WIDE),
            "the same answer an ordinary limit buy would have been given"
        );
    }

    /// With nothing in the way, the OTHER bound does the work — and this is the one that
    /// matters for the oracle. A level can only be created within one spread of `lmp`, so
    /// matching can only move the price a bounded step. `lmp` is 110 and the spread is
    /// 20%, so the furthest an activation can plant a bid is 132.
    function test_withNothingInTheWayTheSpreadStillBoundsTheRestingPrice() public {
        vm.prank(trader1);
        stopEngine.placeStopLimit(
            address(token1), address(token2), true, 110e8, 200e8, 200e18, trader1
        );
        _ask(trader1, 110e8, 1e18, true, 2);
        _bid(trader2, 110e8, 200e18, false, 3);

        (uint256 bidHead, uint256 askHead) = _heads();
        assertEq(askHead, 0, "no ask to clamp against");
        assertEq(bidHead, 132e8, "so the spread bound applies: 110 x 1.20");
        assertEq(bidHead, (110e8 * (1e8 + uint256(WIDE))) / 1e8, "exactly one spread from lmp");
    }

    /// The circuit breaker, end to end. Before the clamp, one ordinary sell into the
    /// unrailed bid printed 200 under a 2% spread that caps a legitimate make price at
    /// 112.20, and `setLmp` carried it into the TWAP the swap pool anchors on.
    ///
    /// Now there is no level to hit. The seller asking 200 finds a book that tops out at
    /// 120, matches nothing, and both `lmp` and the oracle stay where the market is.
    function test_theClampKeepsTheCircuitBreakerAndTheTwapIntact() public {
        vm.prank(trader1);
        stopEngine.placeStopLimit(
            address(token1), address(token2), true, 110e8, 200e8, 200e18, trader1
        );
        _ask(trader1, 120e8, 1e18, true, 2);
        _ask(trader1, 110e8, 1e18, true, 2);
        _bid(trader2, 110e8, 200e18, false, 3);

        vm.warp(block.timestamp + 600);
        (uint256 twapBefore,) = Orderbook(payable(pair)).twap(300);
        assertEq(twapBefore, 110e8, "the oracle agrees with the market");

        uint32 tight = 2_000_000; // 2%
        matchingEngine.setSpread(address(token1), address(token2), tight, tight, true);
        matchingEngine.setSpread(address(token1), address(token2), tight, tight, false);

        // The order that used to do the damage.
        _ask(trader2, 200e8, 1e18, false, 2);
        assertEq(Orderbook(payable(pair)).lmp(), 110e8, "nothing at 200 to sell into");

        vm.warp(block.timestamp + 300);
        (uint256 twapAfter,) = Orderbook(payable(pair)).twap(300);
        assertEq(twapAfter, 110e8, "and the pool's anchor never moved");
    }

    /// The clamp can only ever help the owner, in both directions: `limitBuy` is a pair
    /// of minima, so a buy is moved DOWN and the same deposit buys more base; `limitSell`
    /// is a pair of maxima, so a sell is moved UP and the same base fetches more quote.
    /// That is why this is a safe change to make to orders already resting on chain.
    function test_clampingIsNeverWorseForTheStopOwner() public {
        // Sell stop asking for a fire-sale price of 10, with lmp at 88 and a 20% spread.
        vm.prank(trader1);
        stopEngine.placeStopLimit(
            address(token1), address(token2), false, 90e8, 10e8, 1e18, trader1
        );
        _ask(trader1, 88e8, 1e18, true, 2);
        _bid(trader2, 88e8, 88e18, false, 1);           // fully filled: wakes nothing
        assertEq(Orderbook(payable(pair)).lmp(), 88e8);

        _bid(trader2, 88e8, 10e18, false, 3);            // small: activates, fills a little

        (, uint256 askHead) = _heads();
        assertEq(askHead, 70.4e8, "floored to one spread below lmp, not left at 10");
        assertGt(askHead, 10e8, "strictly better than the price the owner asked for");
        assertEq(
            askHead, MarketMakePriceLib.limitSell(88e8, 10e8, 0, 0, WIDE),
            "the same answer an ordinary limit sell would have been given"
        );
    }

    /// Why a taker who is completely filled never wakes a stop, even a crossed one.
    ///
    /// `MatchingLib.matchAt` returns `(0, matchAtInput.n)` on the branch where the
    /// taker's remainder is exhausted -- so `matchesUsed` comes back as the WHOLE
    /// budget, not the number of orders actually matched. The handoff then sees
    /// `used >= n` and returns on its first line. The same order with a remainder
    /// activates the identical stop, which is the only difference between the two
    /// halves of this test.
    function test_aCompletelyFilledTakerReportsTheWholeBudgetAndWakesNothing() public {
        vm.prank(trader1);
        uint32 id = stopEngine.placeStopLimit(
            address(token1), address(token2), true, 110e8, 200e8, 200e18, trader1
        );

        _ask(trader1, 110e8, 1e18, true, 2);
        _ask(trader1, 110e8, 1e18, true, 2);

        // Exactly consumed: one match of a three-match budget, and yet nothing activates.
        _bid(trader2, 110e8, 110e18, false, 3);
        assertEq(stopEngine.getOrder(address(token1), address(token2), true, id).owner, trader1,
            "crossed at 110, and still dormant after a one-match order with n = 3");
        (uint256 bidHead,) = _heads();
        assertEq(bidHead, 0, "nothing was placed in the book");

        // The same order, sized to leave a remainder, does activate it.
        _bid(trader2, 110e8, 200e18, false, 3);
        assertEq(stopEngine.getOrder(address(token1), address(token2), true, id).owner, address(0),
            "a remainder is what carries the order into the stop book");
    }

    // ---- the pool is not on the engine's path ---------------------------------

    /// MatchingEngine creates a pool and records it on the pair, and that is the whole
    /// relationship: `addPair` calls `setPool`, and nothing in the matching path ever
    /// calls the address back. Price flows the other way, through `reportSwap`.
    function test_aBookOrderNeverCallsThePool() public {
        RecordingPool pool = new RecordingPool();
        vm.prank(address(matchingEngine));
        Orderbook(payable(pair)).setPool(address(pool));
        assertEq(Orderbook(payable(pair)).getPool(), address(pool), "the pair knows the pool");

        // A full market order: matches a resting ask, then makes with the remainder.
        _ask(trader1, 110e8, 1e18, true, 2);
        vm.prank(trader2);
        matchingEngine.marketBuy(IMatchingEngine.MarketOrderInput({
            base: address(token1), quote: address(token2), amount: 200e18,
            isMaker: true, n: 3, recipient: trader2, slippageLimit: WIDE
        }));

        (uint256 bidHead,) = _heads();
        assertGt(bidHead, 0, "the order really did match and make");
        assertEq(pool.calls(), 0, "and never once called the pool");
    }
}
