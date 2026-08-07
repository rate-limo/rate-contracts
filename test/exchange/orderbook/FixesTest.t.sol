// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8;

import {MockToken} from "../../../src/mock/MockToken.sol";
import {MockBase} from "../../../src/mock/MockBase.sol";
import {MockQuote} from "../../../src/mock/MockQuote.sol";
import {MockBTC} from "../../../src/mock/MockBTC.sol";
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

contract FixesTest is BaseSetup {
    // ─── Fix 1: _deleteOrder uint16 i removal ────────────────────────────────
    //
    // Before: _deleteOrder had `uint16 i; ... ++i;` inside the non-head search loop.
    // In Solidity 0.8 checked arithmetic, ++i panics (reverts) when i overflows uint16
    // (i.e., after 65 535 traversals). An attacker can pack 65 536 orders at a single
    // price level to make any order at position >= 65 537 permanently uncancellable —
    // a targeted DoS with no recovery path.
    //
    // After: `uint16 i` declaration and `++i` removed entirely. The loop terminates
    // on `head == 0` or `break`, regardless of list length.
    //
    // This test exercises the non-head deletion path with a small list (5 orders,
    // cancel the 3rd). The fix prevents the panic that would occur at depth 65 536.
    function testDeleteOrderNonHeadNoUint16Overflow() public {
        super.setUp();
        // lmp=10; ask floor = 10 * 0.98 = 9.8 -> 9; price=10 is valid
        matchingEngine.addPair(address(token1), address(token2), 10, 0, address(feeToken), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        vm.prank(booker);
        book = Orderbook(payable(orderbookFactory.getPair(address(token1), address(token2))));

        // Place 5 asks at price=10 with strictly decreasing amounts so they insert
        // in descending-deposit order:  head -> 100e18 -> 80e18 -> 60e18 -> 40e18 -> 20e18 -> null
        vm.prank(trader1);
        matchingEngine.limitSell(address(token1), address(token2), 10, 100e18, true, 2, trader1);
        vm.prank(trader1);
        matchingEngine.limitSell(address(token1), address(token2), 10, 80e18, true, 2, trader1);
        vm.prank(trader1);
        IMatchingEngine.OrderResult memory thirdOrder =
            matchingEngine.limitSell(address(token1), address(token2), 10, 60e18, true, 2, trader1);
        vm.prank(trader1);
        matchingEngine.limitSell(address(token1), address(token2), 10, 40e18, true, 2, trader1);
        vm.prank(trader1);
        matchingEngine.limitSell(address(token1), address(token2), 10, 20e18, true, 2, trader1);

        uint256 balanceBefore = token1.balanceOf(trader1);

        // Cancel the 3rd order (non-head, non-tail) — exercises the search loop.
        // With old code: ++i runs 2 times; with 65 536 orders it would panic.
        // With new code: loop terminates cleanly at any depth.
        vm.prank(trader1);
        matchingEngine.cancelOrder(address(token1), address(token2), false, thirdOrder.id);

        // Maker receives the full deposit back
        assertEq(token1.balanceOf(trader1), balanceBefore + 60e18, "60e18 token1 should be refunded");

        // Remaining 4 orders still live at price 10
        assertFalse(book.isEmpty(false, 10), "price 10 should still have 4 orders");

        // The cancelled order is no longer in the list
        uint32[] memory ids = book.getOrderIds(false, 10, 10);
        for (uint256 i = 0; i < ids.length; i++) {
            assertTrue(ids[i] != thirdOrder.id, "cancelled order id must not appear in the list");
        }
    }

    // ─── Fix 2 + 3: fpop dust-order refund and price-list cleanup ────────────
    //
    // Dust order: an order whose depositAmount converts to zero in the taker's
    // asset (required == 0).  This occurs with mismatched token decimals + a low
    // price where integer division truncates to 0.
    //
    // Setup:
    //   base = btc  (8 decimals),  quote = token1 (18 decimals)
    //   baseBquote = false  (8 < 18),  decDiff = 1e10
    //   convert(price=1, depositAmount=1, !isBid=true)
    //       = ((1 * 1) / 1e8) * 1e10  = 0 * 1e10 = 0  → DUST
    //
    // Fix 2 (funds): old fpop called _fpop (pops from queue) then returned (orderId, 0, true).
    // matchAt hit `required == 0` branch → ++i; continue  with NO execute call.
    // Result: order removed from queue, orders[id] intact, maker funds stranded forever.
    // New fpop: detects required==0, calls _deleteOrder (cleans storage) + _sendFunds.
    //
    // Fix 3 (orphan): old code for the dust path would have relied on _next, leaving
    // the price entry in the price linked-list mapping.  New code calls priceLists._delete
    // which removes the entry so getPrices no longer reports the stale price.
    //
    // We bypass MatchingEngine's deposit check (which would revert on converted==0) by
    // calling book.placeAsk directly as the engine via vm.prank, then funding the book
    // contract directly to simulate the token deposit that MatchingEngine would have done.
    function testFpopDustOrderRefundsMakerAndClearsPrice() public {
        super.setUp();
        // btc (8 dec) as base, token1 (18 dec) as quote, lmp=1
        matchingEngine.addPair(address(btc), address(token1), 1, 0, address(feeToken), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        vm.prank(booker);
        book = Orderbook(payable(orderbookFactory.getPair(address(btc), address(token1))));

        // Confirm the decimal arithmetic: 1 satoshi at price=1 requires 0 token1 from taker
        assertEq(book.convert(1, 1, true), 0, "sanity: 1 satoshi at price=1 is dust (required=0)");

        uint256 dustDeposit = 1; // 1 satoshi of btc

        // Simulate the maker's deposit: transfer 1 satoshi to the book so _sendFunds can refund.
        uint256 makerBalanceBefore = btc.balanceOf(trader1);
        vm.prank(trader1);
        btc.transfer(address(book), dustDeposit);

        // Place the dust ask directly as the engine, bypassing MatchingEngine's converted>0 check.
        vm.prank(address(matchingEngine));
        book.placeAsk(trader1, 1, dustDeposit);

        // The ask appears in the book at price=1
        assertFalse(book.isEmpty(false, 1), "dust ask should be queued at price 1");
        uint256[] memory pricesBefore = book.getPrices(false, 5);
        assertEq(pricesBefore[0], 1, "price 1 should appear in ask price list");

        // Trigger fpop from the engine — remaining is large (taker has more than enough)
        vm.prank(address(matchingEngine));
        (uint32 retId, uint256 retRequired, bool retClear, , ) = book.fpop(false, 1, type(uint256).max);

        // Fix 2 originally flattened the id to 0 to keep `execute` from being called on
        // a deleted order. That property now comes from `required == 0` instead —
        // MatchingLib.matchAt (the ONLY caller of fpop) gates `execute` on `required`,
        // never on the id — so the real id is returned, which is what lets the removal
        // be attributed in the OrderDusted event. Silently deleting a refunded order
        // with nothing naming it is what left orders open forever in every indexer.
        // See docs/contract/order-clear-observability.md.
        assertTrue(retId != 0, "dust fpop must name the order it deleted, for the event");
        assertEq(retRequired, 0, "required==0 is what keeps execute from being called");
        assertEq(retRequired, 0, "dust fpop must return required=0");
        assertTrue(retClear, "dust fpop must return clear=true");

        // Fix 2: maker's deposit is refunded — net balance change is zero
        assertEq(
            btc.balanceOf(trader1),
            makerBalanceBefore,
            "maker must recover the full dust deposit"
        );

        // Fix 3: price is properly deleted from the ask linked list (no orphan node)
        assertTrue(book.isEmpty(false, 1), "ask queue at price 1 must be empty after dust refund");
        uint256[] memory pricesAfter = book.getPrices(false, 5);
        assertEq(pricesAfter[0], 0, "price 1 must be removed from ask price list (no orphan)");
    }
}
