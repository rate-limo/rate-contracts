// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandBaseSetup} from "./BandBaseSetup.sol";
import {Vm} from "forge-std/Vm.sol";

/// The generator's slippage hook, as the engine and the pool both read it: a cap in bps.
contract SlippagePolicy {
    uint256 public bps;

    function setBps(uint256 b) external {
        bps = b;
    }

    function slippageLimitOf(address, address) external view returns (uint256) {
        return bps;
    }
}

/**
 * The pair's spread moves every band, and it does so in the transaction that changes it.
 *
 * v1 gated deposits: a band whose absolute tolerance reached past the market spread
 * refused liquidity, and the ladder was fitted to the spread once, at the first deposit,
 * then frozen. Narrow the spread after that and bands sat beyond reach -- refusing
 * deposits, filling at prices the rail would not record.
 *
 * v2 stores each band as a FRACTION of the pair's limit. The limit is the engine's
 * market spread for that side, capped by the incentive policy's `slippageLimitOf`, and
 * the pool holds a copy that `syncLimit` refreshes. `MatchingEngine.setSpread(isMkt =
 * true)` calls it through the factory, so a spread change and the band move are one
 * transaction. There is no gate left because there is nothing for it to catch: every
 * band is inside the limit by construction, whatever the limit becomes.
 *
 * What this file pins, on the REAL engine:
 *   - a market-spread change syncs the pool in the same transaction;
 *   - a LIMIT-spread change does not, because the rail clamps to the market one;
 *   - narrowing moves every band inside the new limit and strands nobody;
 *   - an incentive cap below the spread wins, once synced.
 */
contract BandSpreadGateTest is BandBaseSetup {
    uint32 constant PRODUCTION = 100000; // 0.1% of DENOM
    uint32 constant WIDE = 10000000; // 10%, what the fixture ships

    event PairLimitSynced(uint32 limitBuy, uint32 limitSell);

    function _setSpread(uint32 s) internal {
        matchingEngine.setSpread(address(token1), address(token2), s, s, true);
    }

    /// A one-band top-up of the seeded position, as its owner would make it.
    function _deposit(uint8 band, uint256 amount) internal {
        uint8[] memory bands = new uint8[](1);
        uint256[] memory base_ = new uint256[](1);
        uint256[] memory quote_ = new uint256[](1);
        uint128[] memory minShares = new uint128[](1);
        bands[0] = band;
        base_[0] = amount;
        vm.prank(lp1);
        positionManager.increaseLiquidity(lpToken, bands, base_, quote_, minShares, block.timestamp);
    }

    function _shipLadder() internal {
        pool.configureBands(poolFactory.defaultSpreadFracs(), poolFactory.defaultFeeMultipliers());
    }

    // ---- the sync ------------------------------------------------------------

    /// `setSpread(isMkt = true)` is the whole mechanism: the pool's limit is current
    /// before the call returns, with no second transaction for anyone to forget.
    function test_setSpreadSyncsThePoolInTheSameTransaction() public {
        assertEq(pool.pairLimit(true), WIDE, "addPair synced the listing's default spread");

        vm.expectEmit(address(pool));
        emit PairLimitSynced(PRODUCTION, 300000);
        matchingEngine.setSpread(address(token1), address(token2), PRODUCTION, 300000, true);

        assertEq(pool.pairLimit(true), PRODUCTION, "buy side synced");
        assertEq(pool.pairLimit(false), 300000, "sell side synced");
        assertEq(pool.liveLimit(true), pool.pairLimit(true), "nothing left pending");
    }

    /**
     * The LIMIT spread bounds where a resting order may be made; a band never makes one.
     * What a band does is fill a swap whose report the rail clamps with the MARKET
     * spread, so that is the one the pool follows -- and only a market change syncs it.
     */
    function test_theLimitSpreadDoesNotMoveThePool() public {
        vm.recordLogs();
        matchingEngine.setSpread(address(token1), address(token2), PRODUCTION, PRODUCTION, false);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].emitter != address(pool), "the pool heard nothing");
        }
        assertEq(pool.pairLimit(true), WIDE, "still the market spread");
        assertEq(pool.liveLimit(true), WIDE, "and that is still the live limit");
    }

    // ---- narrowing -----------------------------------------------------------

    /**
     * At the production spread the shipped ladder (20 / 60 / 100% of the limit) quotes
     * 0.02 / 0.06 / 0.10% -- the numbers v1's one-shot scale produced, now produced by
     * multiplication on every swap. And every band takes liquidity, the widest included:
     * it sits exactly on the spread, never past it.
     */
    function test_atTheProductionSpreadTheLadderShrinksToFit() public {
        _shipLadder();
        _setSpread(PRODUCTION);

        (uint32 t0,) = pool.bandTolerances(0);
        (uint32 t1,) = pool.bandTolerances(1);
        (uint32 t2,) = pool.bandTolerances(2);
        assertEq(t0, 20000, "0.02% -- 20% of the 0.10% spread");
        assertEq(t1, 60000, "0.06% -- 60%");
        assertEq(t2, PRODUCTION, "0.10% -- 100%, exactly the spread");

        _seedBands(100e18);
        for (uint8 i = 0; i < 3; i++) {
            (, uint256 shares,,,) = pool.bands(i);
            assertGt(shares, 0, "every band takes liquidity");
        }
    }

    /// Narrowing after liquidity is in moves every band inside the new limit, in place.
    function test_narrowingMovesEveryBandInsideTheNewLimit() public {
        _seedBands(100e18);
        (uint32 wideT2,) = pool.bandTolerances(2);
        assertEq(wideT2, 500000, "0.50% under the fixture's 10%");

        _setSpread(PRODUCTION);
        for (uint8 i = 0; i < 3; i++) {
            (uint32 frac,,,,) = pool.bands(i);
            (uint32 tb, uint32 ts) = pool.bandTolerances(i);
            assertEq(tb, uint32((uint256(frac) * PRODUCTION) / 1e8), "its fraction of the new limit");
            assertEq(ts, tb, "on both sides");
            assertLe(tb, PRODUCTION, "inside the limit");
        }
        (uint32 t2,) = pool.bandTolerances(2);
        assertEq(t2, 5000, "band 2 moved from 0.50% to 0.005%, one hundredfold, with the limit");
    }

    /// The v1 pin is gone: widening re-prices the bands just as narrowing does.
    function test_wideningTheSpreadMovesTheBandsOutToo() public {
        _setSpread(PRODUCTION);
        _seedBands(100e18);

        _setSpread(WIDE);
        (uint32 t2,) = pool.bandTolerances(2);
        assertEq(t2, 500000, "back to 0.50% -- a band is a fraction, not a snapshot");
    }

    /// There is no refusal left: after narrowing, the widest band takes a top-up.
    function test_aDepositIsAcceptedAfterNarrowing() public {
        _seedBands(100e18);
        _setSpread(PRODUCTION);

        (, uint256 before_,,,) = pool.bands(2);
        _deposit(2, 100e18);
        (, uint256 after_,,,) = pool.bands(2);
        assertGt(after_, before_, "nothing is beyond reach, so nothing is refused");
    }

    /// Each side follows its own limit; the tighter side no longer governs both.
    function test_eachSideFollowsItsOwnLimit() public {
        matchingEngine.setSpread(address(token1), address(token2), WIDE, PRODUCTION, true);

        (uint32 tb, uint32 ts) = pool.bandTolerances(2);
        assertEq(tb, 500000, "buys quote 5% of the 10% buy limit");
        assertEq(ts, 5000, "sells quote 5% of the 0.1% sell limit");
    }

    /// The creator's fractions are theirs: a spread change moves what they mean, never them.
    function test_anExplicitLadderSurvivesASpreadChange() public {
        uint32[] memory fracs = new uint32[](2);
        uint32[] memory mults = new uint32[](2);
        fracs[0] = 40000000; // 40% of the limit
        fracs[1] = 90000000; // 90%
        mults[0] = 100000000;
        mults[1] = 200000000;
        pool.configureBands(fracs, mults);

        _setSpread(PRODUCTION);
        (uint32 f0,,,,) = pool.bands(0);
        (uint32 t0,) = pool.bandTolerances(0);
        assertEq(f0, 40000000, "the creator said 40% and it is still 40%");
        assertEq(t0, 40000, "which now means 0.04%");
    }

    // ---- what narrowing must NOT do ------------------------------------------

    /**
     * An LP already in a band must still be able to get out when the spread moves under
     * them. Narrowing strands nobody -- the same rule setBandOpen follows.
     */
    function test_narrowingTheSpreadStrandsNobody() public {
        uint256 id = _seedBands(500e18); // seeded while the fixture's 10% spread is in force
        vm.warp(block.timestamp + 601);
        _buy(trader1, 5_000e18); // give the bands something to have earned

        _setSpread(PRODUCTION); // every band moves a hundredfold tighter

        // Claiming and withdrawing both still work.
        vm.startPrank(lp1);
        positionManager.collect(id, lp1);
        (uint256 baseOut,) = positionManager.decreaseLiquidity(id, 10_000, 0, 0, lp1, block.timestamp);
        vm.stopPrank();
        assertGt(baseOut, 0, "an existing position exits whatever the spread became");
        assertEq(pool.bandMaskOf(id), 0, "and it is fully out");
    }

    /// And a narrowed band still FILLS for whoever is in it, at its new bound.
    function test_aNarrowedBandStillSettles() public {
        _seedBands(100e18);
        vm.warp(block.timestamp + 601);
        _setSpread(PRODUCTION);

        uint256 out = _buy(trader1, 60_000e18); // large enough to reach band 2
        assertGt(out, 0);
        (uint256 r2,) = pool.bandReserves(2);
        assertLt(r2, 100e18, "band 2 traded");
    }

    /**
     * v1's closing case here asserted the rail still clamped a band quoting past the
     * spread. None can now: on the shipped ladder the widest band sits ON the rail, so
     * after narrowing a sweep prints exactly the block-open ceiling and no further.
     */
    function test_afterNarrowingTheWidestBandPrintsOnTheRailNotPastIt() public {
        _shipLadder();
        _seedBands(1_000e18);
        vm.warp(block.timestamp + 601);
        vm.roll(block.number + 1); // out of the listing block, so the rail has a block open
        _setSpread(PRODUCTION);

        assertEq(_lmp(), LISTING);
        _buy(trader1, 250_000e18);
        assertEq(_lmp(), (LISTING * (1e8 + PRODUCTION)) / 1e8, "one step, and it is what band 2 traded at");
    }

    // ---- the incentive cap ---------------------------------------------------

    /**
     * A generated pair's creator caps slippage below the spread. The engine applies that
     * cap to every market order; the pool mirrors it. `setIncentive` is an admin change
     * neither the engine nor the generator syncs, so `liveLimit` shows it at once and
     * `pairLimit` follows on the permissionless `syncLimit`.
     */
    function test_anIncentiveCapBelowTheSpreadWinsAfterSync() public {
        _setSpread(PRODUCTION);
        SlippagePolicy policy = new SlippagePolicy();
        policy.setBps(5); // 0.05%, under the 0.10% spread
        matchingEngine.setIncentive(address(policy));

        assertEq(pool.liveLimit(true), 50000, "the cap, as the engine now applies it");
        assertEq(pool.pairLimit(true), PRODUCTION, "not yet synced");

        pool.syncLimit();
        assertEq(pool.pairLimit(true), 50000, "the cap wins on the buy side");
        assertEq(pool.pairLimit(false), 50000, "and on the sell side");
        (uint32 t0,) = pool.bandTolerances(0);
        assertEq(t0, 500, "band 0 is 1% of the capped limit");
    }

    /// A cap above the spread changes nothing: the spread is still the tighter bound.
    function test_anIncentiveCapAboveTheSpreadLeavesTheSpread() public {
        _setSpread(PRODUCTION);
        SlippagePolicy policy = new SlippagePolicy();
        policy.setBps(50); // 0.50%
        matchingEngine.setIncentive(address(policy));

        pool.syncLimit();
        assertEq(pool.pairLimit(true), PRODUCTION, "the spread still binds");
    }
}
