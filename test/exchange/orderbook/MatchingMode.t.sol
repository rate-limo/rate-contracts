pragma solidity >=0.8;

import {MatchingEngine} from "../../../src/exchange/MatchingEngine.sol";
import {Orderbook} from "../../../src/exchange/orderbooks/Orderbook.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {BaseSetup} from "../OrderbookBaseSetup.sol";

// PriceTimePriority (strict FIFO) is the only matching mode. SizePriority — largest
// resting order at a price fills first — was removed on 2026-08-06 because keeping the
// level sorted by size over a linear list made insert and delete O(depth); see
// ExchangeOrderbook._insertId and UnboundedOrderQueue.regression.t.sol.
contract MatchingModeTest is BaseSetup {
    function testPriceTimePriorityEarliestOrderFillsFirstRegardlessOfSize() public {
        super.setUp();
        matchingEngine.addPair(
            address(token1),
            address(token2),
            1e8,
            0,
            address(token1),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        book = Orderbook(payable(orderbookFactory.getPair(address(token1), address(token2))));

        vm.prank(trader1);
        matchingEngine.limitSell(address(token1), address(token2), 1e8, 10, true, 1, trader1);
        vm.prank(trader1);
        matchingEngine.limitSell(address(token1), address(token2), 1e8, 50, true, 1, trader1);

        uint32[] memory ids = book.getOrderIds(false, 1e8, 2);
        ExchangeOrderbook.Order memory head = book.getOrder(false, ids[0]);
        assertEq(head.depositAmount, 10, "earliest resting order should stay head under PriceTimePriority");
    }

    function testPriceTimePriorityCancelHeadMiddleTailMaintainsFifoOrder() public {
        super.setUp();
        matchingEngine.addPair(
            address(token1),
            address(token2),
            1e8,
            0,
            address(token1),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        book = Orderbook(payable(orderbookFactory.getPair(address(token1), address(token2))));

        vm.startPrank(trader1);
        MatchingEngine.OrderResult memory a =
            matchingEngine.limitSell(address(token1), address(token2), 1e8, 10, true, 1, trader1);
        MatchingEngine.OrderResult memory b =
            matchingEngine.limitSell(address(token1), address(token2), 1e8, 20, true, 1, trader1);
        MatchingEngine.OrderResult memory c =
            matchingEngine.limitSell(address(token1), address(token2), 1e8, 30, true, 1, trader1);
        vm.stopPrank();

        // cancel the middle order: a -> c must remain linked
        vm.prank(trader1);
        matchingEngine.cancelOrder(address(token1), address(token2), false, b.id);
        uint32[] memory afterMiddleCancel = book.getOrderIds(false, 1e8, 2);
        assertEq(afterMiddleCancel[0], a.id, "head unchanged after cancelling middle order");
        assertEq(afterMiddleCancel[1], c.id, "tail unchanged after cancelling middle order");

        // cancel the tail order, then append a new order: it must follow the new tail (a)
        vm.prank(trader1);
        matchingEngine.cancelOrder(address(token1), address(token2), false, c.id);
        vm.prank(trader1);
        MatchingEngine.OrderResult memory d =
            matchingEngine.limitSell(address(token1), address(token2), 1e8, 40, true, 1, trader1);
        uint32[] memory afterTailCancelAndAppend = book.getOrderIds(false, 1e8, 2);
        assertEq(afterTailCancelAndAppend[0], a.id, "head still the original first order");
        assertEq(afterTailCancelAndAppend[1], d.id, "newly appended order follows the surviving tail");

        // cancel the head order, then append a new order: it must follow the new head (d)
        vm.prank(trader1);
        matchingEngine.cancelOrder(address(token1), address(token2), false, a.id);
        vm.prank(trader1);
        MatchingEngine.OrderResult memory e =
            matchingEngine.limitSell(address(token1), address(token2), 1e8, 50, true, 1, trader1);
        uint32[] memory afterHeadCancel = book.getOrderIds(false, 1e8, 2);
        assertEq(afterHeadCancel[0], d.id, "surviving order becomes new head");
        assertEq(afterHeadCancel[1], e.id, "newly appended order follows the new head");
    }
}
