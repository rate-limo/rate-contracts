// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {NFTAsset} from "../NFTAsset.sol";
import {NFTReceiver} from "../NFTReceiver.sol";

contract NFTBarterMatchingEngine is ReentrancyGuard, NFTReceiver {
    struct Offer {
        address maker;
        NFTAsset.Item offered;
        NFTAsset.Item wanted;
        uint64 expiry;
        bool active;
    }

    uint256 public nextOfferId = 1;
    mapping(uint256 => Offer) public offers;

    /* One cause per revert, so the wallet's toast can name it. A barter offer has two
       distinct ways to be malformed and they need different answers from the user. */
    error ExpiryNotInFuture(uint64 expiry, uint64 timestamp);
    error OfferedIsWanted(address token, uint256 tokenId);
    error NotMaker(uint256 offerId, address caller, address maker);
    error Inactive(uint256 offerId);
    error Expired(uint256 offerId, uint64 expiry);
    error NotExpired(uint256 offerId, uint64 expiry);

    event OfferCreated(uint256 indexed offerId, address indexed maker, address offeredToken, uint256 offeredId, uint256 offeredAmount, address wantedToken, uint256 wantedId, uint256 wantedAmount, uint64 expiry);
    event OfferFilled(uint256 indexed offerId, address indexed taker);
    event OfferCancelled(uint256 indexed offerId);
    event OfferExpired(uint256 indexed offerId);

    function createOffer(NFTAsset.Item calldata offered, NFTAsset.Item calldata wanted, uint64 expiry)
        external nonReentrant returns (uint256 offerId)
    {
        NFTAsset.Item memory offeredCopy = offered;
        NFTAsset.Item memory wantedCopy = wanted;
        NFTAsset.validate(offeredCopy);
        NFTAsset.validate(wantedCopy);
        if (expiry <= block.timestamp) revert ExpiryNotInFuture(expiry, uint64(block.timestamp));
        if (offered.token == wanted.token && offered.tokenId == wanted.tokenId) {
            revert OfferedIsWanted(offered.token, offered.tokenId);
        }
        _pullNFT(offeredCopy, msg.sender, address(this));
        offerId = nextOfferId++;
        offers[offerId] = Offer(msg.sender, offered, wanted, expiry, true);
        emit OfferCreated(offerId, msg.sender, offered.token, offered.tokenId, offered.amount, wanted.token, wanted.tokenId, wanted.amount, expiry);
    }

    function acceptOffer(uint256 offerId) external nonReentrant {
        Offer storage offer = _open(offerId);
        offer.active = false;
        _pullNFT(offer.wanted, msg.sender, address(this));
        _pushNFT(offer.offered, msg.sender);
        _pushNFT(offer.wanted, offer.maker);
        emit OfferFilled(offerId, msg.sender);
    }

    function cancel(uint256 offerId) external nonReentrant {
        Offer storage offer = _open(offerId);
        if (offer.maker != msg.sender) revert NotMaker(offerId, msg.sender, offer.maker);
        offer.active = false;
        _pushNFT(offer.offered, offer.maker);
        emit OfferCancelled(offerId);
    }

    function expire(uint256 offerId) external nonReentrant {
        Offer storage offer = _open(offerId);
        if (block.timestamp < offer.expiry) revert NotExpired(offerId, offer.expiry);
        offer.active = false;
        _pushNFT(offer.offered, offer.maker);
        emit OfferExpired(offerId);
    }

    function _open(uint256 offerId) internal view returns (Offer storage offer) {
        offer = offers[offerId];
        if (!offer.active) revert Inactive(offerId);
        if (block.timestamp >= offer.expiry) revert Expired(offerId, offer.expiry);
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
