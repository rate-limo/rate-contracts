// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IOrderbook} from "../interfaces/IOrderbook.sol";
import {ExchangeOrderbook} from "./ExchangeOrderbook.sol";
import {TransferHelper} from "./TransferHelper.sol";
import {PoolFallbackLib} from "./PoolFallbackLib.sol";

/**
 * What happens to an order's remainder once matching is done.
 *
 * ## Why this is a library and not four inlined copies
 *
 * `_detMake` and `_makeOrder` lived in MatchingEngine and were inlined at five call
 * sites -- both limit entrypoints and both market ones. That was affordable until the
 * pool fallback needed adding: the call site alone cost 188 bytes against the 52 the
 * engine had left, putting it 136 OVER EIP-170 and undeployable.
 *
 * Moving the whole tail out replaces five inlined bodies with five delegatecalls and
 * pays for the new behaviour several times over. `PoolFallbackLib.route` is `internal`
 * so it inlines HERE rather than costing a second hop.
 *
 * `orderDeadlineContext` is passed in because it is the one thing this code read from
 * engine storage. A library reached by delegatecall could technically reach it, but
 * only by redeclaring the engine's storage layout -- a coupling that breaks silently
 * the first time a variable is reordered. A parameter cannot.
 */
library OrderPlacementLib {
    event OrderCanceled(
        address pair, uint256 id, bool isBid, address indexed owner, uint256 amount
    );

    /**
     * A market order that filled NOTHING -- not on the book within its spread, and not
     * from the pool -- reverts rather than handing the deposit back as if it had traded.
     *
     * Before the band pools this would have been the wrong call: with no pool there was
     * routinely no counterparty, and a silent refund was the only honest answer. Now
     * every listed market has a standing two-sided quote under it, so "nothing filled"
     * means the pool is empty too, and that is worth saying out loud -- a market order
     * that succeeds while spending nothing reads, to a caller and to a user, as a fill
     * at a price that never happened.
     *
     * Only MARKET orders raise it. A taker limit order is a price the caller chose and
     * may legitimately cross nothing (LadderBuyer walks levels expecting exactly that),
     * and a maker order rests instead of reaching this path at all.
     */
    error InsufficientLiquidity();

    /// The remainder may rest on the book.
    uint8 internal constant MAKER = 1;
    /// A market order whose book leg filled nothing: an empty pool is a revert, not a refund.
    uint8 internal constant REQUIRE_FILL = 2;

    /**
     * Rest the remainder, or -- for a taker -- try the pool and refund what is left.
     *
     * @param give  the token being spent: quote on a bid, base on an ask.
     * @param flags `MAKER` if the remainder may rest; `REQUIRE_FILL` if the caller is a
     *              MARKET order that matched nothing on the book, so the pool is its last
     *              venue and an empty pool is a revert. Packed into ONE argument because
     *              both order paths in MatchingEngine are at the EVM's stack limit -- a
     *              ninth parameter here compiles to "stack too deep" there.
     * @return id   the resting order's id, or 0 if nothing was placed.
     */
    function detMake(
        address pair,
        address give,
        uint256 remaining,
        uint256 price,
        bool isBid,
        uint8 flags,
        address recipient,
        uint64 orderDeadlineContext
    ) public returns (uint32 id) {
        if (remaining == 0) return 0;

        // A maker order whose remainder converts to zero is dust: refund it rather than
        // placing an order that can never execute.
        if (flags & MAKER != 0 && _convert(pair, price, remaining, !isBid) > 0) {
            TransferHelper.safeTransfer(give, pair, remaining);
            return _makeOrder(pair, remaining, price, isBid, recipient, orderDeadlineContext);
        }

        // Taker path. The pool is the third venue an order sees, after the book and any
        // stops it woke; whatever the pool does not take goes home.
        uint256 left = PoolFallbackLib.route(pair, give, isBid, remaining, recipient, price);
        // `left == remaining` means the pool took none of it. With REQUIRE_FILL -- the
        // book took none either -- nothing anywhere filled this order.
        if (flags & REQUIRE_FILL != 0 && left == remaining) revert InsufficientLiquidity();
        if (left > 0) TransferHelper.safeTransfer(give, recipient, left);
        return 0;
    }

    function _convert(address pair, uint256 price, uint256 amount, bool isBid)
        private view returns (uint256)
    {
        if (pair == address(0)) return 0;
        return price == 0
            ? IOrderbook(pair).assetValue(amount, isBid)
            : IOrderbook(pair).convert(price, amount, isBid);
    }

    function _makeOrder(
        address pair,
        uint256 withoutFee,
        uint256 price,
        bool isBid,
        address recipient,
        uint64 orderDeadlineContext
    ) private returns (uint32 id) {
        bool foundDmt;
        if (isBid) {
            (id, foundDmt) = IOrderbook(pair).placeBid(recipient, price, withoutFee, orderDeadlineContext);
        } else {
            (id, foundDmt) = IOrderbook(pair).placeAsk(recipient, price, withoutFee, orderDeadlineContext);
        }
        if (foundDmt) {
            ExchangeOrderbook.Order memory order = IOrderbook(pair).removeDmt(isBid);
            emit OrderCanceled(pair, id, isBid, order.owner, order.depositAmount);
        }
        return id;
    }
}
