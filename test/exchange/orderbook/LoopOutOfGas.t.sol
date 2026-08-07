pragma solidity >=0.8;

import {MockToken} from "../../../src/mock/MockToken.sol";
import {MockBase} from "../../../src/mock/MockBase.sol";
import {MockQuote} from "../../../src/mock/MockQuote.sol";
import {MockBTC} from "../../../src/mock/MockBTC.sol";
import {ErrToken} from "../../../src/mock/MockTokenOver18Decimals.sol";
import {Utils} from "../../utils/Utils.sol";
import {MatchingEngine} from "../../../src/exchange/MatchingEngine.sol";
import {OrderbookFactory} from "../../../src/exchange/orderbooks/OrderbookFactory.sol";
import {Orderbook} from "../../../src/exchange/orderbooks/Orderbook.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {IOrderbookFactory} from "../../../src/exchange/interfaces/IOrderbookFactory.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";
import {WETH9} from "../../../src/mock/WETH9.sol";
import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {console} from "forge-std/console.sol";
import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";

contract LoopOutOfGasTest is BaseSetup {
    // Fixed: _insert bid traversal previously used (price < last) instead of (price < next),
    // causing infinite loops when inserting a price that required deeper traversal.
    // With lmp=2 and spread=2%, the cap up=2*1.02=2 collapses all bids >= 2 to price=2;
    // only the bid at price=1 (below cap) creates a second distinct price level.
    function testExchangeLinkedListOutOfGas() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(token2), 2, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);

        vm.prank(booker);
        book = Orderbook(payable(orderbookFactory.getPair(address(token1), address(token2))));

        vm.prank(trader1);
        matchingEngine.limitBuy(address(token1), address(token2), 2, 10, true, 2, trader1);
        vm.prank(trader1);
        matchingEngine.limitBuy(address(token1), address(token2), 5, 10, true, 2, trader1);
        vm.prank(trader1);
        matchingEngine.limitBuy(address(token1), address(token2), 5, 10, true, 2, trader1);
        vm.prank(trader1);
        // Previously infinite-looped on _insert; now completes correctly.
        matchingEngine.limitBuy(address(token1), address(token2), 1, 10, true, 2, trader1);

        uint256[] memory prices = book.getPrices(true, 10);
        // With lmp=2: bids at 5 are spread-capped to 2 (same price), bid at 1 is below cap.
        assertEq(prices[0], 2, "bid head should be 2 (spread cap collapses 5->2)");
        assertEq(prices[1], 1, "second bid should be 1");
        assertEq(prices[2], 0, "no third bid price");
    }

    // Fixed: _insert ask traversal previously used (while price > last && last != 0),
    // causing infinite loops when inserting a price above two existing nodes.
    function testExchangeLinkedListOutOfGasPlaceBid() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(token2), 2, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        vm.prank(booker);
        book = Orderbook(payable(orderbookFactory.getPair(address(token1), address(token2))));

        vm.prank(trader1);
        matchingEngine.limitSell(address(token1), address(token2), 2, 5e7, true, 2, trader1);
        vm.prank(trader1);
        matchingEngine.limitSell(address(token1), address(token2), 5, 2e7, true, 2, trader1);
        vm.prank(trader1);
        matchingEngine.limitSell(address(token1), address(token2), 5, 2e7, true, 2, trader1);
        vm.prank(trader1);
        // Previously infinite-looped on _insert; now completes and price 6 is appended above 5.
        matchingEngine.limitSell(address(token1), address(token2), 6, 2e7, true, 2, trader1);

        uint256[] memory prices = book.getPrices(false, 10);
        // Ask list is ascending: 2 -> 5 -> 6
        assertEq(prices[0], 2, "ask head should be 2");
        assertEq(prices[1], 5, "second ask should be 5");
        assertEq(prices[2], 6, "third ask should be 6");
    }

    // Fixed: _insertId traversal previously used (amount > orders[head].depositAmount)
    // as the loop condition, causing infinite loops on equal-amount orders.
    // With lmp=5 and spread=2%, asks below floor=(5*0.98)=4 are raised to 4.
    function testExchangeOrderbookOutOfGas() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(token2), 5, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        vm.prank(booker);
        book = Orderbook(payable(orderbookFactory.getPair(address(token1), address(token2))));

        vm.prank(trader1);
        matchingEngine.limitSell(address(token1), address(token2), 5, 2e7, true, 2, trader1);
        vm.prank(trader1);
        // Previously infinite-looped on _insertId; now completes correctly.
        // Price 1 is below the spread floor (5*0.98=4), so it is raised to 4.
        matchingEngine.limitSell(address(token1), address(token2), 1, 1e8, true, 2, trader1);

        uint256[] memory prices = book.getPrices(false, 10);
        assertEq(prices[0], 4, "ask head should be 4 (spread floor raises 1->4)");
        assertEq(prices[1], 5, "second ask should be 5");
    }

    // Fixed: _delete bid traversal had while condition (price > head) which is ALWAYS false
    // for valid bid prices (price <= bidHead), so non-head prices were never removed.
    // Test: place bids at 10 > 9 > 8, cancel mid-price 9, verify it is gone from the list.
    function testDeleteRemovesNonHeadBidPrice() public {
        super.setUp();
        // listingPrice=10: spread cap = 10 * 1.02 = 10; bids at 10, 9, 8 all stay distinct.
        matchingEngine.addPair(address(token1), address(token2), 10, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        vm.prank(booker);
        book = Orderbook(payable(orderbookFactory.getPair(address(token1), address(token2))));

        vm.prank(trader1);
        matchingEngine.limitBuy(address(token1), address(token2), 10, 10, true, 2, trader1);
        vm.prank(trader1);
        IMatchingEngine.OrderResult memory midOrder =
            matchingEngine.limitBuy(address(token1), address(token2), 9, 10, true, 2, trader1);
        vm.prank(trader1);
        matchingEngine.limitBuy(address(token1), address(token2), 8, 10, true, 2, trader1);

        uint256[] memory before = book.getPrices(true, 5);
        assertEq(before[0], 10, "bid head before cancel");
        assertEq(before[1], 9,  "mid bid before cancel");
        assertEq(before[2], 8,  "tail bid before cancel");

        // Cancel the non-head bid at price=9.
        // Old code: _delete(true, 9) with bidHead=10 — while (9 > 10) never fires -> zombie!
        // New code: traverses from 10 -> finds 9 -> removes it, list becomes 10 -> 8.
        vm.prank(trader1);
        matchingEngine.cancelOrder(address(token1), address(token2), true, midOrder.id);

        uint256[] memory after_ = book.getPrices(true, 5);
        assertEq(after_[0], 10, "bid head after cancel should still be 10");
        assertEq(after_[1], 8,  "next bid should be 8 (9 removed)");
        assertEq(after_[2], 0,  "no third bid price should remain");
    }

    // Fixed: _delete ask traversal had while condition (price < head) which is ALWAYS false
    // for valid ask prices (price >= askHead), so non-head prices were never removed.
    // Test: place asks at 2 < 5 < 10, cancel mid-price 5, verify it is gone from the list.
    function testDeleteRemovesNonHeadAskPrice() public {
        super.setUp();
        // listingPrice=2: spread floor = 2 * 0.98 = 1; asks at 2, 5, 10 all stay distinct.
        matchingEngine.addPair(address(token1), address(token2), 2, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        vm.prank(booker);
        book = Orderbook(payable(orderbookFactory.getPair(address(token1), address(token2))));

        vm.prank(trader1);
        matchingEngine.limitSell(address(token1), address(token2), 2, 5e7, true, 2, trader1);
        vm.prank(trader1);
        IMatchingEngine.OrderResult memory midOrder =
            matchingEngine.limitSell(address(token1), address(token2), 5, 5e7, true, 2, trader1);
        vm.prank(trader1);
        matchingEngine.limitSell(address(token1), address(token2), 10, 5e7, true, 2, trader1);

        uint256[] memory before = book.getPrices(false, 5);
        assertEq(before[0], 2,  "ask head before cancel");
        assertEq(before[1], 5,  "mid ask before cancel");
        assertEq(before[2], 10, "tail ask before cancel");

        // Cancel the non-head ask at price=5.
        // Old code: _delete(false, 5) with askHead=2 — while (5 < 2) never fires -> zombie!
        // New code: traverses from 2 -> finds 5 -> removes it, list becomes 2 -> 10.
        vm.prank(trader1);
        matchingEngine.cancelOrder(address(token1), address(token2), false, midOrder.id);

        uint256[] memory after_ = book.getPrices(false, 5);
        assertEq(after_[0], 2,  "ask head after cancel should still be 2");
        assertEq(after_[1], 10, "next ask should be 10 (5 removed)");
        assertEq(after_[2], 0,  "no third ask price should remain");
    }
}
