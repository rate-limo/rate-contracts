// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.24;

import {IMatchingEngine, ExchangeOrderbook} from "./IMatchingEngine.sol";

interface IOrderbook {
    function initialize(
        uint256 id_,
        address base_,
        address quote_,
        address engine_,
        ExchangeOrderbook.MatchingMode mode_
    ) external;

    function getMatchingMode() external view returns (ExchangeOrderbook.MatchingMode);

    function setLmp(uint256 price) external;

    /// The price this pair opened the current block at -- the anchor a swap's spread rail
    /// is measured against, so a batch of reports in one block is bounded as a batch.
    function lmpAtBlockOpen() external view returns (uint256);

    function twap(uint32 minSecondsAgo) external view returns (uint256 price, uint32 actualWindow);

    function setPool(address pool_) external;

    function getPool() external view returns (address);

    function placeAsk(address owner, uint256 price, uint256 amount) external returns (uint32 id, bool foundDmt);

    function placeBid(address owner, uint256 price, uint256 amount) external returns (uint32 id, bool foundDmt);

    function removeDmt(bool isBid) external returns (ExchangeOrderbook.Order memory order);

    function cancelOrder(bool isBid, uint32 orderId, address owner) external returns (uint256 remaining);

    /// @return orderMatch the fill's two legs and fees
    /// @return deleted whether the order was removed from the book. NOT the same as
    /// the `clear` argument: the dust closeout in ExchangeOrderbook._decreaseOrder
    /// removes an order the caller believed was partially filled, and callers must
    /// emit THIS, not their own `clear`.
    function execute(uint32 orderId, bool isBid, address sender, uint256 amount, bool clear)
        external
        returns (IMatchingEngine.OrderMatch memory orderMatch, bool deleted);

    function clearEmptyHead(bool isBid) external returns (uint256 head);

    /// @return orderId the head order at this price
    /// @return required how much of the taker's remaining this order needs to clear
    /// @return clear whether the order was taken off the queue by this call
    /// @return dustOwner nonzero only when this call deleted-and-refunded an order
    /// whose deposit converts to zero; the caller must emit that removal
    /// @return dustRefund the amount returned to `dustOwner`
    function fpop(bool isBid, uint256 price, uint256 remaining)
        external
        returns (uint32 orderId, uint256 required, bool clear, address dustOwner, uint256 dustRefund);

    function getRequired(bool isBid, uint256 price, uint32 orderId) external view returns (uint256 required);

    function lmp() external view returns (uint256);

    function heads() external view returns (uint256, uint256);

    function askHead() external view returns (uint256);

    function bidHead() external view returns (uint256);

    function orderHead(bool isBid, uint256 price) external view returns (uint32);

    function mktPrice() external view returns (uint256);

    function getPrices(bool isBid, uint32 n) external view returns (uint256[] memory);

    function nextPrice(bool isBid, uint256 price) external view returns (uint256 next);

    function nextOrder(bool isBid, uint256 price, uint32 orderId) external view returns (uint32 next);

    function sfpop(bool isBid, uint256 price, uint32 orderId, bool isHead)
        external
        view
        returns (uint32 id, uint256 required, bool clear);

    function getPricesPaginated(bool isBid, uint32 start, uint32 end) external view returns (uint256[] memory);

    function getOrderIds(bool isBid, uint256 price, uint32 n) external view returns (uint32[] memory);

    function getOrders(bool isBid, uint256 price, uint32 n) external view returns (ExchangeOrderbook.Order[] memory);

    function getOrdersPaginated(bool isBid, uint256 price, uint32 start, uint32 end)
        external
        view
        returns (ExchangeOrderbook.Order[] memory);

    function getOrder(bool isBid, uint32 orderId) external view returns (ExchangeOrderbook.Order memory);

    function getBaseQuote() external view returns (address base, address quote);

    function assetValue(uint256 amount, bool isBid) external view returns (uint256 converted);

    function nextMakeId(bool isBid) external view returns (uint32);

    function isEmpty(bool isBid, uint256 price) external view returns (bool);

    function convertMarket(uint256 amount, bool isBid) external view returns (uint256 converted);

    function convert(uint256 price, uint256 amount, bool isBid) external view returns (uint256 converted);
}
