// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandPool} from "./BandPool.sol";
import {IMatchingEngine} from "../exchange/interfaces/IMatchingEngine.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {IPoolFactory} from "./interfaces/IPoolFactory.sol";

/**
 * The only caller of `BandPool.swap`, and the half of the loop that writes the price
 * back to the orderbook.
 *
 * ## Why the pool cannot do this itself
 *
 * `MatchingEngine.reportSwap` is gated to the engine's registered `swapRouter`, and
 * that gate is the whole reason the price rail can be trusted: `MatchingLib.reportSwapPrice`
 * clamps a report to a block-open-anchored ceiling and floor, and a rail applied to
 * some callers and not others is not a rail. So the pool is gated to the router and the
 * router is gated by the engine, which makes `setSwapRouter` wire both halves at once.
 *
 * ## Why reporting is not optional
 *
 * A band's bound is `twap × (1 ± tolerance)` and the TWAP is built from `lmp`. Without
 * a report, pool trades move nothing: a pair whose book is quiet keeps quoting around
 * the price it was listed at however much the pool trades, and every band is a standing
 * order at a price the market has left. That is the stale-oracle drain the TWAP
 * anchoring exists to avoid, arriving through the side door.
 *
 * The engine clamps what lands. It bounds how far one swap may move the price; it does
 * not decide the price, and it is anchored to the block's OPEN so a batch inside one
 * block is bounded as a batch rather than compounding cap by cap.
 */
contract BandSwapRouter {
    error NothingFilled();
    error UnknownPool(address pool);

    event BandSwapRouted(
        address indexed pool,
        address indexed taker,
        address indexed recipient,
        bool quoteToBase,
        uint256 amountIn,
        uint256 amountOut,
        uint256 matchedPrice
    );

    /**
     * Swap through one band pool and report the price it traded at.
     *
     * `minAmountOut` is the taker's own bound and is enforced inside the pool, so a
     * report can only ever describe a fill the taker accepted.
     */
    function swap(address pool, uint256 amountIn, bool quoteToBase, address recipient, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        // Read ONCE, before the pool runs any code of ours. A fake pool can change its
        // answers inside `swap()`, so a check on one reading and a report on a second
        // is no check at all (the review's C-1 recheck): pass with itself as engine and
        // factory, then name the real engine afterwards.
        PoolRef memory ref = _listed(pool);
        address tokenIn = quoteToBase ? ref.quote : ref.base;
        TransferHelper.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        TransferHelper.safeApprove(tokenIn, pool, amountIn);

        uint256 matchedPrice;
        (amountOut, matchedPrice) = BandPool(pool).swap(amountIn, quoteToBase, recipient, minAmountOut);

        // The pool pulls only what it consumed, so an unfilled remainder is still here.
        // Hand it back rather than leaving it: it is the taker's, and a router holding
        // dust is a router that can be drained of somebody else's dust.
        uint256 leftover = _balance(tokenIn);
        if (leftover > 0) {
            TransferHelper.safeApprove(tokenIn, pool, 0);
            TransferHelper.safeTransfer(tokenIn, msg.sender, leftover);
        }

        // Push the matched price at the engine checked above, which clamps it to the
        // pair's spread. A zero price means nothing changed hands.
        if (matchedPrice > 0) IMatchingEngine(ref.engine).reportSwap(ref.base, ref.quote, quoteToBase, matchedPrice);
        emit BandSwapRouted(pool, msg.sender, recipient, quoteToBase, amountIn, amountOut, matchedPrice);
    }

    struct PoolRef {
        address engine;
        address base;
        address quote;
    }

    /**
     * The pool must be the one its engine's factory records for its pair, and the three
     * values that check was made on are the ones used for the whole swap.
     *
     * This router is the only caller `reportSwap` accepts, so whatever price a pool's
     * `swap` returns is written through the rail into `lmp` and from there into every
     * band's TWAP anchor. `isClone` would not do -- anyone can initialize a clone with
     * their own orderbook -- so the check is the pool's ADDRESS against the factory. A
     * fake that names a fake engine passes, and then reports only to that fake engine.
     */
    function _listed(address pool) private view returns (PoolRef memory ref) {
        ref = PoolRef({engine: BandPool(pool).engine(), base: BandPool(pool).base(), quote: BandPool(pool).quote()});
        address factory = IMatchingEngine(ref.engine).poolFactory();
        if (factory == address(0) || IPoolFactory(factory).getPool(ref.base, ref.quote) != pool) {
            revert UnknownPool(pool);
        }
    }

    function _balance(address token) private view returns (uint256) {
        (bool ok, bytes memory data) =
            token.staticcall(abi.encodeWithSelector(0x70a08231, address(this)));
        return ok && data.length >= 32 ? abi.decode(data, (uint256)) : 0;
    }
}
