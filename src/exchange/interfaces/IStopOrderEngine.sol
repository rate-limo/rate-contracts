// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IStopOrderEngine {
    struct MatchRequest {
        address pair;
        address give;
        address recipient;
        bool isBid;
        uint256 amount;
        uint256 total;
        uint256 limitPrice;
        uint256 bidHead;
        uint256 askHead;
        uint32 used;
        uint32 n;
        uint16 orderHistoryId;
    }

    function createBook(address pair, address base, address quote) external returns (address stopBook);

    function matchRemainder(MatchRequest calldata request)
        external returns (uint256 remaining, uint256 bidHead, uint256 askHead);
}
