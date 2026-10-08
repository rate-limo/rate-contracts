// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * The fee arithmetic for an aggregated pool.
 *
 * Every function here is pure, which is the point: the reason the pool can afford
 * ONE accumulator per band instead of one storage write per position is that none
 * of this depends on WHICH position is asking -- only on its liquidity and its age.
 * The moment a term needs to know the position's identity, fungibility is gone and
 * so is the accumulator.
 */
library PoolFeeMath {
    uint256 internal constant Q128 = 1 << 128;

    /**
     * Fee growth to add per unit of liquidity, Q128-scaled.
     *
     * Zero liquidity returns zero rather than reverting. A swap can cross a band
     * that momentarily holds nothing, and the caller sends that fee to feeTo
     * instead; reverting here would let an empty band halt an otherwise valid swap.
     */
    function growthDelta(uint256 amount, uint256 liquidity) internal pure returns (uint256) {
        if (liquidity == 0) return 0;
        return Math.mulDiv(amount, Q128, liquidity);
    }

    /**
     * The vesting ramp numerator, over `denom`. 0 at mint, `denom` at maturity, and
     * never more -- a fraction KEPT cannot exceed what was earned.
     *
     * The 1.5x that used to exist was a settlement WEIGHT, not a fraction: it bought
     * a mature position more flow per dollar. That has no expression here and is not
     * coming back through this function.
     */
    function vestedNumerator(uint256 age, uint256 maturity, uint256 denom)
        internal
        pure
        returns (uint256)
    {
        if (maturity == 0 || age >= maturity) return denom;
        return Math.mulDiv(age, denom, maturity);
    }

    /** What a position is owed before vesting, from growth accrued since it last looked. */
    function rawEntitlement(uint256 liquidity, uint256 growthNow, uint256 growthLast)
        internal
        pure
        returns (uint256)
    {
        if (growthNow <= growthLast || liquidity == 0) return 0;
        return Math.mulDiv(growthNow - growthLast, liquidity, Q128);
    }

    /**
     * Split a raw entitlement into what is kept and what is forfeited.
     *
     * `forfeit` is derived by subtraction rather than by a second mulDiv, so the two
     * always sum to `raw` exactly -- fees are conserved by construction rather than
     * by two roundings happening to agree. `vested` rounds DOWN, which puts the dust
     * on the forfeit side where it flows back to the other LPs: the one direction a
     * claimant cannot profit from by choosing when to call.
     */
    function split(uint256 raw, uint256 vestedNum, uint256 denom)
        internal
        pure
        returns (uint256 vested, uint256 forfeit)
    {
        vested = Math.mulDiv(raw, vestedNum, denom);
        forfeit = raw - vested;
    }
}
