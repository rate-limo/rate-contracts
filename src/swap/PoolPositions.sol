// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolBands} from "./PoolBands.sol";
import {PoolFeeMath} from "./libraries/PoolFeeMath.sol";

/**
 * Positions, keyed by the position manager's token id.
 *
 * One token holds any subset of the ladder. Per (token, band) the pool keeps one packed
 * slot -- the token's shares in the band and the share-weighted age of that capital --
 * plus a fee checkpoint per currency and the fees accrued but not yet vested. Per token
 * it keeps the fees already vested and payable, which can be summed across bands
 * because they are in the pool's two currencies regardless of the band that earned them.
 *
 * A swap still reads and writes NO position. Everything here is touched only when the
 * token's owner acts.
 */
abstract contract PoolPositions is PoolBands {
    using SafeCast for uint256;

    /// One storage slot: 128 + 64 bits.
    struct Slot {
        uint128 shares;
        uint64 createdAt;
    }

    struct Checkpoint {
        uint256 base;
        uint256 quote;
    }

    struct Amounts {
        uint128 base;
        uint128 quote;
    }

    mapping(uint256 tokenId => mapping(uint8 band => Slot)) internal _slot;
    mapping(uint256 tokenId => mapping(uint8 band => Checkpoint)) internal _ckpt;
    /// Accrued to the slot and not yet vested. Moves with the capital; forfeits only when it leaves.
    mapping(uint256 tokenId => mapping(uint8 band => Amounts)) internal _pending;
    /// Vested and payable. Never forfeits.
    mapping(uint256 tokenId => Amounts) internal _owed;
    /// How much of this slot's accrual has already been released into owed. Together with
    /// pending it is the slot's accrued total, which is what makes release idempotent in
    /// TIME -- see `_vestedPart`. Scales pro-rata with the shares, like pending.
    mapping(uint256 tokenId => mapping(uint8 band => Amounts)) internal _released;
    /// Bit i set <=> the token holds shares in band i. The single source of membership.
    mapping(uint256 tokenId => uint8) internal _mask;

    error BandClosed(uint8 band);
    error ZeroLiquidity();
    error BandsNotAscending();
    error BadBand(uint8 band);

    /**
     * Bring a slot's fees up to date: whatever the band's accumulators grew by since the
     * slot's checkpoint, times its shares, moves into pending. Must run before the
     * slot's shares change, or the accrual is measured on the wrong share count.
     */
    function _accrue(uint256 tokenId, uint8 band) internal {
        Band storage b = _bands[band];
        Slot storage s = _slot[tokenId][band];
        Checkpoint storage c = _ckpt[tokenId][band];
        if (s.shares > 0) {
            uint256 rawBase = PoolFeeMath.rawEntitlement(s.shares, b.feeGrowthBase, c.base);
            uint256 rawQuote = PoolFeeMath.rawEntitlement(s.shares, b.feeGrowthQuote, c.quote);
            if (rawBase > 0 || rawQuote > 0) {
                Amounts storage p = _pending[tokenId][band];
                p.base = (uint256(p.base) + rawBase).toUint128();
                p.quote = (uint256(p.quote) + rawQuote).toUint128();
            }
        }
        if (c.base != b.feeGrowthBase) c.base = b.feeGrowthBase;
        if (c.quote != b.feeGrowthQuote) c.quote = b.feeGrowthQuote;
    }

    /// How far the slot's capital is along the vesting ramp, over DENOM.
    function _vestNum(Slot storage s) internal view returns (uint256) {
        return PoolFeeMath.vestedNumerator(block.timestamp - s.createdAt, maturity, DENOM);
    }

    /**
     * How much of a slot's pending vests NOW: `max(0, (pending + released) x num / DENOM
     * - released)`, capped at pending.
     *
     * The ramp applies to everything the slot has accrued, and what it already paid counts
     * against that. So a second call at the same moment releases nothing (releasing `num`
     * of the REMAINDER on every call compounded -- k calls released `1 - (1 - v)^k`, the
     * review's H-1), and a fee that accrues after a collect vests at the current level
     * rather than from zero (tracking one shared release LEVEL instead over-forfeited
     * later fees -- the H-1 recheck). At maturity everything releases. Rounds DOWN.
     *
     * Right after a top-up the blended clock can sit below what was already released;
     * nothing then releases until the ramp catches up -- at most one maturity. That is the
     * JIT defence working, not a leak: fresh capital does not inherit released vesting.
     */
    function _vestedPart(Slot storage s, uint256 pending, uint256 released) internal view returns (uint256 vested) {
        uint256 num = _vestNum(s);
        if (num >= DENOM) return pending;
        uint256 target = Math.mulDiv(pending + released, num, DENOM);
        if (target <= released) return 0;
        vested = target - released;
        if (vested > pending) vested = pending;
    }

    /// Move the vested part of a slot's pending into the token's owed -- see `_vestedPart`.
    function _lockVested(uint256 tokenId, uint8 band) internal {
        Amounts storage p = _pending[tokenId][band];
        if (p.base == 0 && p.quote == 0) return;
        Slot storage s = _slot[tokenId][band];
        Amounts storage rel = _released[tokenId][band];
        uint256 vestedBase = _vestedPart(s, p.base, rel.base);
        uint256 vestedQuote = _vestedPart(s, p.quote, rel.quote);
        if (vestedBase == 0 && vestedQuote == 0) return;
        p.base -= vestedBase.toUint128();
        p.quote -= vestedQuote.toUint128();
        rel.base = (uint256(rel.base) + vestedBase).toUint128();
        rel.quote = (uint256(rel.quote) + vestedQuote).toUint128();
        Amounts storage o = _owed[tokenId];
        o.base = (uint256(o.base) + vestedBase).toUint128();
        o.quote = (uint256(o.quote) + vestedQuote).toUint128();
    }

    /// Scale a slot's released record by the shares that stay, rounding it DOWN -- the
    /// direction that can only release less later, never more.
    function _scaleReleased(uint256 tokenId, uint8 band, uint256 kept, uint256 held)
        internal
        returns (uint256 movedBase, uint256 movedQuote)
    {
        Amounts storage rel = _released[tokenId][band];
        if (rel.base == 0 && rel.quote == 0) return (0, 0);
        uint256 keepBase = held == 0 ? 0 : Math.mulDiv(rel.base, kept, held);
        uint256 keepQuote = held == 0 ? 0 : Math.mulDiv(rel.quote, kept, held);
        movedBase = rel.base - keepBase;
        movedQuote = rel.quote - keepQuote;
        rel.base = keepBase.toUint128();
        rel.quote = keepQuote.toUint128();
    }

    /**
     * Share-weighted clock, blended on VESTING, not on raw time.
     *
     * New capital pulls the slot's age toward `addedAt` in proportion to the shares it
     * adds -- the JIT defence: fresh capital must not borrow old capital's vesting.
     *
     * Each side's age is CAPPED at `maturity` before the mean. The ramp saturates there,
     * so blending raw timestamps let a tiny slot aged 30 days carry 43 minutes of age at
     * 0.1% weight -- past a 10-minute maturity -- and a 1000x top-up came out fully vested
     * (PoolTopUp.t.sol pins it). Capped, and with the ramp linear below maturity, the
     * blended age is exactly the share-weighted mean of the two sides' VESTED FRACTIONS:
     * 0.1% of the capital fully vested contributes 0.1% vesting and no more.
     *
     * Used for a top-up (`addedAt` = now) and for a move (`addedAt` = the source slot's
     * clock, so capital carries its age between bands but can never create any).
     */
    function _blendCreatedAt(uint64 createdAt, uint256 shares, uint256 addedAt, uint256 added)
        internal
        view
        returns (uint64)
    {
        uint256 floor = block.timestamp > maturity ? block.timestamp - maturity : 0;
        uint256 incoming = addedAt < floor ? floor : addedAt;
        if (shares == 0) return incoming.toUint64();
        uint256 held = createdAt < floor ? floor : createdAt;
        return ((held * shares + incoming * added) / (shares + added)).toUint64();
    }

    /// `amount × part ÷ whole`, rounded UP -- the direction a forfeit must round.
    function _mulDivUp(uint256 amount, uint256 part, uint256 whole) internal pure returns (uint256) {
        return Math.mulDiv(amount, part, whole, Math.Rounding.Ceil);
    }
}
