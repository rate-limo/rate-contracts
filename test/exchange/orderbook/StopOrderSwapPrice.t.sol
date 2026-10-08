// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {StopLimitOrderbook} from "../../../src/exchange/orderbooks/StopLimitOrderbook.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";
import {IOrderbook} from "../../../src/exchange/interfaces/IOrderbook.sol";
import {StopOrderEngine} from "../../../src/exchange/StopOrderEngine.sol";

/**
 * What a POOL price does to a stop order, which is the one seam neither suite covered.
 *
 * `test/swap/*` pins the report rail against a stub book, and `StopLimitOrder.t.sol`
 * pins stop activation against book flow. Nothing joined them, so the answer to "a swap
 * pushed the price through my stop -- did it trigger?" was inferred from two files that
 * never met. It is inferable and it is also counter-intuitive, which is exactly the kind
 * of thing that should be a test rather than a reading.
 *
 * The engine is wired to this contract as its `swapRouter`, so `reportSwap` can be called
 * directly. That is the whole of the swap side's authority over price -- a real
 * BandSwapRouter reaches the engine through this one function and nothing else -- so a
 * pool is not needed to reproduce what a pool can do.
 */
contract StopOrderSwapPriceTest is BaseSetup {
    uint256 private constant INITIAL_PRICE = 100e8;
    /// 20% of DENOM. Wide enough that the rail is not the thing under test.
    uint32 private constant WIDE_SPREAD = 20_000_000;

    StopOrderEngine private stopEngine;
    address private pair;

    function setUp() public override {
        super.setUp();
        stopEngine = new StopOrderEngine(address(matchingEngine));
        matchingEngine.setStopOrderEngine(address(stopEngine));
        // This test contract IS the router. `reportSwap` gates on exactly this.
        matchingEngine.setSwapRouter(address(this));
        matchingEngine.addPair(
            address(token1), address(token2), INITIAL_PRICE, 0, address(token1),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        pair = matchingEngine.getPair(address(token1), address(token2));
        vm.prank(trader1);
        token1.approve(address(stopEngine), type(uint256).max);
        vm.prank(trader1);
        token2.approve(address(stopEngine), type(uint256).max);
        // Report and match in a later block than the listing write, so the rail's
        // block-open anchor is unambiguously the listing price rather than a fallback.
        vm.roll(block.number + 1);
    }

    /// Sell one BASE at a limit of 80 once the price falls to 90. Dormant at 100.
    function _placeSellStop() private returns (uint32 stopId) {
        vm.prank(trader1);
        stopId = stopEngine.placeStopLimit(
            address(token1), address(token2), false, 90e8, 80e8, 1e18, trader1
        );
    }

    /// A taker bid with nothing on the regular book to match. The regular pass returns
    /// untouched, so the whole match budget and the whole deposit reach the stop handoff --
    /// the cleanest way to ask whether the stop is crossed.
    function _takerBuy(uint32 n) private {
        vm.prank(trader2);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 90e8,
                amount: 90e18,
                isMaker: false,
                n: n,
                recipient: trader2
            })
        );
    }

    function _stop(uint32 stopId) private view returns (StopLimitOrderbook.StopOrder memory) {
        return stopEngine.getOrder(address(token1), address(token2), false, stopId);
    }

    // ---------------------------------------------------------------------------

    /// A pool print moves the reference price a stop is measured against, and stops there.
    /// Activation is only ever reached through `MatchingEngine._limitOrder`; `reportSwap`
    /// writes `lmp` through `MatchingLib.reportSwapPrice` and never calls the stop engine.
    function test_aSwapReportCrossesTheTriggerAndActivatesNothing() public {
        uint32 stopId = _placeSellStop();
        matchingEngine.setSpread(address(token1), address(token2), WIDE_SPREAD, WIDE_SPREAD, true);

        matchingEngine.reportSwap(address(token1), address(token2), false, 88e8);

        assertEq(IOrderbook(pair).lmp(), 88e8, "the swap price is the pair's price now");
        assertEq(_stop(stopId).owner, trader1, "the stop is crossed and still dormant");
        assertEq(_stop(stopId).depositAmount, 1e18, "its deposit never moved");
    }

    /// The trigger is not lost, only deferred: the next order that goes through the book
    /// reads the price the pool wrote and activates against it.
    function test_theNextBookOrderPicksUpTheStopThePoolTriggered() public {
        uint32 stopId = _placeSellStop();
        matchingEngine.setSpread(address(token1), address(token2), WIDE_SPREAD, WIDE_SPREAD, true);
        matchingEngine.setSpread(address(token1), address(token2), WIDE_SPREAD, WIDE_SPREAD, false);
        matchingEngine.reportSwap(address(token1), address(token2), false, 88e8);

        uint256 baseBefore = token1.balanceOf(trader2);
        _takerBuy(2);

        assertEq(_stop(stopId).owner, address(0), "activated by the first book order after the print");
        assertEq(
            token1.balanceOf(trader2) - baseBefore, 0.999e18,
            "and the taker filled against it at the stop's own limit"
        );
    }

    /// The rail is what actually stands between a pool and a stop order. At the pair's
    /// configured market spread a single print cannot reach a trigger further away than
    /// the spread, however far from the book the pool traded -- so the answer to a
    /// pool/book price mismatch is that the book takes the clamped price, not the reported
    /// one, and a stop beyond the clamp is not crossed by it.
    function test_theRailStopsAPrintFromReachingATriggerBeyondTheSpread() public {
        uint32 stopId = _placeSellStop();
        // Left at the pair's default 2% market spread.
        matchingEngine.setSpread(address(token1), address(token2), WIDE_SPREAD, WIDE_SPREAD, false);

        matchingEngine.reportSwap(address(token1), address(token2), false, 88e8);

        assertEq(IOrderbook(pair).lmp(), 98e8, "clamped to the block-open anchor minus 2%");
        _takerBuy(2);
        assertEq(_stop(stopId).owner, trader1, "90 was never reached, so the stop is untouched");
    }

    /// And the clamp does not compound: a second print in the same block is measured
    /// against the price the block OPENED at, not against the first print's write. Without
    /// this a pool could walk a stop's trigger in one transaction, one cap at a time.
    function test_repeatedPrintsInOneBlockCannotWalkTheTrigger() public {
        uint32 stopId = _placeSellStop();
        matchingEngine.setSpread(address(token1), address(token2), WIDE_SPREAD, WIDE_SPREAD, false);

        for (uint256 i = 0; i < 5; i++) {
            matchingEngine.reportSwap(address(token1), address(token2), false, 88e8);
        }

        assertEq(IOrderbook(pair).lmp(), 98e8, "five prints land on the same floor as one");
        _takerBuy(2);
        assertEq(_stop(stopId).owner, trader1, "still dormant");
    }
}
