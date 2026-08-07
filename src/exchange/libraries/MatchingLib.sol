// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IMatchingEngine} from "../interfaces/IMatchingEngine.sol";
import {IOrderbook} from "../interfaces/IOrderbook.sol";
import {TransferHelper} from "./TransferHelper.sol";

library MatchingLib {
    event OrderMatched(
        address pair,
        uint16 orderHistoryId,
        uint256 id,
        bool isBid,
        uint256 price,
        uint256 total,
        bool clear,
        IMatchingEngine.OrderMatch orderMatch
    );

    event NewMarketPrice(address pair, uint256 price, bool isBid);

    /// @notice An order was evicted from the book and its deposit refunded, because
    /// what remained converted to zero in the taker's asset and could never fill.
    /// Distinct from OrderCanceled on purpose -- the maker did not ask for this, and
    /// labelling it a cancellation would misreport their own order history.
    /// Before this event the eviction and the refund were entirely unobservable.
    event OrderDusted(
        address pair,
        uint16 orderHistoryId,
        uint256 id,
        bool isBid,
        uint256 price,
        address owner,
        uint256 refunded
    );

    error TooManyMatches(uint256 n);

    /// Evictions this call may perform before giving up on the level.
    ///
    /// Evicting an unfillable order does not consume the taker's match budget --
    /// they got no fill, and charging them means a queue of other people's
    /// remainders can starve a legitimate order (proven under PriceTimePriority in
    /// PoC_DustEatsMatchBudget). But "free" cannot mean "unbounded": each eviction
    /// is a delete, a transfer and a log, so an arbitrarily long run of them is a
    /// gas problem instead of a fill problem. This caps the work one call will do;
    /// the level is left for the next taker, having shrunk by this many.
    uint32 internal constant MAX_DUST_EVICTIONS = 8;

    function matchAt(
        IMatchingEngine.MatchAtInput memory matchAtInput
    ) public returns (uint256 remaining, uint32 k) {
        remaining = matchAtInput.amount;
        uint32 evictions = 0;
        while (
            remaining > 0 &&
            !IOrderbook(matchAtInput.pair).isEmpty(!matchAtInput.isBid, matchAtInput.price) &&
            matchAtInput.i < matchAtInput.n &&
            evictions < MAX_DUST_EVICTIONS
        ) {
            uint32 orderId;
            uint256 required;
            bool clear;
            // Scoped so the eviction-only values do not live across the rest of the
            // body -- without this the frame is one local too deep to compile.
            {
                address dustOwner;
                uint256 dustRefund;
                (orderId, required, clear, dustOwner, dustRefund) = IOrderbook(matchAtInput.pair).fpop(
                    !matchAtInput.isBid, matchAtInput.price, remaining
                );
                // Unfillable: fpop already deleted it and refunded its owner. Checked
                // before the fill branches because `remaining <= required` can never
                // hold here (remaining > 0 is the loop condition, required == 0).
                if (required == 0) {
                    if (dustOwner != address(0)) {
                        emit OrderDusted(
                            matchAtInput.pair, matchAtInput.orderHistoryId, orderId,
                            !matchAtInput.isBid, matchAtInput.price, dustOwner, dustRefund
                        );
                    }
                    // Counted against the eviction cap, NOT against `i`. The taker
                    // received nothing here; charging them a match lets a queue of
                    // other people's remainders consume the budget their order needed.
                    ++evictions;
                    continue;
                }
            }

            if (remaining <= required) {
                TransferHelper.safeTransfer(matchAtInput.give, matchAtInput.pair, remaining);
                // `deleted`, not `clear`: what the book did, not what was asked of it.
                (IMatchingEngine.OrderMatch memory orderMatch, bool deleted) = IOrderbook(matchAtInput.pair).execute(
                    orderId, !matchAtInput.isBid, matchAtInput.recipient, remaining, clear
                );
                emit OrderMatched(
                    matchAtInput.pair, matchAtInput.orderHistoryId, orderId,
                    matchAtInput.isBid, matchAtInput.price, matchAtInput.total, deleted, orderMatch
                );
                return (0, matchAtInput.n);
            }

            remaining -= required;
            TransferHelper.safeTransfer(matchAtInput.give, matchAtInput.pair, required);
            (IMatchingEngine.OrderMatch memory om, bool wasDeleted) = IOrderbook(matchAtInput.pair).execute(
                orderId, !matchAtInput.isBid, matchAtInput.recipient, required, clear
            );
            emit OrderMatched(
                matchAtInput.pair, matchAtInput.orderHistoryId, orderId,
                matchAtInput.isBid, matchAtInput.price, matchAtInput.total, wasDeleted, om
            );
            ++matchAtInput.i;
        }
        k = matchAtInput.i;
        return (remaining, k);
    }

    function limitOrder(
        address pair,
        uint256 amount,
        address give,
        address recipient,
        bool isBid,
        uint256 limitPrice,
        uint32 n,
        uint16 orderHistoryId,
        uint32 maxMatches
    ) public returns (uint256 remaining, uint256 bidHead, uint256 askHead) {
        if (n > maxMatches) {
            revert TooManyMatches(n);
        }
        remaining = amount;
        IMatchingEngine.LimitOrderState memory state = IMatchingEngine.LimitOrderState({
            lmp: IOrderbook(pair).lmp(),
            i: 0,
            prevI: 0
        });
        bidHead = IOrderbook(pair).clearEmptyHead(true);
        askHead = IOrderbook(pair).clearEmptyHead(false);
        if (isBid) {
            if (state.lmp != 0) {
                if (askHead != 0 && limitPrice < askHead) {
                    return (remaining, bidHead, askHead);
                } else if (askHead == 0) {
                    return (remaining, bidHead, askHead);
                }
            }
            while (remaining > 0 && askHead != 0 && askHead <= limitPrice && state.i < n) {
                state.lmp = askHead;
                state.prevI = state.i;
                (remaining, state.i) = matchAt(IMatchingEngine.MatchAtInput({
                    pair: pair,
                    give: give,
                    recipient: recipient,
                    isBid: isBid,
                    amount: remaining,
                    total: amount,
                    price: askHead,
                    i: state.i,
                    n: n,
                    orderHistoryId: orderHistoryId
                }));
                askHead = (state.i == state.prevI) ? 0 : IOrderbook(pair).clearEmptyHead(false);
            }
            bidHead = IOrderbook(pair).clearEmptyHead(true);
        } else {
            if (state.lmp != 0) {
                if (bidHead != 0 && limitPrice > bidHead) {
                    return (remaining, bidHead, askHead);
                } else if (bidHead == 0) {
                    return (remaining, bidHead, askHead);
                }
            }
            while (remaining > 0 && bidHead != 0 && bidHead >= limitPrice && state.i < n) {
                state.lmp = bidHead;
                state.prevI = state.i;
                (remaining, state.i) = matchAt(IMatchingEngine.MatchAtInput({
                    pair: pair,
                    give: give,
                    recipient: recipient,
                    isBid: isBid,
                    amount: remaining,
                    total: amount,
                    price: bidHead,
                    i: state.i,
                    n: n,
                    orderHistoryId: orderHistoryId
                }));
                bidHead = (state.i == state.prevI) ? 0 : IOrderbook(pair).clearEmptyHead(true);
            }
            askHead = IOrderbook(pair).clearEmptyHead(false);
        }
        if (state.lmp != 0) {
            IOrderbook(pair).setLmp(state.lmp);
            emit NewMarketPrice(pair, state.lmp, isBid);
        }
        return (remaining, bidHead, askHead);
    }
}
