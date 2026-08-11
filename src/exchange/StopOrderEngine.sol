// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOrderbook} from "./interfaces/IOrderbook.sol";
import {IStopOrderEngine} from "./interfaces/IStopOrderEngine.sol";
import {IMatchingEngine} from "./interfaces/IMatchingEngine.sol";
import {StopLimitOrderbook} from "./orderbooks/StopLimitOrderbook.sol";
import {StopLimitOrderbookFactory} from "./orderbooks/StopLimitOrderbookFactory.sol";
import {MatchingLib} from "./libraries/MatchingLib.sol";
import {StopOrderMatchingLib} from "./libraries/StopOrderMatchingLib.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";

interface IMainMatchingEngine {
    function getPair(address base, address quote) external view returns (address);
    function maxMatches() external view returns (uint32);
    function listingDates(address pair) external view returns (uint256);
    function getSpread(address pair, bool isBuy, bool isMkt) external view returns (uint32);
}

contract StopOrderEngine is ReentrancyGuard, IStopOrderEngine {
    uint32 public constant DENOM = 100_000_000;
    address public immutable matchingEngine;
    address public immutable factory;
    mapping(address => address) public stopOrderbooks;

    event StopOrderBookCreated(address indexed pair, address indexed stopOrderbook);
    event StopOrderPlaced(
        address indexed pair, uint32 indexed id, address indexed owner,
        bool isBid, bool isMarket, uint256 stopPrice, uint256 limitPrice,
        uint256 amount, uint32 slippageLimit, uint32 maxOrderMatches, uint64 deadline
    );
    event StopOrderCancelled(
        address indexed pair, uint32 indexed id, address indexed owner,
        bool isBid, bool isMarket, uint256 refunded
    );
    event StopOrderActivated(
        address indexed pair, uint32 indexed id, address indexed owner,
        bool isBid, bool isMarket, uint256 limitPrice, uint32 regularOrderId
    );
    event StopMarketOrderExecuted(
        address indexed pair, uint32 indexed id, address indexed owner,
        bool isBid, uint256 submitted, uint256 refunded
    );
    event OrderCanceled(address pair, uint256 id, bool isBid, address indexed owner, uint256 amount);
    event OrderMatched(
        address pair, uint16 orderHistoryId, uint256 id, bool isBid,
        uint256 price, uint256 total, bool clear, IMatchingEngine.OrderMatch orderMatch
    );
    event OrderDusted(
        address pair, uint16 orderHistoryId, uint256 id, bool isBid,
        uint256 price, address owner, uint256 refunded
    );
    event OrderExpired(
        address indexed pair, uint32 indexed orderId, address indexed owner,
        bool isBid, bool isStop, bool isMarket, uint64 deadline, uint256 refunded
    );
    event NewMarketPrice(address pair, uint256 price, bool isBid);

    error InvalidAccess(address sender, address allowed);
    error PairDoesNotExist(address base, address quote);
    error StopBookDoesNotExist(address pair);
    error StopBookAlreadyExists(address pair, address stopBook);
    error StopAlreadyCrossed(uint256 stopPrice, uint256 lmp, bool isBid);
    error InvalidStopMatchLimit(uint32 requested, uint32 maximum);
    error InvalidStopSlippage(uint32 slippageLimit);
    error PairNotListedYet(address pair, uint256 listingDate, uint256 timeNow);
    error AmountIsZero();
    error InvalidRecipient();
    error OrderSizeTooSmall(uint256 amount, uint256 minimum);
    error DeadlineExpired(uint64 deadline, uint256 timeNow);

    modifier onlyMatchingEngine() {
        if (msg.sender != matchingEngine) revert InvalidAccess(msg.sender, matchingEngine);
        _;
    }

    constructor(address matchingEngine_) {
        matchingEngine = matchingEngine_;
        factory = address(new StopLimitOrderbookFactory(address(this)));
    }

    function createBook(address pair, address base, address quote)
        external onlyMatchingEngine returns (address stopBook)
    {
        address existing = stopOrderbooks[pair];
        if (existing != address(0)) revert StopBookAlreadyExists(pair, existing);
        stopBook = StopLimitOrderbookFactory(factory).create(pair, base, quote);
        stopOrderbooks[pair] = stopBook;
        emit StopOrderBookCreated(pair, stopBook);
    }

    function placeStopLimit(
        address base,
        address quote,
        bool isBid,
        uint256 stopPrice,
        uint256 limitPrice,
        uint256 amount,
        address recipient
    ) external nonReentrant returns (uint32 id) {
        return _placeStopLimit(base, quote, isBid, stopPrice, limitPrice, amount, recipient, 0);
    }

    function placeStopLimit(
        address base, address quote, bool isBid, uint256 stopPrice,
        uint256 limitPrice, uint256 amount, address recipient, uint64 deadline
    ) external nonReentrant returns (uint32 id) {
        return _placeStopLimit(base, quote, isBid, stopPrice, limitPrice, amount, recipient, deadline);
    }

    function _placeStopLimit(
        address base, address quote, bool isBid, uint256 stopPrice,
        uint256 limitPrice, uint256 amount, address recipient, uint64 deadline
    ) private returns (uint32 id) {
        if (recipient == address(0)) revert InvalidRecipient();
        _checkDeadline(deadline);
        (address pair, address stopBook, uint256 lmp) = _validate(base, quote, isBid, stopPrice, limitPrice, amount);
        TransferHelper.safeTransferFrom(isBid ? quote : base, msg.sender, stopBook, amount);
        id = StopLimitOrderbook(stopBook).place(recipient, isBid, stopPrice, limitPrice, amount, false, 0, 0, deadline);
        emit StopOrderPlaced(pair, id, recipient, isBid, false, stopPrice, limitPrice, amount, 0, 0, deadline);
        lmp; // retained in the shared validation return for the market path
    }

    function placeStopMarket(IMatchingEngine.StopMarketInput calldata input)
        external nonReentrant returns (uint32 id)
    {
        if (input.recipient == address(0)) revert InvalidRecipient();
        _checkDeadline(input.deadline);
        uint32 maximum = IMainMatchingEngine(matchingEngine).maxMatches();
        if (input.n == 0 || input.n > maximum) revert InvalidStopMatchLimit(input.n, maximum);
        if (input.slippageLimit >= DENOM) revert InvalidStopSlippage(input.slippageLimit);
        (address pair, address stopBook,) = _validate(
            input.base, input.quote, input.isBid, input.stopPrice, 0, input.amount
        );
        TransferHelper.safeTransferFrom(
            input.isBid ? input.quote : input.base, msg.sender, stopBook, input.amount
        );
        id = StopLimitOrderbook(stopBook).place(
            input.recipient, input.isBid, input.stopPrice, 0, input.amount,
            true, input.slippageLimit, input.n, input.deadline
        );
        emit StopOrderPlaced(
            pair, id, input.recipient, input.isBid, true, input.stopPrice, 0,
            input.amount, input.slippageLimit, input.n, input.deadline
        );
    }

    function expire(address base, address quote, bool isBid, uint32 orderId)
        external nonReentrant returns (uint256 refunded)
    {
        address pair = IMainMatchingEngine(matchingEngine).getPair(base, quote);
        if (pair == address(0)) revert PairDoesNotExist(base, quote);
        address stopBook = stopOrderbooks[pair];
        if (stopBook == address(0)) revert StopBookDoesNotExist(pair);
        (address owner, uint256 amount, uint64 deadline, bool isMarket) =
            StopLimitOrderbook(stopBook).expire(isBid, orderId);
        emit OrderExpired(pair, orderId, owner, isBid, true, isMarket, deadline, amount);
        return amount;
    }

    function cancel(address base, address quote, bool isBid, uint32 orderId)
        external nonReentrant returns (uint256 refunded)
    {
        address pair = IMainMatchingEngine(matchingEngine).getPair(base, quote);
        if (pair == address(0)) revert PairDoesNotExist(base, quote);
        address stopBook = stopOrderbooks[pair];
        if (stopBook == address(0)) revert StopBookDoesNotExist(pair);
        StopLimitOrderbook.StopOrder memory order = StopLimitOrderbook(stopBook).getOrder(isBid, orderId);
        refunded = StopLimitOrderbook(stopBook).cancel(isBid, orderId, msg.sender);
        emit StopOrderCancelled(pair, orderId, msg.sender, isBid, order.isMarket, refunded);
    }

    function getOrder(address base, address quote, bool isBid, uint32 orderId)
        external view returns (StopLimitOrderbook.StopOrder memory)
    {
        address pair = IMainMatchingEngine(matchingEngine).getPair(base, quote);
        if (pair == address(0)) revert PairDoesNotExist(base, quote);
        address stopBook = stopOrderbooks[pair];
        if (stopBook == address(0)) revert StopBookDoesNotExist(pair);
        return StopLimitOrderbook(stopBook).getOrder(isBid, orderId);
    }

    function matchRemainder(MatchRequest calldata request)
        external onlyMatchingEngine returns (uint256 remaining, uint256 bidHead, uint256 askHead)
    {
        MatchingLib.LimitOrderInput memory input = MatchingLib.LimitOrderInput(
            request.pair, request.amount, request.give, request.recipient, request.isBid,
            request.limitPrice, request.n, request.orderHistoryId
        );
        IMainMatchingEngine main = IMainMatchingEngine(matchingEngine);
        StopOrderMatchingLib.MatchState memory state = StopOrderMatchingLib.MatchState(
            stopOrderbooks[request.pair], request.amount, request.bidHead, request.askHead,
            request.used, main.maxMatches(), main.getSpread(request.pair, true, true),
            main.getSpread(request.pair, false, true)
        );
        (remaining, bidHead, askHead) = StopOrderMatchingLib.matchRemainder(input, state);
        if (remaining != 0) TransferHelper.safeTransfer(request.give, matchingEngine, remaining);
    }

    function _validate(
        address base,
        address quote,
        bool isBid,
        uint256 stopPrice,
        uint256 limitPrice,
        uint256 amount
    ) private view returns (address pair, address stopBook, uint256 lmp) {
        if (amount == 0) revert AmountIsZero();
        pair = IMainMatchingEngine(matchingEngine).getPair(base, quote);
        if (pair == address(0)) revert PairDoesNotExist(base, quote);
        uint256 listingDate = IMainMatchingEngine(matchingEngine).listingDates(pair);
        if (listingDate > block.timestamp) revert PairNotListedYet(pair, listingDate, block.timestamp);
        stopBook = stopOrderbooks[pair];
        if (stopBook == address(0)) revert StopBookDoesNotExist(pair);
        lmp = IOrderbook(pair).lmp();
        if ((isBid && stopPrice <= lmp) || (!isBid && stopPrice >= lmp)) {
            revert StopAlreadyCrossed(stopPrice, lmp, isBid);
        }
        uint256 validationPrice = limitPrice == 0 ? lmp : limitPrice;
        uint256 converted = IOrderbook(pair).convert(validationPrice, amount, !isBid);
        uint256 minimum = IOrderbook(pair).convert(validationPrice, 1, !isBid);
        if (converted <= minimum) revert OrderSizeTooSmall(converted, minimum);
    }

    function _checkDeadline(uint64 deadline) private view {
        if (deadline != 0 && block.timestamp > deadline) revert DeadlineExpired(deadline, block.timestamp);
    }
}
