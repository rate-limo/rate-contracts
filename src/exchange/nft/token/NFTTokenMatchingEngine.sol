// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {NFTAsset} from "../NFTAsset.sol";
import {NFTReceiver} from "../NFTReceiver.sol";

contract NFTTokenMatchingEngine is ReentrancyGuard, NFTReceiver {
    using SafeERC20 for IERC20;

    enum Side { Ask, Bid }
    struct Order {
        address maker;
        NFTAsset.Item asset;
        address quoteToken;
        uint256 quoteAmount;
        Side side;
        uint64 expiry;
        bool active;
    }

    uint256 public nextOrderId = 1;
    mapping(uint256 => Order) public orders;

    /* Each revert names one cause. `InvalidOrder()` used to cover four of them, which is
       fine for a require-string and useless for the toast a wallet renders: "invalid order"
       cannot tell someone they set an expiry in the past. */
    error ZeroQuoteToken();
    error ZeroQuoteAmount();
    error ExpiryNotInFuture(uint64 expiry, uint64 timestamp);
    error WrongSide(uint256 orderId, Side expected, Side actual);
    error NotMaker(uint256 orderId, address caller, address maker);
    error Inactive(uint256 orderId);
    error Expired(uint256 orderId, uint64 expiry);
    error NotExpired(uint256 orderId, uint64 expiry);

    event OrderCreated(uint256 indexed orderId, address indexed maker, Side side, address nft, uint256 tokenId, uint256 amount, address quoteToken, uint256 quoteAmount, uint64 expiry);
    event OrderFilled(uint256 indexed orderId, address indexed taker);
    event OrderCancelled(uint256 indexed orderId);
    event OrderExpired(uint256 indexed orderId);

    function createAsk(NFTAsset.Item calldata asset, address quoteToken, uint256 quoteAmount, uint64 expiry)
        external nonReentrant returns (uint256 orderId)
    {
        _validate(asset, quoteToken, quoteAmount, expiry);
        _pullNFT(asset, msg.sender, address(this));
        orderId = nextOrderId++;
        orders[orderId] = Order(msg.sender, asset, quoteToken, quoteAmount, Side.Ask, expiry, true);
        emit OrderCreated(orderId, msg.sender, Side.Ask, asset.token, asset.tokenId, asset.amount, quoteToken, quoteAmount, expiry);
    }

    function createBid(NFTAsset.Item calldata asset, address quoteToken, uint256 quoteAmount, uint64 expiry)
        external nonReentrant returns (uint256 orderId)
    {
        _validate(asset, quoteToken, quoteAmount, expiry);
        IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), quoteAmount);
        orderId = nextOrderId++;
        orders[orderId] = Order(msg.sender, asset, quoteToken, quoteAmount, Side.Bid, expiry, true);
        emit OrderCreated(orderId, msg.sender, Side.Bid, asset.token, asset.tokenId, asset.amount, quoteToken, quoteAmount, expiry);
    }

    function buy(uint256 orderId) external nonReentrant {
        Order storage order = _open(orderId);
        if (order.side != Side.Ask) revert WrongSide(orderId, Side.Ask, order.side);
        order.active = false;
        IERC20(order.quoteToken).safeTransferFrom(msg.sender, order.maker, order.quoteAmount);
        _pushNFT(order.asset, msg.sender);
        emit OrderFilled(orderId, msg.sender);
    }

    function acceptBid(uint256 orderId) external nonReentrant {
        Order storage order = _open(orderId);
        if (order.side != Side.Bid) revert WrongSide(orderId, Side.Bid, order.side);
        order.active = false;
        _pullNFT(order.asset, msg.sender, address(this));
        IERC20(order.quoteToken).safeTransfer(msg.sender, order.quoteAmount);
        _pushNFT(order.asset, order.maker);
        emit OrderFilled(orderId, msg.sender);
    }

    function cancel(uint256 orderId) external nonReentrant {
        Order storage order = _open(orderId);
        if (order.maker != msg.sender) revert NotMaker(orderId, msg.sender, order.maker);
        order.active = false;
        if (order.side == Side.Ask) _pushNFT(order.asset, order.maker);
        else IERC20(order.quoteToken).safeTransfer(order.maker, order.quoteAmount);
        emit OrderCancelled(orderId);
    }

    function expire(uint256 orderId) external nonReentrant {
        Order storage order = _open(orderId);
        if (block.timestamp < order.expiry) revert NotExpired(orderId, order.expiry);
        order.active = false;
        if (order.side == Side.Ask) _pushNFT(order.asset, order.maker);
        else IERC20(order.quoteToken).safeTransfer(order.maker, order.quoteAmount);
        emit OrderExpired(orderId);
    }

    function _open(uint256 orderId) internal view returns (Order storage order) {
        order = orders[orderId];
        if (!order.active) revert Inactive(orderId);
        if (block.timestamp >= order.expiry) revert Expired(orderId, order.expiry);
    }

    function _validate(NFTAsset.Item calldata asset, address quoteToken, uint256 quoteAmount, uint64 expiry) internal view {
        NFTAsset.Item memory copy = asset;
        NFTAsset.validate(copy);
        if (quoteToken == address(0)) revert ZeroQuoteToken();
        if (quoteAmount == 0) revert ZeroQuoteAmount();
        if (expiry <= block.timestamp) revert ExpiryNotInFuture(expiry, uint64(block.timestamp));
    }

    function _pullNFT(NFTAsset.Item memory asset, address from, address to) internal {
        if (asset.standard == NFTAsset.Standard.ERC721) IERC721(asset.token).safeTransferFrom(from, to, asset.tokenId);
        else IERC1155(asset.token).safeTransferFrom(from, to, asset.tokenId, asset.amount, "");
    }

    function _pushNFT(NFTAsset.Item memory asset, address to) internal {
        if (asset.standard == NFTAsset.Standard.ERC721) IERC721(asset.token).safeTransferFrom(address(this), to, asset.tokenId);
        else IERC1155(asset.token).safeTransferFrom(address(this), to, asset.tokenId, asset.amount, "");
    }
}
