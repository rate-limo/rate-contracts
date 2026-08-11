// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IOrderbook} from "../interfaces/IOrderbook.sol";
import {IMatchingEngine} from "../interfaces/IMatchingEngine.sol";
import {StopLimitOrderbook} from "../orderbooks/StopLimitOrderbook.sol";
import {ExchangeOrderbook} from "./ExchangeOrderbook.sol";
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

    function matchRemainder(MatchingLib.LimitOrderInput memory input, MatchState memory state)
        public returns (uint256, uint256, uint256)
    {
        if (state.stopBook == address(0)) return (state.remaining, state.bidHead, state.askHead);
        // `n` is shared across the regular and stop books. A regular-book match
        // consumes one slot, and stop orders must not even activate once all
        // slots have been consumed.
        if (state.used >= input.n) return (state.remaining, state.bidHead, state.askHead);
        uint32 activationBudget = input.n - state.used;
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
            _process(
                pair, restingIsBid, activated[i], state.maxMatches,
                state.buySpread, state.sellSpread, orderHistoryId
            );
        }
    }

    function _process(
        address pair,
        bool isBid,
        StopLimitOrderbook.ActivatedOrder memory activated,
        uint32 maxMatches,
        uint32 buySpread,
        uint32 sellSpread,
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
                pair, isBid, activated, maxMatches,
                isBid ? buySpread : sellSpread, orderHistoryId
            );
            return;
        }
        (uint32 id, bool foundDmt) = isBid
            ? IOrderbook(pair).placeBid(activated.owner, activated.limitPrice, activated.depositAmount, activated.deadline)
            : IOrderbook(pair).placeAsk(activated.owner, activated.limitPrice, activated.depositAmount, activated.deadline);
        emit StopOrderActivated(
            pair, activated.stopOrderId, activated.owner, isBid, false, activated.limitPrice, id
        );
        if (foundDmt) {
            ExchangeOrderbook.Order memory dormant = IOrderbook(pair).removeDmt(isBid);
            emit OrderCanceled(pair, id, isBid, dormant.owner, dormant.depositAmount);
        }
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
