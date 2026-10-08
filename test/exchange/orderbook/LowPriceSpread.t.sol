// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {MarketMakePriceLib} from "../../../src/exchange/libraries/MarketMakePriceLib.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {OrderPlacementLib} from "../../../src/exchange/libraries/OrderPlacementLib.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";
import {Orderbook} from "../../../src/exchange/orderbooks/Orderbook.sol";
import {BaseSetup} from "../OrderbookBaseSetup.sol";

/**
 * A nonzero spread must move the buy-side rail by at least one tick.
 *
 * Prices live on a 1e8 grid, so a coin worth 0.000005 quote sits at 500 and one tick there is
 * 0.2%. The buy rail was `lmp * (1 + spread)` FLOORED: at 500 with the production 0.1% spread,
 * 500 * 1.001 = 500.5 floors back to 500, so a market buy's limit equalled the last price and
 * it could never take an ask one tick up. Every price below 1,000 had the same property --
 * the market could not move up through the rail at all. Found on RISE KPRF1448/tUSD.
 *
 * The sell rail floors too, and flooring is already its favour-of-filling direction
 * (499.5 -> 499), so only the buy side changed. These cases pin both, plus the normal-price
 * behaviour, which is unchanged whenever the product is whole.
 */
contract LowPriceSpreadTest is BaseSetup {
    uint32 constant SPREAD = 100_000; // 0.1% on the 1e8 grid -- RISE's market spread
    uint256 constant DENOM = 1e8;

    function _flooredUp(uint256 p) internal pure returns (uint256) {
        return (p * (DENOM + SPREAD)) / DENOM;
    }

    /* ------------------------------ the rail, as literals ------------------------------ */

    function test_buyRail_movesOneTick_from100To900() public pure {
        for (uint256 p = 100; p < 1000; p += 100) {
            assertEq(_flooredUp(p), p, "precondition: flooring erased the whole spread here");
            assertEq(MarketMakePriceLib.buy(p, 0, 0, SPREAD), p + 1, "buy make price must step up");
            assertEq(
                MarketMakePriceLib.limitBuy(p, type(uint256).max, 0, 0, SPREAD), p + 1, "limitBuy rail must step up"
            );
            assertEq(MarketMakePriceLib.sell(p, 0, 0, SPREAD), p - 1, "sell already steps down");
            assertEq(MarketMakePriceLib.limitSell(p, 0, 0, 0, SPREAD), p - 1, "limitSell already steps down");
        }
    }

    /// At 1,000 the product is whole (1,001), so rounding changes nothing.
    function test_buyRail_atWholeProducts_isUnchanged() public pure {
        assertEq(MarketMakePriceLib.buy(1000, 0, 0, SPREAD), 1001);
        // ETH/USDC-shaped: 3,000.00000000 quote -- whole, so exactly the old value.
        uint256 eth = 3000e8;
        assertEq(MarketMakePriceLib.buy(eth, 0, 0, SPREAD), _flooredUp(eth));
        assertEq(MarketMakePriceLib.limitBuy(eth, type(uint256).max, 0, 0, SPREAD), _flooredUp(eth));
    }

    /// A normal price whose product is fractional moves by exactly one grid unit (1e-8 quote).
    function test_buyRail_atNormalPrices_differsByAtMostOneUnit() public pure {
        uint256 p = 123_456_789;
        assertEq(MarketMakePriceLib.buy(p, 0, 0, SPREAD), _flooredUp(p) + 1);
    }

    /// A ZERO spread is a deliberate "do not move" and must stay exactly the last price.
    function test_zeroSpread_staysPut() public pure {
        for (uint256 p = 100; p <= 1000; p += 100) {
            assertEq(MarketMakePriceLib.buy(p, 0, 0, 0), p);
            assertEq(MarketMakePriceLib.limitBuy(p, type(uint256).max, 0, 0, 0), p);
        }
    }

    /// The rail still never crosses a resting ask: rounding up is capped by the head.
    function test_buyRail_isStillCappedByTheAskHead() public pure {
        assertEq(MarketMakePriceLib.buy(500, 0, 500, SPREAD), 500, "locked, not crossed");
        assertEq(MarketMakePriceLib.limitBuy(500, 600, 0, 500, SPREAD), 500);
    }

    /* ---------------------------------- through the engine ---------------------------------- */

    function _listAt(uint256 price) internal {
        matchingEngine.addPair(
            address(token1), address(token2), price, 0, address(token1),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        book = Orderbook(payable(orderbookFactory.getPair(address(token1), address(token2))));
    }

    function _limit(address who, bool isBid, uint256 price, uint256 amount) internal {
        IMatchingEngine.LimitOrderInput memory o = IMatchingEngine.LimitOrderInput({
            base: address(token1), quote: address(token2), price: price,
            amount: amount, isMaker: true, n: 1, recipient: who
        });
        vm.prank(who);
        if (isBid) matchingEngine.limitBuy(o);
        else matchingEngine.limitSell(o);
    }

    function _market(address who, bool isBid, uint256 amount) internal {
        IMatchingEngine.MarketOrderInput memory o = IMatchingEngine.MarketOrderInput({
            base: address(token1), quote: address(token2), amount: amount,
            isMaker: false, n: 5, recipient: who, slippageLimit: SPREAD
        });
        vm.prank(who);
        if (isBid) matchingEngine.marketBuy(o);
        else matchingEngine.marketSell(o);
    }

    /// The RISE case: last price 500, best ask one tick up at 501, a 0.1% market buy.
    /// Before, the limit floored to 500 < 501, nothing matched and the taker was refunded.
    function test_marketBuy_atPrice500_takesTheAskOneTickUp() public {
        _listAt(500);
        _limit(trader1, false, 501, 1000e18);
        assertEq(book.askHead(), 501, "setup: the ask rests one tick above the last price");

        uint256 baseBefore = token1.balanceOf(trader2);
        _market(trader2, true, 1e15);
        assertGt(token1.balanceOf(trader2), baseBefore, "the market buy must fill against 501");
        assertEq(book.lmp(), 501, "and the trade prints at 501");
    }

    /// Mirror image, which already worked because the sell rail floors: pinned so it stays so.
    function test_marketSell_atPrice500_takesTheBidOneTickDown() public {
        _listAt(500);
        _limit(trader1, true, 499, 1e15);
        assertEq(book.bidHead(), 499, "setup: the bid rests one tick below the last price");

        uint256 quoteBefore = token2.balanceOf(trader2);
        _market(trader2, false, 1e18);
        assertGt(token2.balanceOf(trader2), quoteBefore, "the market sell must fill against 499");
    }

    /// Two ticks up is still out of reach for a 0.1% buy: the rail admits ONE tick, no more.
    function test_marketBuy_atPrice500_doesNotReachTwoTicks() public {
        _listAt(500);
        _limit(trader1, false, 502, 1000e18);

        // 502 is beyond one tick of rail, so nothing matches, and with no pool behind the pair
        // the order reverts rather than refunding in silence (QuoteNotPrice.t.sol).
        vm.expectRevert(OrderPlacementLib.InsufficientLiquidity.selector);
        _market(trader2, true, 1e15);
        assertEq(book.askHead(), 502, "the ask at 502 is untouched");
    }
}
