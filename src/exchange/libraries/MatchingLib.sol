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

    /**
     * @notice Matching stopped early because the transaction was running out of gas.
     * @dev Not an error. The unmatched `remaining` is rested by the caller exactly as
     * it would be after any other early exit, so the trader keeps a partial fill plus
     * an order on the book. Emitted so that outcome is explicable rather than merely
     * survivable -- a UI can say "filled what it could and rested the rest" instead of
     * leaving the trader to wonder why a sweep stopped short.
     */
    event MatchingHaltedForGas(address indexed pair, uint256 remaining, uint32 matched);

    /**
     * @notice Gas held back so a halted match can still settle and rest the remainder.
     *
     * @dev An order's cost depends on what it MATCHES, and the caller sets the gas
     * limit before knowing what it will meet. Measured on RISE: an order that matches
     * nothing costs ~240,000 gas and one that matches a single resting ask costs
     * ~373,000. So an order priced into an empty book and mined a moment after someone
     * rests an ask arrives roughly a third short.
     *
     * Without a guard the EVM stops execution mid-write and the WHOLE transaction
     * reverts: no fill, no resting order, and empty revert data, which is why nothing
     * downstream could name the cause. The trader is told a transfer failed.
     *
     * The reserve turns that into an ordinary early exit. It is checked BEFORE doing
     * a unit of work, so it must cover one more unit plus everything after the loop:
     *
     *   one order matched .......... ~105,000
     *   settle, rest, emit ......... ~353,000  (the non-matching path's own cost)
     *   -------------------------------------
     *   floor ...................... ~458,000
     *   reserve .................... 500,000   (~9% margin)
     *
     * ## Both halves of that table were wrong, and the guard was in the wrong loop
     *
     * This read `one match ~133,000 / settle, rest, emit ~170,000 / reserve 300,000`
     * until 2026-09-28. Two independent defects, and each one alone makes a starved
     * order revert -- the exact outcome the reserve exists to prevent.
     *
     * **The figures were measured WARM.** They came from a suite running Foundry's
     * default `isolate = false`, where the calls that set up a book leave every slot
     * warm for the call under test. A real transaction carries a fresh access list, so
     * every slot is cold and EIP-2929 charges 2,100 for a cold SLOAD against 100 warm.
     * Re-measured under `isolate` (`ReserveSweep.t.sol`), the tail alone is ~353,000 --
     * more than the whole 300,000 reserve, before a single further match is paid for.
     * The old numbers were not sloppy; they were taken in a regime that does not exist
     * on chain. Measure gas for this constant under isolate, or not at all.
     *
     * **And it was checked once per price LEVEL, not per order.** See the long note at
     * the top of `matchAt`'s loop: a level holds an unbounded queue, so a per-level
     * reserve has to cover the whole queue and the constant would have to grow with
     * `n`. Sweeping gas caps against a level of six asks, 57 of 116 sampled caps
     * between 450,000 and 1,600,000 reverted, and no reserve below 1,000,000 closed
     * them. The guard now sits in `matchAt`, per order, which is what makes a bounded
     * constant sufficient: `ReserveSweep.t.sol` holds it across 2..20 orders at one
     * price, both sides of the book, maker and taker.
     *
     * Foundry made `isolate = true` the default in 1.8.x, which is how this surfaced:
     * one CI job failed on a test that had passed locally for months.
     *
     * Deliberately a constant rather than an admin-settable storage slot. MatchingLib is
     * a `public`-function library reached by delegatecall, so a constant costs the engine
     * no bytecode -- and MatchingEngine.sol sits a few hundred bytes under the EIP-170
     * limit, which is why `applySwapRail` was moved here in the first place.
     */
    uint256 internal constant MATCH_GAS_RESERVE = 500_000;

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

    /**
     * @notice The order's gas ran below `MATCH_GAS_RESERVE` before it matched anything,
     * while the opposite side of the book still crossed its limit.
     *
     * @dev Halt-and-rest is right for a PARTIAL fill: the trader keeps what matched and the
     * remainder rests. With zero matches it was a trap. The order "succeeded" by resting
     * its whole amount ON the opposite head -- a locked book, a bid and an ask at the same
     * price -- and, worse, that success is what `eth_estimateGas` converges on: its binary
     * search finds the cheapest gas limit that does not revert, which was exactly the
     * starved path. So wallets were handed a limit too small to match, and every order
     * sent with it rested instead of filling. Found on RISE KPRF1448/tUSD, 2026-10-04.
     *
     * Reverting here moves the cheapest succeeding limit up to "at least one match", so an
     * estimate now pays for a fill. Only the trader's own order is strict -- see
     * `MatchAtInput.strict`.
     */
    error InsufficientGasToMatch();

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
            // The reserve is enforced HERE, per ORDER, and not only per price level.
            //
            // One iteration of `limitOrder`'s loop is one price LEVEL, and a level holds
            // an unbounded queue: this loop fills up to `n` orders at a single price and
            // evicts up to `MAX_DUST_EVICTIONS` more, each a delete, a transfer and a
            // log. A reserve checked only outside this loop therefore has to cover the
            // whole level, so the number it needs grows with `n` -- and a constant that
            // large stops an ordinary order matching at all.
            //
            // Measured against a level holding six asks (`ReserveSweep.t.sol`): with the
            // check only outside this loop, 57 of 116 sampled gas caps between 450,000
            // and 1,600,000 REVERTED, and no reserve below 1,000,000 closed them --
            // which is the guard failing at the one thing it exists for. Checked per
            // order, the reserve covers one order plus the tail: bounded, and independent
            // of how deep the level is.
            //
            // Returning `n` is how the halt reaches the caller. `limitOrder`'s loop
            // condition is `state.i < input.n`, so this ends the sweep on the next
            // evaluation and the caller rests `remaining` -- the same exit it already
            // takes on depth or on `n`. It also travels to `StopOrderHandoffLib.handoff`
            // as `used`, telling the stop engine the match budget is spent, which is
            // exactly right when the reason we stopped was gas.
            if (gasleft() < MATCH_GAS_RESERVE) {
                // Nothing matched yet and this level crosses: see InsufficientGasToMatch.
                if (matchAtInput.strict && matchAtInput.i == 0) revert InsufficientGasToMatch();
                emit MatchingHaltedForGas(matchAtInput.pair, remaining, matchAtInput.i);
                return (remaining, matchAtInput.n);
            }

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
                        _reportEviction(matchAtInput, orderId, removedOwner, removedRefund, expired, removedDeadline);
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
                if (!deleted) _evictIfDust(matchAtInput);
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

    /**
     * @notice Evict the order a partial fill just left behind, if what remains of it
     * can never fill.
     *
     * @dev Conversion floors before it scales, so a partial fill can leave a remainder
     * that converts to zero in the taker's asset -- on ETH/USDC (18/6 decimals, price
     * ~2000) any bid remainder under ~2000 raw USDC. `fpop` already evicts such an order,
     * but only when a LATER taker reaches its price; until then it rests, reads ≈100%
     * filled, and only its owner cancelling clears it. Asking `fpop` again with nothing
     * to fill applies its own `required == 0` test to the head -- the order just
     * matched -- and changes nothing when the remainder is fillable. One definition of
     * "cannot fill", now applied in the match that creates the dust.
     * See PartialFillNeverLeavesDust.t.sol.
     */
    function _evictIfDust(IMatchingEngine.MatchAtInput memory m) private {
        (uint32 id, uint256 required, , address owner, uint256 refund, bool expired, uint64 deadline) =
            IOrderbook(m.pair).fpop(!m.isBid, m.price, 0);
        if (required == 0 && owner != address(0)) _reportEviction(m, id, owner, refund, expired, deadline);
    }

    function _reportEviction(
        IMatchingEngine.MatchAtInput memory m,
        uint32 orderId,
        address owner,
        uint256 refund,
        bool expired,
        uint64 deadline
    ) private {
        if (expired) {
            emit OrderExpired(m.pair, orderId, owner, !m.isBid, false, false, deadline, refund);
        } else {
            emit OrderDusted(m.pair, m.orderHistoryId, orderId, !m.isBid, m.price, owner, refund);
        }
    }

    /**
     * @notice The gas held back so a halted match can still settle and rest.
     *
     * @dev Readable so a caller can size its gas limit from the contract rather
     * than hardcoding a number that then drifts from it. A client budgeting for a
     * sweep wants roughly:
     *
     *     limit = base + (levels * perMatch) + matchGasReserve()
     *
     * where `perMatch` is ~75,000-77,000 on the measurements in
     * contracts/CLAUDE.md and `levels` is bounded by `MatchingEngine.maxMatches`.
     *
     * Note what this does NOT do: it cannot tell you how much WILL match, because
     * that depends on the book at inclusion time, which is the whole reason the
     * reserve exists. What it guarantees is the outcome when the budget runs
     * short -- a partial fill and a rested-or-refunded remainder, rather than a
     * revert. The amount actually left over is reported by `MatchingHaltedForGas`;
     * a transaction's return value is not observable off chain, so the event is
     * the only channel that can carry it to an indexer or a UI.
     */
    function matchGasReserve() public pure returns (uint256) {
        return MATCH_GAS_RESERVE;
    }

    /// The stop-order passes' entry (`StopOrderMatchingLib`). They run inside another
    /// trader's transaction, after that trader's order already settled, so a gas halt
    /// there must degrade to "not this trade" and never revert the trader's fill.
    function limitOrder(LimitOrderInput memory input, uint32 maxMatches)
        public returns (uint256 remaining, uint256 bidHead, uint256 askHead, uint32 matchesUsed)
    {
        return _limitOrder(input, maxMatches, false);
    }

    /// The engine's entry, for the trader's own order: identical, except a gas halt with
    /// ZERO matches reverts `InsufficientGasToMatch` instead of resting the whole amount
    /// on the opposite head. A halt after a partial fill still rests the remainder.
    function limitOrderStrict(LimitOrderInput memory input, uint32 maxMatches)
        public returns (uint256 remaining, uint256 bidHead, uint256 askHead, uint32 matchesUsed)
    {
        return _limitOrder(input, maxMatches, true);
    }

    function _limitOrder(LimitOrderInput memory input, uint32 maxMatches, bool strict)
        private returns (uint256 remaining, uint256 bidHead, uint256 askHead, uint32 matchesUsed)
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
                // Stop while there is still enough gas to settle and rest what is left.
                // Falling out here is the SAME exit the loop already takes when it runs
                // out of depth or hits `n`, and the caller rests `remaining` either way.
                if (gasleft() < MATCH_GAS_RESERVE) {
                    if (strict && state.i == 0) revert InsufficientGasToMatch();
                    emit MatchingHaltedForGas(input.pair, remaining, state.i);
                    break;
                }
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
                    orderHistoryId: input.orderHistoryId,
                    strict: strict
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
                if (gasleft() < MATCH_GAS_RESERVE) {
                    if (strict && state.i == 0) revert InsufficientGasToMatch();
                    emit MatchingHaltedForGas(input.pair, remaining, state.i);
                    break;
                }
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
                    orderHistoryId: input.orderHistoryId,
                    strict: strict
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
