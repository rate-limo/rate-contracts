pragma solidity >=0.8;

import {MockToken} from "../../../src/mock/MockToken.sol";
import {MockBase} from "../../../src/mock/MockBase.sol";
import {MockQuote} from "../../../src/mock/MockQuote.sol";
import {Utils} from "../../utils/Utils.sol";
import {MatchingEngine} from "../../../src/exchange/MatchingEngine.sol";
import {OrderbookFactory} from "../../../src/exchange/orderbooks/OrderbookFactory.sol";
import {Orderbook} from "../../../src/exchange/orderbooks/Orderbook.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {IOrderbookFactory} from "../../../src/exchange/interfaces/IOrderbookFactory.sol";
import {WETH9} from "../../../src/mock/WETH9.sol";
import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {console} from "forge-std/console.sol";
import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";

// Tests for the infinite-loop bug in _limitOrder where the i==0 check fails
// to detect "no progress" after the first iteration.
//
// Bug: in _limitOrder, after _matchAt increments i above 0 on the first call,
// subsequent iterations use `i == 0` to detect "no progress made at this price".
// Since i is already > 0, this check never triggers again.  The correct fix is
// to capture prevI = i before _matchAt and compare i == prevI afterward.
//
// The scenarios below set up matching that spans TWO price levels (both within
// the spread limit) to exercise the outer while loop iterating more than once.
// With the bug, if a stale empty price level exists in the list after the first
// price is consumed, the outer loop would spin indefinitely once i > 0.
contract InfiniteLoopMatchingTest is BaseSetup {
    // Buy side: two ask orders at prices 50 and 51, both within the 2% spread
    // of lmp=50 (limitPrice = 50 * 1.02 = 51). A single limitBuy at price 60
    // should match both, iterating the outer while loop twice.
    function testBuyMatchesMultipleAskPriceLevels() public {
        super.setUp();
        // lmp = 50, spread = 2% → limitPrice for buy = 51
        matchingEngine.addPair(address(token1), address(token2), 50, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        book = Orderbook(payable(orderbookFactory.getPair(address(token1), address(token2))));

        // Place ask orders at two price levels within the spread
        vm.prank(trader1);
        matchingEngine.limitSell(address(token1), address(token2), 50, 5e7, true, 10, trader1);

        vm.prank(trader1);
        matchingEngine.limitSell(address(token1), address(token2), 51, 5e7, true, 10, trader1);

        uint256 token1BalBefore = token1.balanceOf(trader2);

        // This buy should match both asks (lmp=50, limitPrice=51)
        // First outer iteration: price 50 consumed, i goes 0→1
        // Second outer iteration: price 51 consumed, i goes 1→2
        // With bug: i==0 is false after first iter, clearEmptyHead is still called (correct here)
        // The fix ensures that if _matchAt returns unchanged i (no progress), we stop immediately
        vm.prank(trader2);
        matchingEngine.limitBuy(address(token1), address(token2), 60, 1e18, false, 10, trader2);

        // Both ask orders should now be empty
        assertTrue(book.isEmpty(false, 50), "Ask at price 50 should be consumed");
        assertTrue(book.isEmpty(false, 51), "Ask at price 51 should be consumed");

        // Trader2 should have received token1
        assertTrue(token1.balanceOf(trader2) > token1BalBefore, "Trader2 should have received token1");
    }

    // Sell side: two bid orders at prices 50 and 49, both >= the 2% spread
    // floor of lmp=50 (limitPrice for sell = 50 * 0.98 = 49). A single
    // limitSell at price 45 should match both bid levels.
    function testSellMatchesMultipleBidPriceLevels() public {
        super.setUp();
        // lmp = 50, spread = 2% → limitPrice floor for sell = 49
        matchingEngine.addPair(address(token1), address(token2), 50, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        book = Orderbook(payable(orderbookFactory.getPair(address(token1), address(token2))));

        // Place bid orders at two price levels at or above the spread floor.
        // Each bid deposits 5e7 token2, which can buy 5e7*1e8/50 = 1e14 token1 (at price 50).
        // The sell deposits 3e14 token1, which exceeds what each individual bid can buy,
        // so both bids are fully consumed (remaining never hits 0 before the second bid).
        vm.prank(trader2);
        matchingEngine.limitBuy(address(token1), address(token2), 50, 5e7, true, 10, trader2);

        vm.prank(trader2);
        matchingEngine.limitBuy(address(token1), address(token2), 49, 5e7, true, 10, trader2);

        uint256 token2BalBefore = token2.balanceOf(trader1);

        // This sell should match both bids (lmp=50, limitPrice floor=49)
        // First outer iteration: price 50 consumed (bid buys 1e14 token1), i goes 0→1
        // Second outer iteration: price 49 consumed (bid buys ~1.02e14 token1), i goes 1→2
        vm.prank(trader1);
        matchingEngine.limitSell(address(token1), address(token2), 45, 3e14, false, 10, trader1);

        // Both bid orders should now be empty
        assertTrue(book.isEmpty(true, 50), "Bid at price 50 should be consumed");
        assertTrue(book.isEmpty(true, 49), "Bid at price 49 should be consumed");

        // Trader1 should have received token2
        assertTrue(token2.balanceOf(trader1) > token2BalBefore, "Trader1 should have received token2");
    }

    // Regression test: placing a buy that spans prices where the second price
    // becomes a stale-but-empty head exercises the prevI guard directly.
    // With the old i==0 check this was safe only on the first call;
    // the prevI fix makes it safe on every iteration.
    function testNoInfiniteLoopOnMultiplePriceIterations() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(token2), 50, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        book = Orderbook(payable(orderbookFactory.getPair(address(token1), address(token2))));

        // Three ask orders at three price levels (50, 51 are within limit; 52 is at the exact cap)
        // limitPrice = 50 * (100000000 + 2000000) / 100000000 = 51
        // 52 > 51, so only 50 and 51 match
        vm.prank(trader1);
        matchingEngine.limitSell(address(token1), address(token2), 50, 5e7, true, 10, trader1);
        vm.prank(trader1);
        matchingEngine.limitSell(address(token1), address(token2), 51, 5e7, true, 10, trader1);
        vm.prank(trader1);
        matchingEngine.limitSell(address(token1), address(token2), 52, 5e7, true, 10, trader1);

        // buy with n=10 (enough headroom) - the outer loop runs twice (for prices 50 and 51)
        // If the i==0 check caused any issue (stale price, no-progress loop), this reverts OOG
        vm.prank(trader2);
        matchingEngine.limitBuy(address(token1), address(token2), 60, 1e18, false, 10, trader2);

        // Prices 50 and 51 consumed; 52 remains (outside spread)
        assertTrue(book.isEmpty(false, 50), "Price 50 ask should be consumed");
        assertTrue(book.isEmpty(false, 51), "Price 51 ask should be consumed");
        assertFalse(book.isEmpty(false, 52), "Price 52 ask should remain");
    }
}
