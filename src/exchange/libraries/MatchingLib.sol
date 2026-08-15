// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IMatchingEngine} from "../interfaces/IMatchingEngine.sol";
import {IOrderbook} from "../interfaces/IOrderbook.sol";
import {TransferHelper} from "./TransferHelper.sol";

library MatchingLib {
    struct LimitOrderInput {
        address pair;
        uint256 amount;
        address give;
        address recipient;
        bool isBid;
        uint256 limitPrice;
        uint32 n;
        uint16 orderHistoryId;
    }
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

    /// @notice Mirrored from MatchingEngine for the same reason as the events above:
    /// this is a delegatecall, so the log carries the engine's address, but an event
    /// declared only here would be absent from the engine's ABI and an indexer
    /// watching that address could not decode it.
    /// Declaration must stay IDENTICAL to MatchingEngine's, `indexed` included. Dropping
    /// it does not change topic0 -- the signature string ignores indexing -- so the event
    /// still looks right by name while landing its pair in data instead of a topic, and
    /// every expectEmit and every indexer filter on it silently stops matching.
    event SwapPriceReport(
        address indexed pair,
        uint256 lmpBefore,
        uint256 reported,
        uint256 lmpAfter,
        bool isBuy
    );

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

    event OrderExpired(
        address indexed pair,
        uint32 indexed orderId,
        address indexed owner,
        bool isBid,
        bool isStop,
        bool isMarket,
        uint64 deadline,
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
                address removedOwner;
                uint256 removedRefund;
                bool expired;
                uint64 removedDeadline;
                (orderId, required, clear, removedOwner, removedRefund, expired, removedDeadline) = IOrderbook(matchAtInput.pair).fpop(
                    !matchAtInput.isBid, matchAtInput.price, remaining
                );
                // Unfillable: fpop already deleted it and refunded its owner. Checked
                // before the fill branches because `remaining <= required` can never
                // hold here (remaining > 0 is the loop condition, required == 0).
                if (required == 0) {
                    if (removedOwner != address(0)) {
                        if (expired) {
                            emit OrderExpired(
                                matchAtInput.pair, orderId, removedOwner, !matchAtInput.isBid,
                                false, false, removedDeadline, removedRefund
                            );
                        } else {
                            emit OrderDusted(
                                matchAtInput.pair, matchAtInput.orderHistoryId, orderId,
                                !matchAtInput.isBid, matchAtInput.price, removedOwner, removedRefund
                            );
                        }
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

    function limitOrder(LimitOrderInput memory input, uint32 maxMatches)
        public returns (uint256 remaining, uint256 bidHead, uint256 askHead, uint32 matchesUsed)
    {
        if (input.n > maxMatches) {
            revert TooManyMatches(input.n);
        }
        remaining = input.amount;
        IMatchingEngine.LimitOrderState memory state = IMatchingEngine.LimitOrderState({
            lmp: IOrderbook(input.pair).lmp(),
            i: 0,
            prevI: 0
        });
        bidHead = IOrderbook(input.pair).clearEmptyHead(true);
        askHead = IOrderbook(input.pair).clearEmptyHead(false);
        if (input.isBid) {
            if (state.lmp != 0) {
                if (askHead != 0 && input.limitPrice < askHead) {
                    return (remaining, bidHead, askHead, 0);
                } else if (askHead == 0) {
                    return (remaining, bidHead, askHead, 0);
                }
            }
            while (remaining > 0 && askHead != 0 && askHead <= input.limitPrice && state.i < input.n) {
                state.lmp = askHead;
                state.prevI = state.i;
                (remaining, state.i) = matchAt(IMatchingEngine.MatchAtInput({
                    pair: input.pair,
                    give: input.give,
                    recipient: input.recipient,
                    isBid: input.isBid,
                    amount: remaining,
                    total: input.amount,
                    price: askHead,
                    i: state.i,
                    n: input.n,
                    orderHistoryId: input.orderHistoryId
                }));
                askHead = (state.i == state.prevI) ? 0 : IOrderbook(input.pair).clearEmptyHead(false);
            }
            bidHead = IOrderbook(input.pair).clearEmptyHead(true);
        } else {
            if (state.lmp != 0) {
                if (bidHead != 0 && input.limitPrice > bidHead) {
                    return (remaining, bidHead, askHead, 0);
                } else if (bidHead == 0) {
                    return (remaining, bidHead, askHead, 0);
                }
            }
            while (remaining > 0 && bidHead != 0 && bidHead >= input.limitPrice && state.i < input.n) {
                state.lmp = bidHead;
                state.prevI = state.i;
                (remaining, state.i) = matchAt(IMatchingEngine.MatchAtInput({
                    pair: input.pair,
                    give: input.give,
                    recipient: input.recipient,
                    isBid: input.isBid,
                    amount: remaining,
                    total: input.amount,
                    price: bidHead,
                    i: state.i,
                    n: input.n,
                    orderHistoryId: input.orderHistoryId
                }));
                bidHead = (state.i == state.prevI) ? 0 : IOrderbook(input.pair).clearEmptyHead(true);
            }
            askHead = IOrderbook(input.pair).clearEmptyHead(false);
        }
        if (state.lmp != 0) {
            IOrderbook(input.pair).setLmp(state.lmp);
            emit NewMarketPrice(input.pair, state.lmp, input.isBid);
        }
        return (remaining, bidHead, askHead, state.i);
    }

    /**
     * @notice Applies the block-open price rail to a swap-reported price and writes it.
     * @dev Moved out of MatchingEngine.reportSwap purely for EIP-170 headroom -- the
     * engine sits a few hundred bytes under the 24,576 limit. Behaviour is unchanged:
     * this is a delegatecall, so `pair` still sees the engine as its caller and the
     * logs still carry the engine's address.
     *
     * The rail is applied in BOTH directions regardless of which way the swap traded.
     * A swap's own side says which way it *intends* to push the price; it does not
     * license an unbounded move the other way. Bounding only the trade's own direction
     * left the opposite direction completely unconstrained -- a buy could write the
     * price arbitrarily far DOWN, and a spread of zero, the strongest circuit breaker
     * the system can express, did not prevent it.
     *
     * Anchored to the price the pair opened this block at rather than to the live lmp:
     * the rail is applied per report, so N reports in one transaction would otherwise
     * each get a fresh cap measured against their predecessor's write and compound
     * straight past it. Anchoring bounds the block as a whole, and the cap re-arms
     * next block so honest sustained flow is not frozen out.
     */
    function reportSwapPrice(
        address pair,
        uint256 matchedPrice,
        bool isBuy,
        uint32 up,
        uint32 down,
        uint32 denom
    ) public {
        uint256 lmp = IOrderbook(pair).lmp();
        if (lmp == 0 || matchedPrice == 0) return;

        uint256 newLmp = matchedPrice;
        uint256 anchor = IOrderbook(pair).lmpAtBlockOpen();
        uint256 ceiling = (anchor * (denom + uint256(up))) / denom;
        // A spread of 100%+ means "no lower bound"; taking denom - down there would
        // underflow and revert the whole swap. Elsewhere that config already bricks limit
        // orders, but a rail must never be the thing that fails a settled trade.
        uint256 floor = down >= denom ? 0 : (anchor * (denom - uint256(down))) / denom;
        if (newLmp > ceiling) newLmp = ceiling;
        if (newLmp < floor) newLmp = floor;
        if (newLmp == 0 || newLmp == lmp) return;

        IOrderbook(pair).setLmp(newLmp);
        emit NewMarketPrice(pair, newLmp, isBuy);
        emit SwapPriceReport(pair, lmp, matchedPrice, newLmp, isBuy);
    }
}
