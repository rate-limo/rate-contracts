// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ISwapRouter} from "./interfaces/ISwapRouter.sol";
import {IPool} from "./interfaces/IPool.sol";
import {IPoolFactory} from "./interfaces/IPoolFactory.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {IMatchingEngine} from "../exchange/interfaces/IMatchingEngine.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

contract SwapRouter is ISwapRouter {
    address public immutable poolFactory;

    // Matches per resting/crossing attempt when disposing of a remainder via RestAsOrder --
    // this is a fresh small order, not a swap leg, so it never needs MAX_POSITIONS_PER_SWAP's
    // headroom (Pool.sol:29).
    uint32 private constant REMAINDER_MATCH_CAP = 5;

    constructor(address poolFactory_) {
        poolFactory = poolFactory_;
    }

    /// @inheritdoc ISwapRouter
    function swap(
        address[] calldata path,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        RemainderMode remainderMode,
        RemainderConfig calldata remainderConfig
    ) external override returns (uint256 amountOut) {
        TransferHelper.safeTransferFrom(path[0], msg.sender, address(this), amountIn);

        uint256 currentAmountIn = amountIn;

        for (uint256 i = 0; i < path.length - 1; i++) {
            // Every hop's matched output stays with the router (address(this)) so it can feed
            // the next hop, and every hop always lets Pool.swap refund its own leftover back to
            // the router too (isMaker=false) -- Pool.swap's single `recipient` argument governs
            // both the matched output AND any rested remainder, so there is no way to send the
            // match to the router while resting the remainder for the end user in one call.
            // Capturing the remainder here instead, then dispositioning it ourselves against
            // `recipient`, is what makes a per-hop, uniform three-option choice possible at all.
            uint256 hopLeftover;
            (currentAmountIn, hopLeftover) = _executeHop(path[i], path[i + 1], currentAmountIn);

            if (hopLeftover > 0) {
                _handleRemainder(path[i], path[i + 1], hopLeftover, recipient, remainderMode, remainderConfig);
            }
        }

        amountOut = currentAmountIn;

        if (amountOut < minAmountOut) {
            revert SlippageExceeded(minAmountOut, amountOut);
        }

        // Every hop's matched output was captured by the router itself (see the loop above),
        // including the final hop's -- so unlike the matched portion of every earlier hop,
        // which immediately became the NEXT hop's input, the last hop's output is still sitting
        // in the router's own balance at this point and must be forwarded out to `recipient`.
        TransferHelper.safeTransfer(path[path.length - 1], recipient, amountOut);

        emit SwapExecuted(recipient, path[0], path[path.length - 1], amountIn, amountOut);
    }

    function _executeHop(address tokenIn, address tokenOut, uint256 amountIn_)
        private
        returns (uint256 hopAmountOut, uint256 hopLeftover)
    {
        address pool = _getPool(tokenIn, tokenOut);

        (address poolBase,) = IPool(pool).getBaseQuote();
        bool quoteToBase = poolBase != tokenIn; // tokenIn is quote if it's not the pool's base

        TransferHelper.safeApprove(tokenIn, pool, amountIn_);

        uint256 matchedPrice;
        (hopAmountOut, hopLeftover, matchedPrice) = IPool(pool).swap(amountIn_, quoteToBase, address(this), false);

        emit HopExecuted(pool, tokenIn, tokenOut, amountIn_, hopAmountOut, hopLeftover);

        _reportSwap(pool, quoteToBase, matchedPrice);
    }

    // Reports the price this hop actually traded at, AFTER it has settled -- a swap must
    // never influence the reference it priced against.
    //
    // This is the matched price itself, not a figure derived from it. `lmp` means "last
    // matched price", and a swap through the pool is a match: the swapper and the pool's
    // positions exchanged tokens at a price, and that price is what the field should
    // hold. Synthesising a different number from spread and depth would make lmp -- and
    // the TWAP averaged over it -- stop describing trades that happened.
    //
    // The engine clamps this to the pair's market spread on the way in. That bounds how
    // far a single swap may move the price; it does not decide the price.
    function _reportSwap(address pool, bool quoteToBase, uint256 matchedPrice) private {
        if (matchedPrice == 0) return; // nothing filled

        address engine = IPool(pool).engine();
        (address base, address quote) = IPool(pool).getBaseQuote();
        IMatchingEngine(engine).reportSwap(base, quote, quoteToBase, matchedPrice);
    }

    // Disposes of one hop's unmatched input per the caller's chosen mode. `recipient` here is
    // always the ORIGINAL swap recipient (never the router), regardless of which hop this is --
    // an intermediate hop's remainder belongs to the same end user as the final hop's does.
    // Split into one private function per mode purely to keep each function's own stack frame
    // within EVM limits (this file has no viaIR compilation available -- see foundry.toml),
    // same reasoning as Pool.sol's own _placeTierLegs/_settleTiers split.
    function _handleRemainder(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        address recipient,
        RemainderMode mode,
        RemainderConfig calldata cfg
    ) private {
        if (mode == RemainderMode.Refund) {
            TransferHelper.safeTransfer(tokenIn, recipient, amount);
        } else if (mode == RemainderMode.RestAsOrder) {
            _restAsOrder(tokenIn, tokenOut, amount, recipient, cfg.restPrice);
        } else {
            _depositToLP(tokenIn, tokenOut, amount, recipient, cfg);
        }
        emit RemainderHandled(tokenIn, tokenOut, amount, mode);
    }

    function _restAsOrder(address tokenIn, address tokenOut, uint256 amount, address recipient, uint256 restPrice)
        private
    {
        address pool = _getPool(tokenIn, tokenOut);
        (address base, address quote) = IPool(pool).getBaseQuote();
        address engine = IPool(pool).engine();
        uint256 price = restPrice > 0 ? restPrice : IMatchingEngine(engine).mktPrice(base, quote);
        TransferHelper.safeApprove(tokenIn, engine, amount);
        if (base != tokenIn) {
            IMatchingEngine(engine).limitBuy(base, quote, price, amount, true, REMAINDER_MATCH_CAP, recipient);
        } else {
            IMatchingEngine(engine).limitSell(base, quote, price, amount, true, REMAINDER_MATCH_CAP, recipient);
        }
    }

    // PositionManager.addLiquidity always pulls from, and mints the position NFT to, its own
    // msg.sender -- which is this router, not `recipient`, since there is no recipient-aware
    // overload. Minting to the router first and immediately forwarding the NFT is the only way
    // to get the position into the actual end user's hands without a new PositionManager entry
    // point.
    function _depositToLP(address tokenIn, address tokenOut, uint256 amount, address recipient, RemainderConfig calldata cfg)
        private
    {
        address pool = _getPool(tokenIn, tokenOut);
        (address base,) = IPool(pool).getBaseQuote();
        address positionManager = IPool(pool).positionManager();
        uint256 baseAmount = base != tokenIn ? 0 : amount;
        uint256 quoteAmount = base != tokenIn ? amount : 0;

        TransferHelper.safeApprove(tokenIn, pool, amount);
        uint256 tokenId = IPositionManager(positionManager).addLiquidity(
            pool, cfg.lpMinPrice, cfg.lpMaxPrice, cfg.lpSlippageLimit, baseAmount, quoteAmount
        );

        _emitLiquidityAdded(pool, positionManager, tokenId, recipient, baseAmount, quoteAmount, cfg);

        IERC1155(positionManager).safeTransferFrom(address(this), recipient, tokenId, 1, "");
    }

    // Split out purely for stack depth (same reasoning as the _handleRemainder/_restAsOrder/
    // _depositToLP split): mirrors IPool.LiquidityAdded from the router's own address so an
    // indexer watching only SwapRouter sees every remainder-originated position, without also
    // having to watch every Pool the PoolFactory may have deployed.
    function _emitLiquidityAdded(
        address pool,
        address positionManager,
        uint256 tokenId,
        address recipient,
        uint256 baseAmount,
        uint256 quoteAmount,
        RemainderConfig calldata cfg
    ) private {
        (, uint256 positionId) = IPositionManager(positionManager).tokenPosition(tokenId);
        emit LiquidityAdded(
            pool, positionId, recipient, cfg.lpMinPrice, cfg.lpMaxPrice, cfg.lpSlippageLimit, baseAmount, quoteAmount
        );
    }

    /// @inheritdoc ISwapRouter
    function removeLiquidity(
        address positionManager,
        uint256 tokenId,
        uint256 baseAmount,
        uint256 quoteAmount,
        address recipient
    ) external override {
        (address pool, uint256 positionId) = IPositionManager(positionManager).tokenPosition(tokenId);
        IPositionManager(positionManager).removeLiquidityFor(msg.sender, tokenId, baseAmount, quoteAmount, recipient);
        emit LiquidityRemoved(pool, positionId, recipient, baseAmount, quoteAmount);
    }

    function _getPool(address tokenIn, address tokenOut) private view returns (address pool) {
        pool = IPoolFactory(poolFactory).getPool(tokenIn, tokenOut);
        if (pool == address(0)) {
            pool = IPoolFactory(poolFactory).getPool(tokenOut, tokenIn);
        }
        if (pool == address(0)) {
            revert PoolDoesNotExist(tokenIn, tokenOut);
        }
    }

    // Required so this contract can receive the position token PositionManager.addLiquidity
    // mints to it, in between minting and forwarding it to `recipient` in _handleRemainder.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }
}
