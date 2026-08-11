// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ExchangeLinkedList} from "../libraries/ExchangeLinkedList.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";
import {Initializable} from "../../security/Initializable.sol";

/// @notice Custody and trigger queue for stop-limit orders belonging to one pair.
/// Orders are deliberately kept outside Orderbook until their stop is crossed.
contract StopLimitOrderbook is Initializable {
    using ExchangeLinkedList for ExchangeLinkedList.PriceLinkedList;

    struct StopOrder {
        address owner;
        uint256 stopPrice;
        uint256 limitPrice;
        uint256 depositAmount;
        uint32 maxMatches;
        uint32 slippageLimit;
        uint64 deadline;
        bool isMarket;
    }

    struct ActivatedOrder {
        uint32 stopOrderId;
        address owner;
        uint256 limitPrice;
        uint256 depositAmount;
        uint32 maxMatches;
        uint32 slippageLimit;
        uint64 deadline;
        bool isMarket;
        bool expired;
    }

    address public engine;
    address public orderbook;
    address public base;
    address public quote;

    ExchangeLinkedList.PriceLinkedList private triggerPrices;
    mapping(bool => mapping(uint32 => StopOrder)) private orders;
    mapping(bool => mapping(uint256 => uint32)) private heads;
    mapping(bool => mapping(uint256 => uint32)) private tails;
    mapping(bool => mapping(uint256 => mapping(uint32 => uint32))) private nextIds;
    mapping(bool => uint32) private nextOrderIds;

    error InvalidAccess(address sender, address allowed);
    error InvalidOwner(address sender, address owner);
    error InvalidPrice(uint256 stopPrice, uint256 limitPrice);
    error InvalidAmount(uint256 amount);
    error OrderIdOverflow(bool isBid);

    modifier onlyEngine() {
        if (msg.sender != engine) revert InvalidAccess(msg.sender, engine);
        _;
    }

    function initialize(address engine_, address orderbook_, address base_, address quote_) external initializer {
        engine = engine_;
        orderbook = orderbook_;
        base = base_;
        quote = quote_;
    }

    function place(
        address owner,
        bool isBid,
        uint256 stopPrice,
        uint256 limitPrice,
        uint256 amount,
        bool isMarket,
        uint32 slippageLimit,
        uint32 maxMatches,
        uint64 deadline
    )
        external onlyEngine returns (uint32 id)
    {
        if (stopPrice == 0 || (!isMarket && limitPrice == 0)) revert InvalidPrice(stopPrice, limitPrice);
        if (amount == 0) revert InvalidAmount(amount);
        id = nextOrderIds[isBid] + 1;
        if (id == 0) revert OrderIdOverflow(isBid);
        nextOrderIds[isBid] = id;
        orders[isBid][id] = StopOrder(
            owner, stopPrice, limitPrice, amount, maxMatches, slippageLimit, deadline, isMarket
        );

        uint32 tail = tails[isBid][stopPrice];
        if (tail == 0) {
            heads[isBid][stopPrice] = id;
            // Buy stops trigger upward: lowest threshold first. Sell stops trigger
            // downward: highest threshold first.
            triggerPrices._insert(!isBid, stopPrice);
        } else {
            nextIds[isBid][stopPrice][tail] = id;
        }
        tails[isBid][stopPrice] = id;
    }

    function cancel(bool isBid, uint32 id, address owner) external onlyEngine returns (uint256 refunded) {
        StopOrder memory order = orders[isBid][id];
        if (order.owner != owner) revert InvalidOwner(owner, order.owner);
        refunded = order.depositAmount;
        _remove(isBid, id, order.stopPrice);
        TransferHelper.safeTransfer(isBid ? quote : base, owner, refunded);
    }

    /// @dev Removes up to maxOrders crossed stops and transfers their custody to
    /// the regular Orderbook. MatchingEngine inserts them there immediately.
    function activate(bool isBid, uint256 lmp, uint32 maxOrders)
        external onlyEngine returns (ActivatedOrder[] memory activated)
    {
        activated = new ActivatedOrder[](maxOrders);
        uint32 count;
        while (count < maxOrders) {
            uint256 stopPrice = isBid ? triggerPrices.askHead : triggerPrices.bidHead;
            bool crossed = stopPrice != 0 && (isBid ? lmp >= stopPrice : lmp <= stopPrice);
            if (!crossed) break;
            uint32 id = heads[isBid][stopPrice];
            StopOrder memory order = orders[isBid][id];
            bool expired = order.deadline != 0 && block.timestamp > order.deadline;
            activated[count++] = ActivatedOrder(
                id,
                order.owner,
                order.limitPrice,
                order.depositAmount,
                order.maxMatches,
                order.slippageLimit,
                order.deadline,
                order.isMarket,
                expired
            );
            _removeHead(isBid, id, stopPrice);
            TransferHelper.safeTransfer(isBid ? quote : base, expired ? order.owner : (order.isMarket ? engine : orderbook), order.depositAmount);
        }
        assembly { mstore(activated, count) }
    }

    function expire(bool isBid, uint32 id)
        external onlyEngine returns (address owner, uint256 refunded, uint64 deadline, bool isMarket)
    {
        StopOrder memory order = orders[isBid][id];
        if (order.deadline == 0 || block.timestamp <= order.deadline) revert InvalidAmount(order.deadline);
        _remove(isBid, id, order.stopPrice);
        TransferHelper.safeTransfer(isBid ? quote : base, order.owner, order.depositAmount);
        return (order.owner, order.depositAmount, order.deadline, order.isMarket);
    }

    function getOrder(bool isBid, uint32 id) external view returns (StopOrder memory) {
        return orders[isBid][id];
    }

    function triggerHead(bool isBid) external view returns (uint256) {
        return isBid ? triggerPrices.askHead : triggerPrices.bidHead;
    }

    function _removeHead(bool isBid, uint32 id, uint256 stopPrice) private {
        uint32 next = nextIds[isBid][stopPrice][id];
        heads[isBid][stopPrice] = next;
        delete nextIds[isBid][stopPrice][id];
        if (next == 0) {
            tails[isBid][stopPrice] = 0;
            triggerPrices._delete(!isBid, stopPrice);
        }
        delete orders[isBid][id];
    }

    function _remove(bool isBid, uint32 id, uint256 stopPrice) private {
        uint32 current = heads[isBid][stopPrice];
        uint32 previous;
        while (current != id) {
            previous = current;
            current = nextIds[isBid][stopPrice][current];
        }
        uint32 next = nextIds[isBid][stopPrice][id];
        if (previous == 0) heads[isBid][stopPrice] = next;
        else nextIds[isBid][stopPrice][previous] = next;
        if (tails[isBid][stopPrice] == id) tails[isBid][stopPrice] = previous;
        delete nextIds[isBid][stopPrice][id];
        delete orders[isBid][id];
        if (heads[isBid][stopPrice] == 0) triggerPrices._delete(!isBid, stopPrice);
    }
}
