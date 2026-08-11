// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IStopOrderEngine} from "../interfaces/IStopOrderEngine.sol";
import {MatchingLib} from "./MatchingLib.sol";
import {TransferHelper} from "./TransferHelper.sol";

library StopOrderHandoffLib {
    function handoff(
        address stopOrderEngine,
        MatchingLib.LimitOrderInput memory input,
        uint256 remaining,
        uint256 bidHead,
        uint256 askHead,
        uint32 used
    ) public returns (uint256, uint256, uint256) {
        if (stopOrderEngine == address(0)) return (remaining, bidHead, askHead);
        if (remaining != 0) TransferHelper.safeTransfer(input.give, stopOrderEngine, remaining);
        IStopOrderEngine.MatchRequest memory request = IStopOrderEngine.MatchRequest({
            pair: input.pair,
            give: input.give,
            recipient: input.recipient,
            isBid: input.isBid,
            amount: remaining,
            total: input.amount,
            limitPrice: input.limitPrice,
            bidHead: bidHead,
            askHead: askHead,
            used: used,
            n: input.n,
            orderHistoryId: input.orderHistoryId
        });
        return IStopOrderEngine(stopOrderEngine).matchRemainder(request);
    }
}
