// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandBaseSetup} from "../swap/BandBaseSetup.sol";
import {IMatchingEngine} from "../../src/exchange/interfaces/IMatchingEngine.sol";
import {OrderPlacementLib} from "../../src/exchange/libraries/OrderPlacementLib.sol";

/**
 * A resting order is a QUOTE. Only a trade is a PRICE.
 *
 * Before this change an order that never traded still wrote `lmp` -- a limit sell
 * below the last price printed a new, lower price the moment it rested, and a
 * cancel refunded it. So the price could be walked anywhere, one resting order at
 * a time, for gas and with no counterparty: `testWalkDown` is that attack, and it
 * is the reason the change exists. The executable price never moved; only the
 * printed one did, which is worse for a launch than a real fall.
 *
 * What still moves the price: a book match (`MatchingLib`), a pool swap
 * (`reportSwapPrice`), and the listing price at `addPair`. All three are trades or
 * the start of trading.
 *
 * The second half is what makes removing the print safe: with the band pool open
 * there is a standing quote under every market, so a market order that matches
 * nothing on the book is no longer "no liquidity, come back later" -- it is either
 * filled by the pool or there is genuinely nothing there, and the second case now
 * says so instead of silently handing the deposit back.
 */
contract QuoteNotPriceTest is BandBaseSetup {
    /// A limit sell this far under the last price would, before the change, print.
    uint256 constant UNDER = 90e8;
    uint256 constant OVER = 110e8;

    function _limitSell(address who, uint256 price, uint256 amount) internal returns (uint32 id) {
        vm.startPrank(who);
        token1.approve(address(matchingEngine), type(uint256).max);
        IMatchingEngine.OrderResult memory r = matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: price,
                amount: amount,
                isMaker: true,
                n: 2,
                recipient: who
            })
        );
        vm.stopPrank();
        return r.id;
    }

    function _limitBuy(address who, uint256 price, uint256 amount) internal returns (uint32 id) {
        vm.startPrank(who);
        token2.approve(address(matchingEngine), type(uint256).max);
        IMatchingEngine.OrderResult memory r = matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: price,
                amount: amount,
                isMaker: true,
                n: 2,
                recipient: who
            })
        );
        vm.stopPrank();
        return r.id;
    }

    /// Approve OUTSIDE the order call, so `vm.expectRevert` can only catch the order.
    function _approveQuote(address who) internal {
        vm.prank(who);
        token2.approve(address(matchingEngine), type(uint256).max);
    }

    function _marketBuy(address who, uint256 quoteIn) internal returns (IMatchingEngine.OrderResult memory r) {
        _approveQuote(who);
        vm.startPrank(who);
        r = matchingEngine.marketBuy(
            IMatchingEngine.MarketOrderInput({
                base: address(token1),
                quote: address(token2),
                amount: quoteIn,
                isMaker: false,
                n: 2,
                recipient: who,
                slippageLimit: 0
            })
        );
        vm.stopPrank();
    }

    function _cancelAsk(address who, uint32 id) internal {
        IMatchingEngine.CancelOrderInput[] memory c = new IMatchingEngine.CancelOrderInput[](1);
        c[0] = IMatchingEngine.CancelOrderInput({
            base: address(token1),
            quote: address(token2),
            isBid: false,
            orderId: id
        });
        vm.prank(who);
        matchingEngine.cancelOrders(c);
    }

    // ---------------------------------------------------------------- the price

    /// A sell that nobody took is an offer, not a sale. It must not print.
    function test_restingLimitSell_doesNotMovePrice() public {
        assertEq(_lmp(), LISTING, "listing price");
        _limitSell(trader1, UNDER, 10e18);
        assertEq(_lmp(), LISTING, "a resting ask must not write lmp");
    }

    /// Symmetric: a bid above the last price is also only an offer.
    function test_restingLimitBuy_doesNotMovePrice() public {
        _limitBuy(trader1, OVER, 1000e18);
        assertEq(_lmp(), LISTING, "a resting bid must not write lmp");
    }

    /**
     * The walk-down, as described in the launch memo: place an ask under the last
     * price, let it print, cancel it, repeat. No buyer, no capital at risk, gas only.
     * Thirteen rounds used to cover ~49.5%; here each round is the full spread.
     */
    function test_walkDown_thirteenRestingOrders_doesNotMovePrice() public {
        uint256 price = LISTING;
        for (uint256 i = 0; i < 13; i++) {
            price = (price * 97) / 100;
            uint32 id = _limitSell(trader1, price, 1e18);
            _cancelAsk(trader1, id);
        }
        assertEq(_lmp(), LISTING, "13 cancelled asks must leave the price where it was");
    }

    /// A trade is a price. This is the half that must keep working.
    function test_match_movesPrice() public {
        _limitSell(trader2, UNDER, 10e18);
        uint256 before = _lmp();
        _marketBuy(trader1, 500e18);
        assertTrue(_lmp() != before, "a filled order must write lmp");
        assertEq(_lmp(), UNDER, "lmp is the traded price");
    }

    /// A pool swap is a trade too: band liquidity still prices the market.
    function test_poolSwap_movesPrice() public {
        _seedBands(1000e18);
        uint256 before = _lmp();
        _buy(trader1, 100e18);
        assertTrue(_lmp() != before, "a pool swap must still report a price");
    }

    // --------------------------------------------------------------- the revert

    /// Nothing on the book, nothing in the pool: say so rather than refunding in silence.
    function test_marketBuy_revertsWhenBookAndPoolAreEmpty() public {
        _approveQuote(trader1);
        vm.prank(trader1);
        vm.expectRevert(OrderPlacementLib.InsufficientLiquidity.selector);
        matchingEngine.marketBuy(
            IMatchingEngine.MarketOrderInput({
                base: address(token1),
                quote: address(token2),
                amount: 100e18,
                isMaker: false,
                n: 2,
                recipient: trader1,
                slippageLimit: 0
            })
        );
    }

    /// The same order, with band liquidity behind it, fills from the pool.
    function test_marketBuy_fillsFromPoolWhenBookIsEmpty() public {
        _seedBands(1000e18);
        uint256 baseBefore = token1.balanceOf(trader1);
        _marketBuy(trader1, 100e18);
        assertGt(token1.balanceOf(trader1), baseBefore, "the pool filled it");
    }

    /// A partial fill is not a failure: what the book could not take still comes home.
    function test_marketBuy_partialFill_refundsRemainderWithoutReverting() public {
        _limitSell(trader2, UNDER, 1e18); // one small ask
        uint256 quoteBefore = token2.balanceOf(trader1);
        uint256 baseBefore = token1.balanceOf(trader1);
        _marketBuy(trader1, 5000e18); // far more than the ask can fill
        assertGt(token1.balanceOf(trader1), baseBefore, "it filled what it could");
        assertGt(token2.balanceOf(trader1), quoteBefore - 5000e18, "the rest was refunded");
    }
}
