// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandBaseSetup} from "./BandBaseSetup.sol";
import {Oracle} from "../../src/exchange/libraries/Oracle.sol";
import {BandPool} from "../../src/swap/BandPool.sol";

/**
 * Oracle seeding, against the real Orderbook.
 *
 * This coverage came from TwapSeeding.t.sol, which was written for `Pool` and went
 * with it. What it pins is not Pool's: `Oracle.initialize` writes a TIME ANCHOR and no
 * price, the listing's own setLmp adds nothing because Oracle.write no-ops within a
 * timestamp, and a quiet pair's TWAP is therefore the listing price to the wei. All of
 * that still ships and still decides where every band sits.
 */
contract BandOracleSeedingTest is BandBaseSetup {
    function test_theSeedIsATimeAnchorNotAPrice() public view {
        assertEq(book.lmp(), LISTING, "the listing price lives in lmp, not the oracle");
    }

    /// A fresh pair has no history for ANY window, not merely for the pool's 300s.
    function test_aFreshPairCannotAnswerAnyWindow() public {
        vm.expectRevert(abi.encodeWithSelector(Oracle.InsufficientHistory.selector, uint32(300), uint32(0)));
        book.twap(300);
        vm.expectRevert(abi.encodeWithSelector(Oracle.InsufficientHistory.selector, uint32(1), uint32(0)));
        book.twap(1);
    }

    function test_theWindowMustElapseBeforeItIsAnswerable() public {
        vm.warp(block.timestamp + 299);
        vm.expectRevert(abi.encodeWithSelector(Oracle.InsufficientHistory.selector, uint32(300), uint32(299)));
        book.twap(300);

        vm.warp(block.timestamp + 1);
        (uint256 price, uint32 window) = book.twap(300);
        assertEq(window, 300);
        assertEq(price, LISTING, "and the average is the listing price, exactly");
    }

    /// The returned window is a floor, not a promise -- it stretches on a quiet pair.
    function test_theWindowIsAFloorNotAPromise() public {
        vm.warp(block.timestamp + 3000);
        (uint256 price, uint32 window) = book.twap(300);
        assertEq(window, 3000, "asked for 300, got 3000");
        assertEq(price, LISTING, "no activity means no drift, ever");
    }

    /**
     * And the reason BandPool does not care. `Pool` failed closed for its first 600
     * seconds on exactly the revert above; a band pool captures the listing price at
     * creation and trades from the block it was listed in.
     */
    function test_thePoolIsSwappableBeforeTheOracleCanAnswer() public {
        assertEq(pool.seedPrice(), LISTING, "captured from the same transaction as the listing");
        _seedBands(1_000e18);
        uint256 out = _buy(trader1, 1_000e18);
        assertGt(out, 0, "listed this block, swappable this block");
    }
}

/**
 * The `lmp` rail, through the band router and the REAL MatchingLib.
 *
 * This is what SwapPriceReport / SwapPriceReportEdges covered for `Pool`. The rail is
 * shared code that still ships, and after the deletion nothing else exercised it --
 * BandPriceReportCases mirrors the arithmetic against a stub, which cannot catch the
 * library changing underneath it.
 *
 * In v2 the pool's bands are fractions of the same market spread the rail clamps to, so
 * at a steady anchor the pool cannot trade past the rail at all: its widest band sits ON
 * it. These cases therefore run on the factory's shipped ladder (20 / 60 / 100% of the
 * limit), which puts band 2 exactly on the ceiling. Where the rail still refuses a print
 * -- the TWAP lagging a book that has moved -- is BandSpreadSide's subject.
 */
contract BandRailTest is BandBaseSetup {
    uint32 constant PRODUCTION_SPREAD = 100000; // 0.1% of DENOM

    function setUp() public override {
        super.setUp();
        pool.configureBands(poolFactory.defaultSpreadFracs(), poolFactory.defaultFeeMultipliers());
        vm.warp(block.timestamp + 600); // let the oracle answer, so the TWAP is real
        // Out of the listing block: its setLmp opened the block from zero, so until the
        // next block the rail anchors on the LIVE lmp rather than a block open.
        vm.roll(block.number + 1);
        // No order constraint any more: a deposit is never refused for the spread. The
        // spread moves every band when it changes, in the same transaction.
        _seedBands(1_000e18);
        matchingEngine.setSpread(address(token1), address(token2), PRODUCTION_SPREAD, PRODUCTION_SPREAD, true);
    }

    function _ceiling() internal pure returns (uint256) {
        return (LISTING * (1e8 + PRODUCTION_SPREAD)) / 1e8;
    }

    function test_aRealSwapPrintsAPrice() public {
        assertEq(_lmp(), LISTING);
        _buy(trader1, 500e18);
        assertGt(_lmp(), LISTING, "the loop closed: a pool trade moved the book");
    }

    /**
     * One step, however deep the swap. v1 showed this as a clamp -- band 2 traded at
     * 0.50% and the rail recorded 0.10%. In v2 band 2 IS the rail, so a sweep trades
     * and records the same ceiling: nothing to clamp, and nothing lost between them.
     */
    function test_aSweepLandsExactlyOnTheBlockOpenCeiling() public {
        (uint32 widest,) = pool.bandTolerances(2);
        assertEq(widest, PRODUCTION_SPREAD, "the widest band sits on the rail");

        _buy(trader1, 250_000e18); // through bands 0 and 1 and into band 2
        (uint256 r2,) = pool.bandReserves(2);
        assertLt(r2, 1_000e18, "band 2 filled");
        assertEq(_lmp(), _ceiling(), "one step, and exactly the price band 2 traded at");
    }

    /// Several swaps inside one block are bounded together, not cap-by-cap.
    function test_aBatchInOneBlockIsBoundedAsABatch() public {
        for (uint256 i = 0; i < 4; i++) _buy(trader1, 70_000e18); // the fourth reaches band 2
        assertEq(_lmp(), _ceiling(), "four prints, one block, one step");
    }

    /// ...and the cap re-arms next block, so honest sustained flow is not frozen out.
    function test_theCapReArmsEachBlock() public {
        _buy(trader1, 5_000e18);
        uint256 afterOne = _lmp();
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        _buy(trader1, 5_000e18);
        assertGt(_lmp(), afterOne, "a second block earns a second step");
    }

    /// Dust fills at the band bound and does not get to set the market.
    function test_dustFillsButDoesNotPrint() public {
        uint256 out = _buy(trader1, 210);
        assertEq(_lmp(), LISTING, "the public reference is untouched");
        // Whether 210 wei even rounds to an output is the book's business; what matters
        // is that it did not move the price either way.
        out;
    }

    /**
     * A zero spread freezes the reference entirely -- in v2 one step earlier than the
     * rail. The pool's limit is the spread, so every band's tolerance is zero and every
     * band idles: nothing trades, so nothing is reported. The rail's own zero-spread
     * branch is pinned directly in BandEightCases case 7.
     */
    function test_aZeroSpreadFreezesThePrice() public {
        matchingEngine.setSpread(address(token1), address(token2), 0, 0, true);
        assertEq(pool.pairLimit(true), 0, "synced to zero in the same transaction");

        vm.startPrank(trader1);
        token2.approve(address(router), type(uint256).max);
        vm.expectRevert(BandPool.NoLiquidity.selector);
        router.swap(address(pool), 5_000e18, true, trader1, 0);
        vm.stopPrank();
        assertEq(_lmp(), LISTING, "nothing traded, so nothing printed");
    }
}
