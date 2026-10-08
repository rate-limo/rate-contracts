// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IOrderbook} from "../interfaces/IOrderbook.sol";
import {IMatchingEngine} from "../interfaces/IMatchingEngine.sol";
import {StopLimitOrderbook} from "../orderbooks/StopLimitOrderbook.sol";
import {ExchangeOrderbook} from "./ExchangeOrderbook.sol";
import {MarketMakePriceLib} from "./MarketMakePriceLib.sol";
import {MatchingLib} from "./MatchingLib.sol";
import {TransferHelper} from "./TransferHelper.sol";

library StopOrderMatchingLib {
    uint256 internal constant DENOM = 100_000_000;

    struct MatchState {
        address stopBook;
        uint256 remaining;
        uint256 bidHead;
        uint256 askHead;
        uint32 used;
        uint32 maxMatches;
        uint32 buySpread;
        uint32 sellSpread;
        /// Read for the LIMIT spread only when a limit stop actually activates. The two
        /// market spreads above are needed on every call for the stop-market path, but
        /// this one is not, and reading it eagerly would charge an SLOAD to every order
        /// that reaches the handoff and activates nothing -- which is most of them.
        address engine;
    }

    event OrderCanceled(address pair, uint256 id, bool isBid, address indexed owner, uint256 amount);
    event StopOrderActivated(
        address indexed pair, uint32 indexed id, address indexed owner,
        bool isBid, bool isMarket, uint256 limitPrice, uint32 regularOrderId
    );
    event StopMarketOrderExecuted(
        address indexed pair, uint32 indexed id, address indexed owner,
        bool isBid, uint256 submitted, uint256 refunded
    );
    event OrderExpired(
        address indexed pair, uint32 indexed orderId, address indexed owner,
        bool isBid, bool isStop, bool isMarket, uint64 deadline, uint256 refunded
    );

    /**
     * @notice What one stop activation costs the taker who happens to trip it.
     * @dev +277,193 measured in `GasProbe_StopActivation.t.sol`. The owner pays to PLACE
     * a stop and nothing to have it fire; the cost lands on whichever order reaches this
     * handoff with budget left, which is what makes it the least predictable gas in the
     * system -- it depends on somebody else's resting stop, not on anything the taker did.
     */
    uint256 internal constant STOP_ACTIVATION_GAS = 280_000;

    /**
     * @notice Gas kept back for the work that FOLLOWS activation.
     * @dev Activation is not the end: `matchRemainder` re-runs `MatchingLib.limitOrder`
     * for the taker's remainder (which holds back its own reserve), and the caller then
     * settles and rests. 400,000 covers that tail.
     */
    uint256 internal constant STOP_TAIL_RESERVE = 400_000;

    /**
     * @notice How many stops this transaction can afford to wake, right now.
     *
     * @dev The clamp has to be applied BEFORE `activate()`, not inside the loop that
     * places what it returned, and that is the whole subtlety here: `activate()` DEQUEUES
     * the orders it hands back. Breaking out of `_activate`'s loop partway would leave a
     * stop removed from the trigger queue and never placed -- funds stranded, with no
     * error. Capping `maxOrders` instead means nothing is ever dequeued that cannot be
     * placed.
     *
     * Returning zero is a normal outcome, not a failure. A stop that does not wake on
     * this trade stays exactly where it was and wakes on the next one that crosses it.
     */
    function _affordableActivations() private view returns (uint32) {
        uint256 available = gasleft();
        if (available <= STOP_TAIL_RESERVE) return 0;
        uint256 count = (available - STOP_TAIL_RESERVE) / STOP_ACTIVATION_GAS;
        return count > type(uint32).max ? type(uint32).max : uint32(count);
    }

    function matchRemainder(MatchingLib.LimitOrderInput memory input, MatchState memory state)
        public returns (uint256, uint256, uint256)
    {
        if (state.stopBook == address(0)) return (state.remaining, state.bidHead, state.askHead);
        // `n` is shared across the regular and stop books. A regular-book match
        // consumes one slot, and stop orders must not even activate once all
        // slots have been consumed.
        if (state.used >= input.n) return (state.remaining, state.bidHead, state.askHead);
        uint32 activationBudget = input.n - state.used;
        // Waking a stop costs the taker ~280,000 on top of their own order, and they
        // cannot see it coming. Cap the budget at what this transaction can still
        // afford so a crossed stop degrades to "not this trade" instead of taking the
        // whole transaction out of gas.
        uint32 affordable = _affordableActivations();
        if (affordable == 0) return (state.remaining, state.bidHead, state.askHead);
        if (activationBudget > affordable) activationBudget = affordable;
        uint256 lmp = IOrderbook(input.pair).lmp();
        uint32 activated = _activate(
            state, input.pair, !input.isBid, lmp, activationBudget, input.orderHistoryId
        );
        if (activated < activationBudget) {
            activated += _activate(
                state, input.pair, input.isBid, lmp, activationBudget - activated, input.orderHistoryId
            );
        }
        if (state.remaining == 0 || activated == 0) {
            return (state.remaining, state.bidHead, state.askHead);
        }
        input.amount = state.remaining;
        input.n = activationBudget;
        (state.remaining, state.bidHead, state.askHead,) = MatchingLib.limitOrder(input, state.maxMatches);
        return (state.remaining, state.bidHead, state.askHead);
    }

    function _activate(
        MatchState memory state,
        address pair,
        bool restingIsBid,
        uint256 lmp,
        uint32 maxOrders,
        uint16 orderHistoryId
    ) private returns (uint32 count) {
        StopLimitOrderbook.ActivatedOrder[] memory activated =
            StopLimitOrderbook(state.stopBook).activate(restingIsBid, lmp, maxOrders);
        count = uint32(activated.length);
        for (uint256 i; i < activated.length; ++i) {
            _process(state, pair, restingIsBid, activated[i], orderHistoryId);
        }
    }

    /**
     * @dev An activated stop-limit rests like any other order, so it is PRICED like any
     * other order.
     *
     * It used to be handed straight to `placeBid`/`placeAsk` at its raw `limitPrice`, and
     * `Orderbook._place` inserts at whatever price it is given. That skipped both bounds
     * every other resting order passes -- never further than one spread from `lmp`, and
     * never across the opposing head -- and the second one is not cosmetic: because a
     * level can only be CREATED within one spread of `lmp`, and matching walks levels one
     * at a time, the make-price rail is what bounds how far a single trade can move the
     * price. A stop resting outside it let one ordinary trade teleport `lmp` past the
     * pair's circuit breaker and, through `setLmp`, into the TWAP the swap pool prices
     * off. Reproduced in VenueRouting.t.sol before this call existed.
     *
     * Clamping is never worse for the owner. A buy is only ever moved DOWN (they pay
     * less for the same deposit) and a sell only ever UP (they receive more), because
     * `limitBuy` is a pair of minima and `limitSell` a pair of maxima.
     *
     * What it does NOT do is fill against the head it clamps to -- the order rests at
     * that price rather than trading there. Sweeping first is a fill-semantics change
     * and wants its own decision; see contracts/CLAUDE.md.
     */
    function _process(
        MatchState memory state,
        address pair,
        bool isBid,
        StopLimitOrderbook.ActivatedOrder memory activated,
        uint16 orderHistoryId
    ) private {
        if (activated.expired) {
            emit OrderExpired(
                pair, activated.stopOrderId, activated.owner, isBid, true,
                activated.isMarket, activated.deadline, activated.depositAmount
            );
            return;
        }
        if (activated.isMarket) {
            emit StopOrderActivated(
                pair, activated.stopOrderId, activated.owner, isBid, true, activated.limitPrice, 0
            );
            _executeMarket(
                pair, isBid, activated, state.maxMatches,
                isBid ? state.buySpread : state.sellSpread, orderHistoryId
            );
            return;
        }
        uint256 price = _restingPrice(state.engine, pair, isBid, activated.limitPrice);
        (uint32 id, bool foundDmt) = isBid
            ? IOrderbook(pair).placeBid(activated.owner, price, activated.depositAmount, activated.deadline)
            : IOrderbook(pair).placeAsk(activated.owner, price, activated.depositAmount, activated.deadline);
        // The price the order is ACTUALLY at, not the one it asked for. The field names
        // the placed order, and emitting a price it is not resting at would be a lie an
        // indexer has no way to detect.
        emit StopOrderActivated(
            pair, activated.stopOrderId, activated.owner, isBid, false, price, id
        );
        if (foundDmt) {
            ExchangeOrderbook.Order memory dormant = IOrderbook(pair).removeDmt(isBid);
            emit OrderCanceled(pair, id, isBid, dormant.owner, dormant.depositAmount);
        }
    }

    /// The same rule `MatchingEngine._detLimitBuyMakePrice` applies, against a book read
    /// fresh: `Orderbook._place` clears its own side's empty head and the opposite side
    /// was cleared by the matching pass, so these heads are at least as current as the
    /// ones the ordinary make path uses.
    function _restingPrice(address engine, address pair, bool isBid, uint256 limitPrice)
        private view returns (uint256)
    {
        (uint256 bidHead, uint256 askHead) = IOrderbook(pair).heads();
        uint256 lmp = IOrderbook(pair).lmp();
        uint32 spread = IMatchingEngine(engine).getSpread(pair, isBid, false);
        return isBid
            ? MarketMakePriceLib.limitBuy(lmp, limitPrice, bidHead, askHead, spread)
            : MarketMakePriceLib.limitSell(lmp, limitPrice, bidHead, askHead, spread);
    }

    function _executeMarket(
        address pair,
        bool isBid,
        StopLimitOrderbook.ActivatedOrder memory activated,
        uint32 maxMatches,
        uint32 configuredSpread,
        uint16 orderHistoryId
    ) private {
        uint32 spread = activated.slippageLimit > configuredSpread
            ? configuredSpread
            : activated.slippageLimit;
        uint256 lmp = IOrderbook(pair).lmp();
        uint256 executionLimit = isBid
            ? (lmp * (DENOM + uint256(spread))) / DENOM
            : (lmp * (DENOM - uint256(spread))) / DENOM;
        (address base, address quote) = IOrderbook(pair).getBaseQuote();
        MatchingLib.LimitOrderInput memory marketInput = MatchingLib.LimitOrderInput(
            pair, activated.depositAmount, isBid ? quote : base, activated.owner,
            isBid, executionLimit, activated.maxMatches, orderHistoryId
        );
        (uint256 remaining,,,) = MatchingLib.limitOrder(marketInput, maxMatches);
        if (remaining != 0) TransferHelper.safeTransfer(isBid ? quote : base, activated.owner, remaining);
        emit StopMarketOrderExecuted(
            pair, activated.stopOrderId, activated.owner, isBid, activated.depositAmount, remaining
        );
    }
}
