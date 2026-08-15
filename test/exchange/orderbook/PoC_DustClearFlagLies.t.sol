pragma solidity >=0.8;

import {MockToken} from "../../../src/mock/MockToken.sol";
import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {IOrderbook} from "../../../src/exchange/interfaces/IOrderbook.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

/**
 * `clear` is the ONLY signal the off-chain stack has for "this order is gone".
 * The broker deletes its row on it; every UI derives open-order state from that.
 *
 * These began as PoCs for two ways the flag disagreed with the book, and now pin
 * the fix: they FAIL against the pre-fix contracts.
 *
 * Companion to DecimalsDustBonus.t.sol, which covers the *economics* of the same
 * dust closeout (the taker receiving the maker's full remaining deposit). This
 * one is about OBSERVABILITY: whatever one thinks of the value transfer, an
 * indexer must still be able to learn that the order stopped existing.
 */
contract PoCDustClearFlagLiesTest is BaseSetup {
    // MatchingLib.OrderMatched — all fields non-indexed, OrderMatch is a static struct.
    bytes32 constant ORDER_MATCHED_TOPIC =
        keccak256(
            "OrderMatched(address,uint16,uint256,bool,uint256,uint256,bool,(address,address,uint256,uint256,uint256,uint256,uint64))"
        );

    bytes32 constant ORDER_DUSTED_TOPIC =
        keccak256("OrderDusted(address,uint16,uint256,bool,uint256,address,uint256)");

    function _lastClearFlag(Vm.Log[] memory logs) internal pure returns (bool found, bool clear) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == ORDER_MATCHED_TOPIC) {
                (, , , , , , bool c, ) = abi.decode(
                    logs[i].data,
                    (address, uint16, uint256, bool, uint256, uint256, bool, IMatchingEngine.OrderMatch)
                );
                found = true;
                clear = c;
            }
        }
    }

    /**
     * FIXED (was FINDING A) — the scenario no longer exists.
     *
     * The finding was that a partial fill leaving <= dust deleted the order while
     * the event said `clear: false`. The first fix made the event tell the truth.
     * Removing the dust threshold went further and made the deletion itself stop
     * happening: a partial fill is now a partial fill, and the order rests with a
     * reduced deposit. `clear: false` is now simply correct.
     *
     * `ExchangeOrderbook._decreaseOrder` deletes on `decreased <= dust || clear`,
     * so the dust condition alone removes the order. `clear` reaching the event
     * comes from `Orderbook.fpop`, which only sets it when `required <= remaining`
     * — a different question. The two disagree exactly on the dust boundary.
     *
     * `execute` still returns whether `_decreaseOrder` removed the order and
     * MatchingLib still emits THAT rather than fpop's `clear` -- the two agree now,
     * but they answer different questions and a caller reporting its own request
     * instead of the outcome is what left indexers showing deleted orders as open.
     */
    function testPartialFillLeavesTheOrderRestingAndSaysSo() public {
        super.setUp();

        MockToken zeroDecBase = new MockToken("ZeroDec", "ZD", 0);
        MockToken sixDecQuote = new MockToken("SixDec", "SIX", 6);

        matchingEngine.setDefaultFee(true, 0);
        matchingEngine.setDefaultFee(false, 0);

        uint256 price = 500 * 1e8;
        matchingEngine.addPair(
            address(zeroDecBase),
            address(sixDecQuote),
            price,
            0,
            address(zeroDecBase),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        address pair = matchingEngine.getPair(address(zeroDecBase), address(sixDecQuote));

        // Same boundary construction as DecimalsDustBonus: rest a bid worth a fair
        // 2-unit fill plus exactly one `dust`, so the leftover lands on the boundary.
        uint256 fairValue = 1000 * 1e6;
        uint256 dust = 500 * 1e6;
        uint256 makerDeposit = fairValue + dust;
        sixDecQuote.mint(trader1, makerDeposit);
        vm.prank(trader1);
        sixDecQuote.approve(address(matchingEngine), makerDeposit);
        vm.prank(trader1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(zeroDecBase),
                quote: address(sixDecQuote),
                price: price,
                amount: makerDeposit,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );

        assertFalse(IOrderbook(pair).isEmpty(true, price), "maker order should be resting before the fill");

        // A fill SMALLER than the resting order: a partial fill by any reading.
        uint256 fillAmount = 2;
        zeroDecBase.mint(attacker, fillAmount);
        vm.prank(attacker);
        zeroDecBase.approve(address(matchingEngine), fillAmount);

        vm.recordLogs();
        vm.prank(attacker);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(zeroDecBase),
                quote: address(sixDecQuote),
                price: price,
                amount: fillAmount,
                isMaker: true,
                n: 5,
                recipient: attacker
            })
        );
        (bool found, bool clearFlag) = _lastClearFlag(vm.getRecordedLogs());

        bool bookEmpty = IOrderbook(pair).isEmpty(true, price);

        console.log("OrderMatched emitted:      ", found);
        console.log("event said clear:          ", clearFlag);
        console.log("order actually gone:       ", bookEmpty);

        assertTrue(found, "an OrderMatched should have been emitted");
        // No threshold, so a partial fill leaves the order where it was.
        assertFalse(bookEmpty, "a partial fill must leave the order resting");
        assertFalse(clearFlag, "and the event must say it was not cleared");
        // And the sharper point: this remainder is not dust at all. 500 SIX converts
        // to a whole base unit, so it is a perfectly fillable order -- the old
        // threshold was sweeping away REAL liquidity and handing it to whoever
        // happened to trade against it, not cleaning up unfillable scraps.
        assertEq(
            IOrderbook(pair).convert(price, 500 * 1e6, false), 1,
            "the swept remainder was fillable liquidity, not dust"
        );
    }

    /**
     * FIXED (was FINDING B) — an order whose remaining deposit converts to zero is
     * deleted and refunded, and that removal is now announced.
     *
     * `Orderbook.fpop` handles `required == 0` by deleting the order and calling
     * `_sendFunds` to return the deposit, then returns `(0, 0, true)`.
     * `MatchingLib.matchAt` sees `required == 0`, takes `++i; continue;` — and so
     * emits nothing. `Orderbook.sol` declares no events at all.
     *
     * `fpop` now returns the owner and refunded amount, and MatchingLib emits
     * `OrderDusted`. Before the fix the maker's funds moved and their order
     * vanished with nothing on chain to observe, orphaning the row permanently.
     *
     * Deliberately NOT reported as OrderCanceled: the maker did not ask for this,
     * and labelling an eviction a cancellation misreports their own history.
     */
    function testDustOrderIsRefundedAndDeletedWithNoEventAtAll() public {
        super.setUp();

        // ETH/USDC-shaped: base 18dec, quote 6dec, ~$3000. Here `dust` in
        // _decreaseOrder floors to ZERO (see DecimalsDustBonus's second case), so a
        // leftover is NOT cleaned up on the way out -- it survives on the book and is
        // evaluated by `fpop` on the next sweep, which is where `required == 0` lives.
        MockToken base18 = new MockToken("Eighteen", "E18", 18);
        MockToken quote6 = new MockToken("SixDec", "SIX", 6);

        matchingEngine.setDefaultFee(true, 0);
        matchingEngine.setDefaultFee(false, 0);

        uint256 price = 3000 * 1e8;
        matchingEngine.addPair(
            address(base18), address(quote6), price, 0, address(base18),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        address pair = matchingEngine.getPair(address(base18), address(quote6));
        assertEq(IOrderbook(pair).convert(price, 1, true), 0, "precondition: dust floors to zero on this pair");

        // Maker rests 20,000 raw quote units.
        uint256 makerDeposit = 20000;
        quote6.mint(trader1, makerDeposit);
        vm.prank(trader1);
        quote6.approve(address(matchingEngine), makerDeposit);
        vm.prank(trader1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base18),
                quote: address(quote6),
                price: price,
                amount: makerDeposit,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );

        // The whole 20,000 deposit requires 6e12 base to clear (convert quote->base).
        // Deliver strictly LESS than that, so this is a partial fill and `clear` is
        // false: 5.8e12 base converts to 17,400 quote, leaving a 2,600 remainder.
        // Under 3,000 that remainder converts to zero base -- the `required == 0`
        // condition -- and dust being zero means nothing cleans it up on the way past.
        assertEq(IOrderbook(pair).convert(price, makerDeposit, false), 6e12, "precondition: full clear needs 6e12");
        uint256 firstFill = 5.8e12; // -> converted 17,400 quote, leaving 2,600
        base18.mint(trader2, firstFill);
        vm.prank(trader2);
        base18.approve(address(matchingEngine), firstFill);
        vm.prank(trader2);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(base18),
                quote: address(quote6),
                price: price,
                amount: firstFill,
                isMaker: true,
                n: 5,
                recipient: trader2
            })
        );

        assertFalse(IOrderbook(pair).isEmpty(true, price), "remainder should still be resting");
        assertEq(
            IOrderbook(pair).convert(price, 2600, false), 0,
            "precondition: the 2,600 remainder converts to zero base units"
        );

        uint256 makerQuoteBefore = quote6.balanceOf(trader1);

        // Second taker sweeps the level. fpop takes the `required == 0` branch:
        // deletes the order, refunds the maker, returns (0, 0, true) -- and matchAt's
        // `else if (required == 0) { ++i; continue; }` emits nothing.
        uint256 secondFill = 1e15;
        base18.mint(attacker, secondFill);
        vm.prank(attacker);
        base18.approve(address(matchingEngine), secondFill);

        vm.recordLogs();
        vm.prank(attacker);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(base18),
                quote: address(quote6),
                price: price,
                amount: secondFill,
                isMaker: true,
                n: 5,
                recipient: attacker
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 refunded = quote6.balanceOf(trader1) - makerQuoteBefore;
        bool bookEmpty = IOrderbook(pair).isEmpty(true, price);

        // The eviction must be announced, with enough to identify the order and the
        // refund. This assertion fails pre-fix, where nothing was emitted at all.
        bool dusted;
        address dustedOwner;
        uint256 dustedRefund;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == ORDER_DUSTED_TOPIC) {
                (, , , , , address owner_, uint256 refund_) = abi.decode(
                    logs[i].data,
                    (address, uint16, uint256, bool, uint256, address, uint256)
                );
                dusted = true;
                dustedOwner = owner_;
                dustedRefund = refund_;
            }
        }

        console.log("maker refunded (raw quote):", refunded);
        console.log("order gone from book:      ", bookEmpty);
        console.log("OrderDusted emitted:       ", dusted);

        assertTrue(bookEmpty, "the dust order was removed from the book");
        assertEq(refunded, 2600, "maker was refunded the full remaining deposit");
        assertTrue(dusted, "the eviction must emit OrderDusted");
        assertEq(dustedOwner, trader1, "OrderDusted must name the maker who was refunded");
        assertEq(dustedRefund, refunded, "OrderDusted must report the amount actually refunded");
    }
}
