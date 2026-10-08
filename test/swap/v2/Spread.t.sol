// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {V2Base} from "./V2Base.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {MockBase} from "../../../src/mock/MockBase.sol";
import {MockQuote} from "../../../src/mock/MockQuote.sol";
import {AssetGenerator} from "../../../src/asset/AssetGenerator.sol";
import {BandPool} from "../../../src/swap/BandPool.sol";
import {IBandPool} from "../../../src/swap/interfaces/IBandPool.sol";

/**
 * The push model, end to end through the REAL engine and AssetGenerator.
 *
 * A band stores a fraction of the pair's limit; the pool stores the limit, and only
 * `syncLimit` writes it. The engine calls it from `addPair` and `setSpread(isMkt)`, the
 * generator from its pair-config setters -- each in the same transaction as the change --
 * so no band ever quotes against a limit the engine no longer applies.
 */
contract V2SpreadTest is V2Base {
    bytes32 internal constant SYNCED = keccak256("PairLimitSynced(uint32,uint32)");

    function _tolerances(uint8 band) internal view returns (uint32 buy, uint32 sell) {
        return pool.bandTolerances(band);
    }

    function test_addPairCreatesAndSyncsThePoolInOneTransaction() public {
        MockBase b = new MockBase("B2", "B2");
        MockQuote q = new MockQuote("Q2", "Q2");
        address lister = address(0x1157);

        vm.recordLogs();
        vm.prank(lister);
        matchingEngine.addPair(address(b), address(q), 5e8, 0, address(b), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        BandPool p = BandPool(poolFactory.getPool(address(b), address(q)));
        assertTrue(address(p) != address(0), "the pool exists");
        bool synced;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(p) && logs[i].topics[0] == SYNCED) synced = true;
        }
        assertTrue(synced, "and was synced in the same transaction");
        assertEq(p.pairLimit(true), 10000000, "the engine's default market spread");
        assertEq(p.pairLimit(false), 10000000);
        (uint32 tb,) = p.bandTolerances(0);
        assertEq(tb, 2000000, "the default 20% band is live the moment the pair is");
        assertEq(p.creator(), lister, "the lister is the pool's creator");
        assertEq(p.seedPrice(), 5e8);
    }

    function test_setSpreadMovesTheLimitAndEveryBandInOneTransaction() public {
        assertEq(pool.pairLimit(true), 10000000);
        vm.recordLogs();
        matchingEngine.setSpread(address(token1), address(token2), 2000000, 4000000, true);
        (uint256 count,) = _poolLog(vm.getRecordedLogs(), SYNCED);
        assertEq(count, 1, "one sync, whatever the ladder's length");

        assertEq(pool.pairLimit(true), 2000000);
        assertEq(pool.pairLimit(false), 4000000);
        uint32[3] memory fracs = [uint32(1000000), 3000000, 5000000];
        for (uint8 i = 0; i < 3; i++) {
            (uint32 tb, uint32 ts) = _tolerances(i);
            assertEq(tb, uint32((uint256(fracs[i]) * 2000000) / 1e8), "buy tolerance = frac x limit");
            assertEq(ts, uint32((uint256(fracs[i]) * 4000000) / 1e8), "sell tolerance = frac x limit");
        }

        // A position reads the same numbers.
        uint256 id = _mintBase(alice, _b(1), 10e18);
        IBandPool.BandView memory v = _slot(id, 1);
        assertEq(v.toleranceBuy, 60000);
        assertEq(v.toleranceSell, 120000);
    }

    function test_theLimitSpreadDoesNotMoveTheBands() public {
        matchingEngine.setSpread(address(token1), address(token2), 2000000, 2000000, false);
        assertEq(pool.pairLimit(true), 10000000, "bands follow the MARKET limit only");
    }

    /// A narrower limit fills the same band at a tighter price: more base for the same quote.
    function test_aNarrowerLimitFillsCloserToTheAnchor() public {
        _seedBands(1_000e18);
        uint256 snap = vm.snapshotState();
        uint256 wide = _buy(trader1, 1_000e18);
        vm.revertToState(snap);
        matchingEngine.setSpread(address(token1), address(token2), 1000000, 1000000, true);
        uint256 narrow = _buy(trader1, 1_000e18);
        assertGt(narrow, wide);
    }

    // ---------------------------------------------------------- idle thresholds

    function _defaultLadder() internal {
        uint32[] memory fracs = new uint32[](3);
        uint32[] memory mults = new uint32[](3);
        fracs[0] = 20000000;
        fracs[1] = 60000000;
        fracs[2] = 100000000;
        for (uint256 i = 0; i < 3; i++) {
            mults[i] = 100000000;
        }
        pool.configureBands(fracs, mults);
    }

    /**
     * A 20% band's buy tolerance is `2e7 * limit / 1e8`, which rounds to zero for any
     * limit below 5. Zero means "cannot express this band at 8 decimals": the band is
     * idle, and the swap starts at the next one, rather than quoting at the anchor.
     */
    function test_aBandWhoseToleranceRoundsToZeroIsSkipped() public {
        _defaultLadder();
        _seedBands(1_000e18);

        matchingEngine.setSpread(address(token1), address(token2), 4, 10000000, true);
        (uint32 tb0,) = _tolerances(0);
        (uint32 tb1,) = _tolerances(1);
        assertEq(tb0, 0, "20% of 4 rounds to zero");
        assertEq(tb1, 2, "60% of 4 does not");

        uint256 snap = vm.snapshotState();
        _buy(trader1, 10e18);
        (uint256 b0,) = pool.bandReserves(0);
        (uint256 b1,) = pool.bandReserves(1);
        assertEq(b0, 1_000e18, "band 0 is idle");
        assertLt(b1, 1_000e18, "band 1 filled instead");
        vm.revertToState(snap);

        // One unit more and band 0 is live again.
        matchingEngine.setSpread(address(token1), address(token2), 5, 10000000, true);
        (tb0,) = _tolerances(0);
        assertEq(tb0, 1);
        _buy(trader1, 10e18);
        (b0,) = pool.bandReserves(0);
        (b1,) = pool.bandReserves(1);
        assertLt(b0, 1_000e18, "band 0 fills");
        assertEq(b1, 1_000e18, "and band 1 is not reached");
    }

    /// A zero limit idles every band on that side: the swap finds nothing to fill.
    function test_aZeroLimitIdlesTheWholeSide() public {
        _seedBands(1_000e18);
        matchingEngine.setSpread(address(token1), address(token2), 0, 10000000, true);
        vm.startPrank(trader1);
        token2.approve(address(router), type(uint256).max);
        vm.expectRevert(BandPool.NoLiquidity.selector);
        router.swap(address(pool), 1e18, true, trader1, 0);
        vm.stopPrank();
    }

    /// On the sell side a tolerance of 100% would price at zero, so that band is idle too.
    function test_aSellToleranceOfTheWholeDenomIsIdle() public {
        _defaultLadder();
        // Two-sided in every band, so sells have quote to take.
        uint8[] memory bands = _b(0, 1, 2);
        _mint(alice, bands, _fill(3, 1_000e18), _fill(3, 100_000e18));
        matchingEngine.setSpread(address(token1), address(token2), 10000000, 100000000, true);
        (, uint32 ts2) = _tolerances(2);
        assertEq(ts2, 100000000, "the whole limit, which is 100%");

        (, uint256 q2Before) = pool.bandReserves(2);
        vm.startPrank(trader1);
        token1.approve(address(router), type(uint256).max);
        // More than bands 0 and 1 can absorb: the rest is left unfilled, not sold for nothing.
        router.swap(address(pool), 100_000e18, false, trader1, 0);
        vm.stopPrank();
        (, uint256 q2After) = pool.bandReserves(2);
        assertEq(q2After, q2Before, "band 2 paid nothing out");
        (, uint256 q1) = pool.bandReserves(1);
        assertEq(q1, 0, "band 1 was drained first");
    }

    // ------------------------------------------------------- the generator's cap

    /**
     * With the generator as the engine's incentive, a pair's limit is its creator's
     * slippage cap (bps, x 10,000 onto DENOM) when that is tighter than the spread. The
     * generator's setter syncs the pool itself; re-pointing the engine's incentive does
     * not, so between that admin change and the next sync `liveLimit` and `pairLimit`
     * differ -- and the permissionless `syncLimit` closes the gap.
     */
    function test_theGeneratorsSlippageCapIsPushedToThePool() public {
        AssetGenerator gen = new AssetGenerator(address(this), address(matchingEngine));
        // Pair policy is also written to the engine, which needs the generator as feeManager.
        matchingEngine.setFeeManager(address(gen));

        // Configured before the engine consults the generator: synced, but nothing changes yet.
        gen.setExistingPairTradingConfig(address(token1), address(token2), 10, 0, 50_000);
        assertEq(pool.pairLimit(true), 10000000);

        matchingEngine.setIncentive(address(gen));
        assertEq(pool.liveLimit(true), 100000, "10 bps is 0.1% of DENOM");
        assertEq(pool.pairLimit(true), 10000000, "stale until someone syncs");

        vm.prank(address(0xBAD));
        pool.syncLimit();
        assertEq(pool.pairLimit(true), 100000);
        assertEq(pool.pairLimit(false), 100000);

        // From here the generator's own setter moves every band in its transaction.
        gen.setExistingPairTradingConfig(address(token1), address(token2), 20, 0, 50_000);
        assertEq(pool.pairLimit(true), 200000);
        (uint32 tb2,) = _tolerances(2);
        assertEq(tb2, 10000, "the 5% band of a 0.2% limit is 0.01%");
        assertEq(pool.liveLimit(true), pool.pairLimit(true));
    }

    /// The cap only ever narrows: a cap wider than the spread leaves the spread in charge.
    function test_aCapWiderThanTheSpreadLeavesTheSpread() public {
        AssetGenerator gen = new AssetGenerator(address(this), address(matchingEngine));
        // Pair policy is also written to the engine, which needs the generator as feeManager.
        matchingEngine.setFeeManager(address(gen));
        matchingEngine.setIncentive(address(gen));
        matchingEngine.setSpread(address(token1), address(token2), 500000, 500000, true); // 0.5%
        gen.setExistingPairTradingConfig(address(token1), address(token2), 100, 0, 50_000); // 1%
        assertEq(pool.pairLimit(true), 500000);
    }
}
