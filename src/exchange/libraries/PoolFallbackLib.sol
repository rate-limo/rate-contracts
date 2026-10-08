// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IOrderbook} from "../interfaces/IOrderbook.sol";
import {TransferHelper} from "./TransferHelper.sol";
import {MatchingLib} from "./MatchingLib.sol";

interface IBandPoolSwap {
    function swap(uint256 amountIn, bool quoteToBase, address recipient, uint256 minAmountOut)
        external
        returns (uint256 amountOut, uint256 matchedPrice);
    function effectiveFeeRate(uint8 band, uint256 engineRate) external view returns (uint256);
    function bandTolerances(uint8 band) external view returns (uint32 buy, uint32 sell);
}

interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

/// The engine, called on itself: under delegatecall `address(this)` IS the engine.
interface ISelf {
    function getSpread(address pair, bool isBuy, bool isMkt) external view returns (uint32);
    function DENOM() external view returns (uint32);
    function feeOf(address base, address quote, address account, bool isMaker) external view returns (uint32);
}

/**
 * The last stop for a TAKER's unmatched remainder: the pair's own pool.
 *
 * ## Where this sits
 *
 * An order walks three venues in order, and until now it walked two:
 *
 *   1. the resting book        (`MatchingLib.limitOrder`)
 *   2. any stop orders it woke (`StopOrderMatchingLib`, which rests them and re-matches)
 *   3. the pool                (here)
 *
 * Whatever survives all three is refunded, exactly as it was before.
 *
 * ## Two guards, and a third that matters more
 *
 * **The pair must have a pool.** `addPair` creates one only when
 * `poolFactory != 0 && (nativeScale != 0 || neither leg is WETH)`, so on a chain where
 * WETH is a real wrapper the WETH pairs -- the busiest ones -- have none. A zero address
 * here returns the remainder untouched.
 *
 * **The pool must admit us.** `BandPool.onlyRouter` gates on the engine's configured
 * `swapRouter`, so this only works because the pool was taught to accept the engine as
 * well. Everything is wrapped in `try`, so a pool that refuses -- an older deployment, a
 * different gate, no liquidity, a slippage rejection -- degrades to the previous
 * behaviour rather than reverting the order.
 *
 * **The PRICE can never be worse than the order asked for.** `minAmountOut` starts at
 * `IOrderbook.convert(limitPrice, remaining, ...)` -- the venue's own conversion at the
 * order's own price -- and is then reduced by the pool's FEE on its tightest band, exactly
 * as `BandPool._fillBand` computes it (`out - out * rate / DENOM`). Without that bound the
 * pool could fill a long way through the bands and hand the taker an execution they never
 * agreed to.
 *
 * The fee deduction is what lets this path fill at all. Before it, `minAmountOut` was the
 * GROSS amount at the order price while the pool pays out NET of its fee, so a pool
 * filling at exactly the order price -- the best it can do, since its rail caps the band
 * bound at the same price -- always came up short by precisely its fee and reverted
 * `SlippageExceeded`. Measured on RISE KPRF1448/tUSD (2026-10-04): 300 tUSD at 500
 * asked for 60.0M KPRF gross, the pool returned 59.4M -- its 1% band-0 fee -- and every
 * taker remainder was refunded. The fee is the pool's quoted charge, the same as the
 * book's taker fee is charged on top of a limit price; only a WORSE PRICE is refused.
 * A walk that spills into a wider band pays that band's higher fee and can still fail
 * the bound, refunding as before.
 *
 * ## Taker orders only
 *
 * A maker order's remainder is meant to REST -- that is what the trader asked for, and
 * filling it here instead would mean limit orders never reach the book. Only the branch
 * that would otherwise refund reaches this code.
 */
library PoolFallbackLib {
    /// BandPool's fee denominator (`PoolBands.DENOM`), the same 1e8 grid as the engine.
    uint256 private constant FEE_DENOM = 100_000_000;

    event RemainderRoutedToPool(
        address indexed pair, address indexed recipient, uint256 spent, uint256 received
    );

    /**
     * @param give   the token being spent -- quote on a bid, base on an ask.
     * @return still the part the pool did not take, for the caller to refund.
     */
    function route(
        address pair,
        address give,
        bool isBid,
        uint256 remaining,
        address recipient,
        uint256 limitPrice
    ) internal returns (uint256 still) {
        if (remaining == 0) return 0;

        address pool = IOrderbook(pair).getPool();
        if (pool == address(0)) return remaining;

        // The best the POOL can pay for this order, which is not the order's own price.
        // Zero means the pair cannot express this order's bound, so do not route blind.
        uint256 minOut =
            _poolBound(pair, pool, isBid, IOrderbook(pair).convert(limitPrice, remaining, !isBid));
        if (minOut == 0) return remaining;

        TransferHelper.safeApprove(give, pool, remaining);
        uint256 held = IERC20Balance(give).balanceOf(address(this));

        // `quoteToBase` is the pool's word for a buy, which is what `isBid` means here.
        try IBandPoolSwap(pool).swap(remaining, isBid, recipient, minOut) returns (
            uint256 out, uint256 matched
        ) {
            // How much the pool actually TOOK, measured rather than assumed: its own gas
            // guard can stop the band walk early, in which case it pulls less than it was
            // offered and `amountOut` alone cannot tell us how much.
            uint256 spent = held - IERC20Balance(give).balanceOf(address(this));
            if (spent < remaining) TransferHelper.safeApprove(give, pool, 0);

            // Report the price exactly as a router-driven swap would.
            //
            // This is not optional bookkeeping. `BandSwapRouter` is what normally calls
            // `reportSwap`, and this path deliberately bypasses the router -- so without
            // this the pool leg emits `BandSwap` (which the broker acknowledges and does
            // NOT aggregate) and nothing else. No price print, no candle, no `lmp` move:
            // the tokens change hands and the backend never learns the trade happened.
            //
            // `reportSwapPrice` is the same rail `reportSwap` applies, with the same
            // arguments, so the two-sided block-open cap that stops one trade teleporting
            // `lmp` -- and through the 300s TWAP, the pool's own anchor -- applies here
            // too. Writing `setLmp` directly instead would reintroduce exactly the
            // manipulation the rail exists to prevent.
            _report(pair, matched, isBid);

            emit RemainderRoutedToPool(pair, recipient, spent, out);
            return remaining - spent;
        } catch {
            // Never leave an allowance behind on a path that did nothing.
            TransferHelper.safeApprove(give, pool, 0);
            return remaining;
        }
    }

    /**
     * The fee the pool charges THIS engine on its tightest band: the engine's taker rate
     * for the pair (the pool prices `feeOf(base, quote, msg.sender, false)` and the engine
     * is `msg.sender`) times the band's multiplier, capped -- via the pool's own view, so
     * the cap and rounding cannot drift from `_fillBand`. Its own frame for stack reasons.
     */
    ///
    /// A pool that cannot answer (an older deployment, a test double) is treated as
    /// fee-free -- the previous behaviour -- rather than reverting the order: the swap
    /// itself is still bounded and still wrapped in `try`. A rate of 100% or more, which
    /// no BandPool can return (`MAX_FEE_RATE` is 3%), is likewise ignored rather than
    /// allowed to zero the bound.
    /**
     * The best price the pool can actually pay, which is NOT the order's price.
     *
     * Band 0 quotes a SPREAD around the anchor, and `BandPool._bandBound` is where it
     * lives: a buy is widened to `anchor x (1 + tolerance)` and a sell narrowed to
     * `anchor x (1 - tolerance)`. `_fillBand` then takes its fee out of the result. The
     * fee was deducted here already (2026-10-04); the tolerance was not, and on most
     * pairs it is the larger of the two -- so the bound asked the pool for strictly more
     * than it can ever pay, and every routed remainder came back `SlippageExceeded`.
     *
     * Measured at an anchor of 100e8 with a 0.1% band-0 tolerance and a 0.1% fee: the
     * pool offers 0.998001998e18 against a bound of 0.999e18 and refuses. It is INVISIBLE
     * without the revert this change adds -- the engine caught `SlippageExceeded`,
     * refunded, and reported success. It only ever filled where the tolerance rounded
     * away to nothing, which is the low-price case the earlier fork test happened to use.
     *
     * Reproduces `_fillBand`'s arithmetic in its order, rounding DOWN at each step, so
     * the bound is satisfiable by at most a wei. The price protection is unchanged in
     * kind: the tolerance is itself capped by the pair's own spread rail, which is the
     * same limit the engine applies to a book match.
     */
    function _poolBound(address pair, address pool, bool isBid, uint256 gross)
        private
        view
        returns (uint256)
    {
        if (gross == 0) return 0;
        uint256 tol = _bandZeroTolerance(pool, isBid);
        if (tol > 0) {
            if (isBid) {
                gross = (gross * FEE_DENOM) / (FEE_DENOM + tol);
            } else {
                // A tolerance at or past 100% prices the sell side at zero: that band is
                // idle, exactly as `_bandBound` treats it.
                gross = tol >= FEE_DENOM ? 0 : (gross * (FEE_DENOM - tol)) / FEE_DENOM;
            }
        }
        return gross - (gross * _bandZeroFee(pair, pool)) / FEE_DENOM;
    }

    /// Band 0's quoted spread for this side, or zero from a pool that cannot answer.
    function _bandZeroTolerance(address pool, bool isBid) private view returns (uint256 tol) {
        try IBandPoolSwap(pool).bandTolerances(0) returns (uint32 buy, uint32 sell) {
            tol = isBid ? buy : sell;
        } catch {}
    }

    function _bandZeroFee(address pair, address pool) private view returns (uint256 rate) {
        (address base, address quote) = IOrderbook(pair).getBaseQuote();
        try IBandPoolSwap(pool).effectiveFeeRate(
            0, ISelf(address(this)).feeOf(base, quote, address(this), false)
        ) returns (uint256 r) {
            if (r < FEE_DENOM) rate = r;
        } catch {}
    }

    /**
     * The price rail, in its own frame.
     *
     * Extracted purely because `route` ran out of stack slots with the three spread
     * reads inlined -- "Stack too deep" on the legacy pipeline, which is the one this
     * project builds and ships (see foundry.toml on why `--via-ir` is not an option
     * for a deploy).
     */
    function _report(address pair, uint256 matched, bool isBid) private {
        if (matched == 0) return;
        MatchingLib.reportSwapPrice(
            pair,
            matched,
            isBid,
            ISelf(address(this)).getSpread(pair, true, true),
            ISelf(address(this)).getSpread(pair, false, true),
            ISelf(address(this)).DENOM()
        );
    }
}
