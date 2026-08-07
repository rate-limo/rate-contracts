// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.24;

/// @dev Ring buffer size, declared file-level (not as a library member) because Solidity
/// requires a compile-time constant expression to size a fixed storage array, and a library's
/// own `internal constant` isn't accepted as one at the call site in consuming contracts.
/// 1024 slots span 1023s at the maximum write rate of one per second, comfortably
/// outlasting Pool's 600s TWAP_WINDOW. At 512 a pair written every second spanned only
/// 511s, so `twap(600)` silently degraded to a shorter average than the caller asked for
/// -- and the party flooding the buffer is the one who benefits from less smoothing.
uint16 constant ORACLE_CARDINALITY = 1024;

/**
 * @title Oracle
 * @notice Fixed-cardinality, time-weighted average price (TWAP) ring buffer for a single
 * Orderbook's last-matched price (`lmp`). `Orderbook.setLmp` is the single choke point every
 * price update funnels through -- every market order, every crossing limit order, and the
 * initial listing price all call it (see `MatchingEngine.sol`'s six call sites) -- so hooking
 * the accumulator there covers every way `lmp` can move, without needing any change to
 * `MatchingEngine.sol` or the matching logic itself.
 *
 * Threat model this defends against: `lmp()` is a single stored value that can be moved by a
 * single trade in the same block as a subsequent transaction that reads it (see
 * docs/swap/design.md's MEV section for the full walkthrough). Bounding a trade's price
 * relative to `lmp()` -- e.g. `lmp() * (1 +/- slippageLimit)` -- does not protect against this,
 * because the reference point itself is what gets manipulated; the bound just follows it.
 * `twap()` instead averages price over many blocks, so a single manipulated block can only ever
 * contribute a small fraction of the result.
 *
 * Design choices, and why:
 * - One observation written per block, max (`write` no-ops if already written this block).
 *   This is the load-bearing security property: without it, an attacker could spam many
 *   same-block/same-window transactions to evict old observations out of the fixed-size ring
 *   buffer faster than real time passes, artificially shrinking the *effective* window
 *   regardless of what `minSecondsAgo` the caller requested. With the throttle, evicting a
 *   given observation requires actually waiting out `ORACLE_CARDINALITY` blocks, not just
 *   paying for that many transactions.
 * - `twap(minSecondsAgo)` returns the average over an *actual* window that is >= `minSecondsAgo`
 *   (never less, may be slightly more), computed between two *real* stored observations. This
 *   deliberately avoids interpolating a synthetic price at an exact sub-observation timestamp:
 *   interpolation is where subtle TWAP oracle bugs live, and "the window is a little longer
 *   than requested" is strictly more manipulation-resistant than "a little shorter", so the
 *   simplification is conservative rather than a compromise.
 * - Fixed-size array (not a dynamically-`push`ed one) so the buffer costs nothing to create at
 *   pair-listing time -- storage slots are implicitly zero/uninitialized until actually written,
 *   at normal per-write SSTORE cost only.
 */
library Oracle {
    struct Observation {
        // `blockTimestamp` and `initialized` are deliberately declared adjacent (both before
        // `priceCumulative`) so Solidity packs them into a single storage slot instead of three
        // -- `priceCumulative` alone needs a full slot regardless, so packing the other two
        // together is a genuine 33%-per-write storage-cost reduction, not a cosmetic reorder.
        uint32 blockTimestamp;
        bool initialized;
        // Sum, over every second since the buffer's first observation, of the price that was
        // in effect during that second. TWAP over [t1, t2] = (cumulative(t2) - cumulative(t1)) / (t2 - t1).
        uint256 priceCumulative;
    }

    error AlreadyInitialized();
    error NotInitialized();
    error InsufficientHistory(uint32 requested, uint32 oldestAvailableAge);
    error InvalidWindow(uint32 minSecondsAgo);

    /// @notice Seeds the buffer's first slot. Must be called exactly once, before any `write`,
    /// typically from the Orderbook's own `initialize()`.
    function initialize(
        Observation[ORACLE_CARDINALITY] storage self,
        uint32 blockTimestamp
    ) internal {
        if (self[0].initialized) revert AlreadyInitialized();
        self[0] = Observation({blockTimestamp: blockTimestamp, priceCumulative: 0, initialized: true});
    }

    /// @notice Writes a new observation carrying `priceBeforeUpdate` forward for the time
    /// elapsed since the last write, then advances the ring buffer. `priceBeforeUpdate` is the
    /// price that was in effect *up until this call* (i.e. the outgoing `lmp`, not the new one
    /// being set) -- that's the price that was actually live during the elapsed interval.
    /// No-ops (returns the unchanged index) if an observation was already written this block.
    function write(
        Observation[ORACLE_CARDINALITY] storage self,
        uint16 index,
        uint32 blockTimestamp,
        uint256 priceBeforeUpdate
    ) internal returns (uint16 indexUpdated) {
        Observation memory last = self[index];
        if (!last.initialized) revert NotInitialized();
        if (last.blockTimestamp == blockTimestamp) {
            return index;
        }

        uint32 delta = blockTimestamp - last.blockTimestamp;
        uint256 cumulative = last.priceCumulative + priceBeforeUpdate * delta;

        indexUpdated = uint16((uint256(index) + 1) % ORACLE_CARDINALITY);
        self[indexUpdated] = Observation({
            blockTimestamp: blockTimestamp,
            priceCumulative: cumulative,
            initialized: true
        });
    }

    /// @notice Time-weighted average price over a window of at least `minSecondsAgo`, ending
    /// now. `currentPrice` is the live `lmp` (the price in effect since the newest observation,
    /// used to extrapolate the cumulative forward to the present moment). Reverts with
    /// `InsufficientHistory` if the buffer doesn't yet hold an observation at least
    /// `minSecondsAgo` old (e.g. a pair listed more recently than that).
    function twap(
        Observation[ORACLE_CARDINALITY] storage self,
        uint16 index,
        uint32 blockTimestamp,
        uint256 currentPrice,
        uint32 minSecondsAgo
    ) internal view returns (uint256 price, uint32 actualWindow) {
        if (minSecondsAgo == 0) revert InvalidWindow(minSecondsAgo);

        Observation memory newest = self[index];
        if (!newest.initialized) revert NotInitialized();

        uint256 cumulativeNow = newest.priceCumulative + currentPrice * (blockTimestamp - newest.blockTimestamp);

        Observation memory target = _findAtLeast(self, index, blockTimestamp, minSecondsAgo);

        actualWindow = blockTimestamp - target.blockTimestamp;
        price = (cumulativeNow - target.priceCumulative) / actualWindow;
    }

    /// @dev Returns the newest observation whose age (blockTimestamp distance from `now`) is
    /// >= `minSecondsAgo`, when one exists. Age strictly increases as you walk backward (toward
    /// older logical positions) through the populated range of the buffer, so this is a
    /// monotonic boundary search: binary search over logical position (0 = oldest
    /// currently-retained observation) finds it in O(log ORACLE_CARDINALITY) storage reads
    /// instead of a full linear scan.
    ///
    /// Two distinct reasons the oldest retained observation might not be old enough, handled
    /// differently:
    /// - Buffer not yet wrapped (fewer than ORACLE_CARDINALITY writes have ever happened): this
    ///   pair/market simply hasn't existed long enough for a window this long to exist yet.
    ///   Reverts -- there is no data to give the caller, degrading would mean fabricating it.
    /// - Buffer fully wrapped (every slot has been written at least once) but writes have come
    ///   more often than `minSecondsAgo / ORACLE_CARDINALITY` apart, so even the *oldest*
    ///   observation this fixed-size buffer can retain isn't old enough: this is a capacity
    ///   limit, not a bootstrap gap. A market trading at least once every block on a fast chain
    ///   can permanently be in this state for large `minSecondsAgo` values. Reverting here would
    ///   brick every caller requesting that window forever, so this degrades instead: return the
    ///   oldest observation the buffer actually has, and let the caller (via `twap`'s returned
    ///   `actualWindow`) see that it got less history than it asked for, rather than nothing.
    function _findAtLeast(
        Observation[ORACLE_CARDINALITY] storage self,
        uint16 newestIndex,
        uint32 blockTimestamp,
        uint32 minSecondsAgo
    ) private view returns (Observation memory) {
        bool wrapped = self[uint16((uint256(newestIndex) + 1) % ORACLE_CARDINALITY)].initialized;
        uint16 oldestIndex = wrapped ? uint16((uint256(newestIndex) + 1) % ORACLE_CARDINALITY) : 0;
        uint256 count = wrapped ? ORACLE_CARDINALITY : uint256(newestIndex) + 1;

        Observation memory oldest = self[oldestIndex];
        if (blockTimestamp - oldest.blockTimestamp < minSecondsAgo) {
            if (!wrapped) {
                revert InsufficientHistory(minSecondsAgo, blockTimestamp - oldest.blockTimestamp);
            }
            return oldest; // buffer at capacity -- degrade to the longest window it can provide
        }

        // Binary search logical positions [0, count-1] (0 = oldest) for the smallest logical
        // position `pos` whose age is < minSecondsAgo, then return the observation just before
        // it (logical position pos-1), which is the newest one still >= minSecondsAgo old.
        // Invariant maintained: lo's observation is always >= minSecondsAgo old (age condition
        // true); hi's observation is always either out of range or < minSecondsAgo old (false).
        uint256 lo = 0;
        uint256 hi = count - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2; // bias toward hi to keep lo's invariant intact
            Observation memory obs = self[uint16((oldestIndex + mid) % ORACLE_CARDINALITY)];
            uint32 age = blockTimestamp - obs.blockTimestamp;
            if (age >= minSecondsAgo) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }

        return self[uint16((oldestIndex + lo) % ORACLE_CARDINALITY)];
    }
}
