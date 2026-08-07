// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC1155Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {IPool} from "./interfaces/IPool.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";

contract PositionManager is IPositionManager, ERC1155Upgradeable, OwnableUpgradeable {
    struct TokenPosition {
        address pool;
        uint256 positionId;
    }

    mapping(uint256 => TokenPosition) internal _tokenPositions;
    // ERC1155 has no per-id owner (only per-id, per-address balances), so adjustPosition's
    // "who do I pull/refund principal against" and onlyOwnerOrApproved's isApprovedForAll check
    // both need a tracked holder. Kept in sync by _update below; every position mints/burns
    // exactly amount=1, so "the holder" is unambiguous for as long as the id is live.
    mapping(uint256 => address) internal _holder;
    uint256 public nextTokenId;
    address public poolFactory;
    // The one SwapRouter (or other trusted forwarder) allowed to call *For functions on behalf
    // of a caller it reports itself -- see removeLiquidityFor. Unset (address(0)) by default, so
    // no address can ever satisfy onlyRouter until the owner explicitly wires one up.
    address public router;

    modifier onlyOwnerOrApproved(uint256 tokenId) {
        if (!_isOwnerOrApproved(msg.sender, tokenId)) {
            revert NotOwnerOrApproved(tokenId, msg.sender);
        }
        _;
    }

    modifier onlyRouter() {
        if (msg.sender != router) {
            revert NotRouter(msg.sender);
        }
        _;
    }

    function _isOwnerOrApproved(address caller, uint256 tokenId) private view returns (bool) {
        return balanceOf(caller, tokenId) > 0 || isApprovedForAll(_holder[tokenId], caller);
    }

    function initialize(string memory uri_) external initializer {
        __ERC1155_init(uri_);
        __Ownable_init(msg.sender);
    }

    function setPoolFactory(address poolFactory_) external onlyOwner {
        poolFactory = poolFactory_;
    }

    function setRouter(address router_) external onlyOwner {
        router = router_;
    }

    function addLiquidity(
        address pool,
        uint256 minPrice,
        uint256 maxPrice,
        uint32 slippageLimit,
        uint256 baseAmount,
        uint256 quoteAmount
    ) external returns (uint256 tokenId) {
        uint256 positionId =
            IPool(pool).addLiquidity(minPrice, maxPrice, slippageLimit, baseAmount, quoteAmount, msg.sender);

        tokenId = ++nextTokenId;
        _tokenPositions[tokenId] = TokenPosition({pool: pool, positionId: positionId});
        _mint(msg.sender, tokenId, 1, "");

        emit LiquidityAdded(pool, tokenId, msg.sender, positionId, minPrice, maxPrice, slippageLimit, baseAmount, quoteAmount);
    }

    function adjustPosition(
        uint256 tokenId,
        uint256 newMinPrice,
        uint256 newMaxPrice,
        uint32 newSlippageLimit,
        uint256 newBaseAmount,
        uint256 newQuoteAmount
    ) external onlyOwnerOrApproved(tokenId) {
        TokenPosition storage tp = _tokenPositions[tokenId];
        address pool = tp.pool;
        uint256 oldPositionId = tp.positionId;
        address owner = _holder[tokenId];

        // I2: the old position may already be retired (fully drained + fees collected)
        // -- Pool.collect/removeLiquidity revert PositionDoesNotExist on a retired id, so
        // only settle what is actually still live. Read the position FIRST: collect only
        // zeroes fees, never balances, so the amounts read here are unaffected by the
        // collect below. When the old position is retired, oldP's amounts are zero and
        // the pull/refund arithmetic further down degenerates correctly to "pull the full
        // new amounts from the owner".
        IPool.Position memory oldP = IPool(pool).getPosition(oldPositionId);
        if (oldP.active) {
            // Settle fees owed under the old range first.
            IPool(pool).collect(oldPositionId, owner);

            // Remove all remaining principal from the old range, sending it to this
            // contract so it can be re-supplied to the new range without an extra
            // external transfer round-trip through the NFT owner.
            if (oldP.baseAmount > 0 || oldP.quoteAmount > 0) {
                IPool(pool).removeLiquidity(oldPositionId, oldP.baseAmount, oldP.quoteAmount, address(this));
            }
        }

        (address base, address quote) = IPool(pool).getBaseQuote();
        // Pull whatever additional amount is needed beyond what the old range's withdrawal
        // already provided, from the NFT owner (who must have approved this contract for it
        // beforehand, same as any addLiquidity call).
        if (newBaseAmount > oldP.baseAmount) {
            TransferHelper.safeTransferFrom(base, owner, address(this), newBaseAmount - oldP.baseAmount);
        }
        if (newQuoteAmount > oldP.quoteAmount) {
            TransferHelper.safeTransferFrom(quote, owner, address(this), newQuoteAmount - oldP.quoteAmount);
        }
        // Symmetric case: shrinking a position (newAmount < old). The old range's full
        // withdrawal above already brought oldP.baseAmount/oldP.quoteAmount into this
        // contract, but the new range only spends newBaseAmount/newQuoteAmount of it --
        // refund the difference to the owner now, or it silently strands in this contract
        // forever (found before implementation: the growth-only pull above has no symmetric
        // counterpart without this).
        if (oldP.baseAmount > newBaseAmount) {
            TransferHelper.safeTransfer(base, owner, oldP.baseAmount - newBaseAmount);
        }
        if (oldP.quoteAmount > newQuoteAmount) {
            TransferHelper.safeTransfer(quote, owner, oldP.quoteAmount - newQuoteAmount);
        }
        if (newBaseAmount > 0) TransferHelper.safeApprove(base, pool, newBaseAmount);
        if (newQuoteAmount > 0) TransferHelper.safeApprove(quote, pool, newQuoteAmount);

        uint256 newPositionId = IPool(pool).addLiquidity(
            newMinPrice, newMaxPrice, newSlippageLimit, newBaseAmount, newQuoteAmount, address(this)
        );

        tp.positionId = newPositionId;

        _emitPositionAdjusted(tokenId, oldPositionId);
    }

    // Split out purely for stack depth (same pattern as SwapRouter._emitLiquidityAdded), and taken
    // one step further: adjustPosition's stack is so full that even forwarding the new range/amount
    // args overflows it, so everything is re-derived here -- tp.positionId was just updated (it IS
    // the new position id), and the new range/amounts are read back from the Pool's own record,
    // which is authoritative anyway.
    function _emitPositionAdjusted(uint256 tokenId, uint256 oldPositionId) private {
        TokenPosition storage tp = _tokenPositions[tokenId];
        IPool.Position memory p = IPool(tp.pool).getPosition(tp.positionId);
        emit PositionAdjusted(
            tp.pool, tokenId, oldPositionId, tp.positionId, p.minPrice, p.maxPrice, p.slippageLimit, p.baseAmount, p.quoteAmount
        );
    }

    function removeLiquidity(uint256 tokenId, uint256 baseAmount, uint256 quoteAmount, address recipient)
        external
        onlyOwnerOrApproved(tokenId)
    {
        TokenPosition memory tp = _tokenPositions[tokenId];
        IPool(tp.pool).removeLiquidity(tp.positionId, baseAmount, quoteAmount, recipient);

        emit LiquidityRemoved(tp.pool, tokenId, recipient, tp.positionId, baseAmount, quoteAmount);
    }

    // `caller` is trusted only because this function is gated onlyRouter -- msg.sender here is
    // always the router itself (never the real end user), so the owner-or-approved check has to
    // run against the caller the router reports, not msg.sender. This is safe precisely because
    // only the one address the owner wired up via setRouter can invoke it, and SwapRouter's own
    // implementation always passes its own msg.sender, never a caller-supplied address.
    function removeLiquidityFor(
        address caller,
        uint256 tokenId,
        uint256 baseAmount,
        uint256 quoteAmount,
        address recipient
    ) external onlyRouter {
        if (!_isOwnerOrApproved(caller, tokenId)) {
            revert NotOwnerOrApproved(tokenId, caller);
        }
        TokenPosition memory tp = _tokenPositions[tokenId];
        IPool(tp.pool).removeLiquidity(tp.positionId, baseAmount, quoteAmount, recipient);

        emit LiquidityRemoved(tp.pool, tokenId, recipient, tp.positionId, baseAmount, quoteAmount);
    }

    function collect(uint256 tokenId, address recipient)
        external
        onlyOwnerOrApproved(tokenId)
        returns (uint256 baseFee, uint256 quoteFee)
    {
        TokenPosition memory tp = _tokenPositions[tokenId];
        return IPool(tp.pool).collect(tp.positionId, recipient);
    }

    function burn(uint256 tokenId) external onlyOwnerOrApproved(tokenId) {
        TokenPosition memory tp = _tokenPositions[tokenId];
        IPool.Position memory p = IPool(tp.pool).getPosition(tp.positionId);
        if (p.baseAmount > 0 || p.quoteAmount > 0 || p.feeOwedBase > 0 || p.feeOwedQuote > 0) {
            revert PositionNotEmpty(tokenId);
        }
        address holder = _holder[tokenId];
        delete _tokenPositions[tokenId];
        _burn(holder, tokenId, 1);
    }

    function tokenPosition(uint256 tokenId) external view returns (address pool, uint256 positionId) {
        TokenPosition memory tp = _tokenPositions[tokenId];
        return (tp.pool, tp.positionId);
    }

    // Keeps _holder in sync across mint/transfer/batch-transfer/burn -- every position id is
    // always minted/burned with amount=1 and never split, so "the holder of ids[i]" stays
    // unambiguous. `to == address(0)` is a burn; every other `to` (including batch transfers)
    // is the id's new holder.
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        super._update(from, to, ids, values);
        for (uint256 i = 0; i < ids.length; i++) {
            if (to == address(0)) {
                delete _holder[ids[i]];
            } else {
                _holder[ids[i]] = to;
            }
        }
    }
}
