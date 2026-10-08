pragma solidity >=0.8;

import {BandBaseSetup} from "./BandBaseSetup.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {Orderbook} from "../../src/exchange/orderbooks/Orderbook.sol";
import {OrderPlacementLib} from "../../src/exchange/libraries/OrderPlacementLib.sol";
import {IMatchingEngine} from "../../src/exchange/interfaces/IMatchingEngine.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockBase} from "../../src/mock/MockBase.sol";
import {MockQuote} from "../../src/mock/MockQuote.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";

/**
 * A TAKER's unmatched remainder reaches the pair's pool before it goes home.
 *
 * An order now walks three venues in order — the resting book, any stop orders it
 * woke, then the pool — and only what survives all three is refunded. This pins the
 * third leg, and the four conditions under which it must NOT happen.
 */
contract PoolFallbackTest is BandBaseSetup {
    bytes32 constant ROUTED_TOPIC =
        keccak256("RemainderRoutedToPool(address,address,uint256,uint256)");

    function _routed(Vm.Log[] memory logs) internal pure returns (bool) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == ROUTED_TOPIC) return true;
        }
        return false;
    }

    /// A market buy for `quoteIn`, as a taker — the branch that would otherwise refund.
    function _takerBuy(address who, uint256 quoteIn) internal returns (bool ok) {
        vm.startPrank(who);
        token2.approve(address(matchingEngine), type(uint256).max);
        bytes memory call_ = abi.encodeCall(
            IMatchingEngine.marketBuy,
            (
                IMatchingEngine.MarketOrderInput({
                    base: address(token1),
                    quote: address(token2),
                    amount: quoteIn,
                    isMaker: false,
                    n: 2,
                    recipient: who,
                    slippageLimit: 1_000_000_000
                })
            )
        );
        (ok,) = address(matchingEngine).call(call_);
        vm.stopPrank();
    }

    /**
     * The pool is reached, and the taker ends up with base the book could not give them.
     *
     * Nothing rests on the book here — this is a taker order, so before this change the
     * whole unmatched amount came straight back.
     */
    function test_takerRemainder_reachesThePool() public {
        _seedBands(1000e18);
        assertTrue(Orderbook(payable(address(book))).getPool() != address(0), "pair has a pool");

        uint256 baseBefore = token1.balanceOf(trader2);
        uint256 poolQuoteBefore = token2.balanceOf(address(pool));

        vm.recordLogs();
        assertTrue(_takerBuy(trader2, 100e18), "the order must succeed");

        assertTrue(_routed(vm.getRecordedLogs()), "the remainder should have reached the pool");
        assertGt(token1.balanceOf(trader2), baseBefore, "the taker received base");
        assertGt(token2.balanceOf(address(pool)), poolQuoteBefore, "the pool took the quote");
    }

    /**
     * A pair with NO pool is untouched — the remainder is refunded exactly as before.
     *
     * `addPair` only creates a pool when the factory is set and neither leg is a wrapped
     * native, so this is not a hypothetical: on a chain where WETH is a real wrapper the
     * busiest pairs have none.
     */
    function test_pairWithoutAPool_refundsExactlyAsBefore() public {
        // A pair created while the factory is unset genuinely has no pool -- the same
        // shape `addPair` produces for a WETH pair on a wrapper chain. Detaching the
        // existing one is not possible: `setPool` is one-time (`PoolAlreadySet`).
        MockBase b2 = new MockBase("Base2", "BASE2");
        MockQuote q2 = new MockQuote("Quote2", "QUOTE2");
        b2.mint(trader1, 1_000_000e18);
        q2.mint(trader2, 1_000_000e18);

        matchingEngine.setPoolFactory(address(0));
        matchingEngine.addPair(
            address(b2), address(q2), 100000000, 0, address(b2),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        address pair2 = matchingEngine.getPair(address(b2), address(q2));
        assertEq(Orderbook(payable(pair2)).getPool(), address(0), "this pair has no pool");

        // A small resting ask, so the taker gets a partial fill and a real remainder.
        vm.startPrank(trader1);
        b2.approve(address(matchingEngine), type(uint256).max);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(b2), quote: address(q2), price: 100000000,
                amount: 1e18, isMaker: true, n: 2, recipient: trader1
            })
        );
        vm.stopPrank();

        uint256 quoteBefore = q2.balanceOf(trader2);

        vm.recordLogs();
        vm.startPrank(trader2);
        q2.approve(address(matchingEngine), type(uint256).max);
        matchingEngine.marketBuy(
            IMatchingEngine.MarketOrderInput({
                base: address(b2), quote: address(q2), amount: 100e18,
                isMaker: false, n: 2, recipient: trader2, slippageLimit: 1_000_000_000
            })
        );
        vm.stopPrank();

        assertFalse(_routed(vm.getRecordedLogs()), "nothing should have been routed");
        assertGt(b2.balanceOf(trader2), 0, "the book part still filled");
        // Only the matched portion left the taker; the rest was refunded.
        assertLt(quoteBefore - q2.balanceOf(trader2), 100e18, "the remainder came back");
    }

    /**
     * A MAKER order still rests. Filling it at the pool instead would mean limit orders
     * never reach the book, which is the opposite of what the trader asked for.
     */
    function test_makerRemainder_restsAndNeverRoutes() public {
        _seedBands(1000e18);

        vm.startPrank(trader2);
        token2.approve(address(matchingEngine), type(uint256).max);
        vm.recordLogs();
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 50000000, // well below the market: rests, matches nothing
                amount: 100e18,
                isMaker: true,
                n: 2,
                recipient: trader2
            })
        );
        vm.stopPrank();

        assertFalse(_routed(vm.getRecordedLogs()), "a maker order must never route to the pool");
        (uint256 bidHead,) = matchingEngine.heads(address(token1), address(token2));
        assertGt(bidHead, 0, "it should be resting on the book");
    }

    /**
     * A pool that refuses is still caught -- its own error never escapes the `try` -- but
     * a MARKET order that the book matched nothing of and the pool took none of now
     * reverts `InsufficientLiquidity` instead of completing having spent nothing
     * (QuoteNotPrice.t.sol). It used to refund in silence, which is also what hid the
     * pool bound being unsatisfiable at ordinary prices. The trader's funds never move.
     */
    function test_aPoolThatRefuses_revertsInsteadOfRefunding() public {
        // No bands seeded at all, so the pool has nothing to fill with and reverts
        // `NoLiquidity` internally.
        uint256 quoteBefore = token2.balanceOf(trader2);

        vm.startPrank(trader2);
        token2.approve(address(matchingEngine), type(uint256).max);
        vm.expectRevert(OrderPlacementLib.InsufficientLiquidity.selector);
        matchingEngine.marketBuy(
            IMatchingEngine.MarketOrderInput({
                base: address(token1), quote: address(token2), amount: 100e18,
                isMaker: false, n: 2, recipient: trader2, slippageLimit: 1_000_000_000
            })
        );
        vm.stopPrank();

        assertEq(token2.balanceOf(trader2), quoteBefore, "nothing was spent");
    }

    /**
     * The pool can never fill worse than the order's own limit price.
     *
     * This is the property that makes routing safe to do without asking. `minAmountOut`
     * is `IOrderbook.convert(limitPrice, remaining, ...)` — the venue's own conversion at
     * the order's own price — so the taker gets their limit or better, or nothing.
     *
     * A buy priced far BELOW the market demands more base per unit of quote than the
     * pool can give, so the pool must refuse and the remainder must come home whole.
     * Without the bound it would happily fill a long way through the bands at a price
     * the trader never agreed to.
     */
    function test_theLimitPriceBoundsThePoolFill() public {
        _seedBands(1000e18);

        uint256 quoteBefore = token2.balanceOf(trader2);
        uint256 baseBefore = token1.balanceOf(trader2);

        vm.startPrank(trader2);
        token2.approve(address(matchingEngine), type(uint256).max);
        vm.recordLogs();
        // Priced far below the market and NOT a maker order: matches nothing on the
        // book, and the pool cannot satisfy the implied minimum either.
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1), quote: address(token2), price: 1000000,
                amount: 100e18, isMaker: false, n: 2, recipient: trader2
            })
        );
        vm.stopPrank();

        assertFalse(_routed(vm.getRecordedLogs()), "the pool must refuse a fill worse than the limit");
        assertEq(token2.balanceOf(trader2), quoteBefore, "the whole amount came back");
        assertEq(token1.balanceOf(trader2), baseBefore, "and no base was bought at a bad price");
    }

    /**
     * The pool leg reports its price, or the backend never learns the trade happened.
     *
     * `BandSwapRouter` is what normally calls `reportSwap`, and this path bypasses the
     * router. Without an explicit report the pool fill emits only `BandSwap` — which
     * the broker acknowledges and deliberately does NOT aggregate (`processBandSwap`
     * is a no-op) — so the tokens would change hands with no price print, no candle
     * and no `lmp` move.
     *
     * It goes through `MatchingLib.reportSwapPrice`, the same rail `reportSwap` uses,
     * so the cap that stops one trade teleporting `lmp` — and through the 300s TWAP,
     * the pool's own anchor — applies here too.
     */
    function test_thePoolLegReportsItsPrice() public {
        _seedBands(1000e18);

        vm.recordLogs();
        assertTrue(_takerBuy(trader2, 100e18), "the order must succeed");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(_routed(logs), "the remainder reached the pool");

        bytes32 priceTopic = keccak256("NewMarketPrice(address,uint256,bool)");
        bool printed;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == priceTopic) printed = true;
        }
        assertTrue(printed, "the pool fill must print a price the indexer can see");
    }

    /// The engine is admitted by the pool; an arbitrary caller still is not.
    function test_theGateAdmitsTheEngineAndNobodyElse() public {
        _seedBands(1000e18);
        vm.prank(trader1);
        vm.expectRevert();
        pool.swap(1e18, true, trader1, 0);
    }
}
