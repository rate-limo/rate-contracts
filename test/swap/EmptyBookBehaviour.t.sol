// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandBaseSetup} from "./BandBaseSetup.sol";
import {IMatchingEngine} from "../../src/exchange/interfaces/IMatchingEngine.sol";
import {OrderPlacementLib} from "../../src/exchange/libraries/OrderPlacementLib.sol";
import {MatchingEngine} from "../../src/exchange/MatchingEngine.sol";

/**
 * MARKET reverts, LIMIT rests -- the distinction the error copy is written against.
 *
 * The pair exists, the pool holds nothing and the book is empty: the state a user meets
 * on a coin nobody has made a market in yet. `apps/web/utils/orderErrors.ts` tells that
 * user their fix is a limit order rather than a smaller size, and that sentence is only
 * true while these two halves hold. If a later change makes a limit order revert here
 * too, that copy becomes a lie and this test is what should catch it.
 *
 * The revert itself is pinned by `test/exchange/QuoteNotPrice.t.sol`, which owns the
 * behaviour. This file owns the CONTRAST.
 */
contract EmptyBookBehaviourTest is BandBaseSetup {
    function _fund(address who) private {
        token1.mint(who, 1_000e18);
        token2.mint(who, 1_000e18);
        vm.startPrank(who);
        token1.approve(address(matchingEngine), type(uint256).max);
        token2.approve(address(matchingEngine), type(uint256).max);
        vm.stopPrank();
    }

    function test_marketBuy_revertsRatherThanRefundingSilently() public {
        _fund(trader1);
        vm.prank(trader1);
        vm.expectRevert(OrderPlacementLib.InsufficientLiquidity.selector);
        matchingEngine.marketBuy(
            IMatchingEngine.MarketOrderInput({
                base: address(token1), quote: address(token2), amount: 10e18,
                isMaker: false, n: 2, recipient: trader1, slippageLimit: 1000000
            })
        );
    }

    function test_marketSell_revertsRatherThanRefundingSilently() public {
        _fund(trader1);
        vm.prank(trader1);
        vm.expectRevert(OrderPlacementLib.InsufficientLiquidity.selector);
        matchingEngine.marketSell(
            IMatchingEngine.MarketOrderInput({
                base: address(token1), quote: address(token2), amount: 10e18,
                isMaker: false, n: 2, recipient: trader1, slippageLimit: 1000000
            })
        );
    }

    /// The other half: the fix the UI offers has to actually work.
    function test_limitOrder_restsInsteadOfReverting() public {
        _fund(trader1);
        uint256 before = token2.balanceOf(trader1);

        vm.prank(trader1);
        IMatchingEngine.OrderResult memory r = matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1), quote: address(token2), price: LISTING,
                amount: 10e18, isMaker: true, n: 2, recipient: trader1
            })
        );

        assertGt(r.id, 0, "the order rested and has an id");
        assertEq(r.placed, 10e18, "the whole amount rested");
        assertEq(before - token2.balanceOf(trader1), 10e18, "and the quote left the wallet to fund it");
    }

    /// The engine's ABI must carry the error, or every client decodes a raw hex blob.
    /// This is the fifth time a library-only declaration has caused that in this repo.
    function test_theErrorIsOnTheEngineAbiToo() public pure {
        assertEq(
            OrderPlacementLib.InsufficientLiquidity.selector,
            MatchingEngine.InsufficientLiquidity.selector,
            "MatchingEngine must declare InsufficientLiquidity for clients to decode it"
        );
    }
}
