// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {BandSwapRouter} from "../../src/swap/BandSwapRouter.sol";
import {BandPoolFactory} from "../../src/swap/BandPoolFactory.sol";
import {BandPositionManager} from "../../src/swap/BandPositionManager.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";
import {WalkTok, PricedBook, CountEngine} from "./GasBandCount.t.sol";

/**
 * Band spacing sets a FLOOR on a usable slippage tolerance.
 *
 * A curve AMM moves price continuously, so a small change in pool state between
 * quote and execution costs a taker a small amount. Bands quantise price: every unit
 * inside one fills at that band's bound and not a fraction worse. So when the state
 * shifts by one band -- somebody else's trade drains band 0 before yours lands -- the
 * execution price does not drift, it STEPS.
 *
 * Which means a slippage tolerance smaller than one step cannot survive being pushed
 * out a band, however calm the market is. The tolerance is not really protecting
 * against price movement here; it is deciding whether the taker will accept the next
 * band down. These tests measure the steps rather than reasoning about them.
 *
 * Bands do NOT adapt to the tolerance -- they are creator-set and identical for every
 * taker, because every unit in a band must earn identically or one accumulator cannot
 * describe it. The adaptation available is the creator's: choose spacing whose steps
 * fit inside the slippage the venue actually defaults to.
 *
 * The engine's limit is 0.5% here, so the factory's default fractions (20 / 60 / 100%)
 * are the 0.10 / 0.30 / 0.50% ladder these steps were measured on. A creator re-spacing
 * the ladder now writes fractions of that limit, not absolute tolerances.
 */
contract BandSlippageStepTest is Test {
    BandPoolFactory factory;
    BandPositionManager manager;
    BandPool pool;
    BandSwapRouter router;
    WalkTok baseTok;
    WalkTok quoteTok;
    CountEngine eng;

    address lp = address(0xA11CE);
    address taker = address(0xABCD);
    address frontrunner = address(0xF00D);

    /// Each band gets this much base, so a trade of ~2x it steps out one band.
    uint256 constant PER_BAND = 100e18;

    uint32 constant LIMIT = 500000; // 0.5%

    function setUp() public {
        router = new BandSwapRouter();
        baseTok = new WalkTok();
        quoteTok = new WalkTok();
        eng = new CountEngine();
        eng.setSwapRouter(address(router));
        eng.setSpread_(LIMIT);
        manager = new BandPositionManager();
        manager.initialize("");
        factory = new BandPoolFactory();
        factory.initialize(address(eng), address(manager), address(new BandPool()), address(0xC0FFEE));
        eng.setPoolFactory(address(factory));
        manager.setPoolFactory(address(factory));
        address book = address(new PricedBook());
        vm.prank(address(eng));
        pool = BandPool(factory.createPool(address(baseTok), address(quoteTok), book, address(0)));
        pool.syncLimit();
        vm.warp(1_000_000);

        // Fund all three bands equally, in one position: 0.10%, 0.30%, 0.50%.
        uint8[] memory bands = new uint8[](3);
        uint256[] memory baseAmts = new uint256[](3);
        for (uint8 i = 0; i < 3; i++) {
            bands[i] = i;
            baseAmts[i] = PER_BAND;
        }
        baseTok.mint(lp, PER_BAND * 3);
        vm.startPrank(lp);
        baseTok.approve(address(manager), type(uint256).max);
        manager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: baseAmts,
                quoteAmounts: new uint256[](3),
                minShares: new uint128[](3),
                recipient: lp,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    function _buy(address who, uint256 quoteIn, uint256 minOut) internal returns (uint256) {
        quoteTok.mint(who, quoteIn);
        vm.startPrank(who);
        quoteTok.approve(address(pool), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        uint256 out = router.swap(address(pool), quoteIn, true, who, minOut);
        vm.stopPrank();
        return out;
    }

    /// What `amountIn` would deliver against the CURRENT pool, without keeping the trade.
    function _quote(uint256 quoteIn) internal returns (uint256 out) {
        uint256 snap = vm.snapshotState();
        out = _buy(address(0xDEAD), quoteIn, 0);
        vm.revertToState(snap);
    }

    /// bps by which `after_` falls short of `before_`.
    function _shortfallBps(uint256 before_, uint256 after_) internal pure returns (uint256) {
        return ((before_ - after_) * 10000) / before_;
    }

    // ---- the size of one step ------------------------------------------------

    /**
     * The whole point, in numbers. Quote a trade that fills in band 0, let somebody
     * else take band 0 first, and re-quote: the SAME trade now costs a discrete
     * amount more, and that amount is the step, not a drift.
     */
    function test_beingPushedOutOneBandIsAStepNotADrift() public {
        uint256 size = 150e18; // ~75 base, comfortably inside band 0's 100
        uint256 quoted = _quote(size);

        // Someone drains band 0 ahead of us.
        _buy(frontrunner, 210e18, 0);

        uint256 requoted = _quote(size);
        uint256 step01 = _shortfallBps(quoted, requoted);
        console2.log("band 0 -> band 1 step, bps:", step01);

        // 29-30 bps, and the decomposition matters: 19.9 of it is the price gap
        // (0.10% -> 0.30%) and 10.0 is the FEE gap (1x -> 2x). The premium is part of
        // the step a taker faces, not something separate from it.
        assertGt(step01, 25, "a real step, not rounding");
        assertLt(step01, 35, "price gap plus fee gap, nothing else");
    }

    /**
     * The ladder is UNIFORM now, and that is the point of the re-spacing.
     *
     * This test used to assert the opposite -- that 0.30% to 1.00% was a much bigger
     * jump than 0.10% to 0.30% -- because it was: 89.2 bps against 29.9, and the wide
     * one was past what a default-slippage taker would accept. At 0.50% and 3x both
     * rungs cost the same to cross, so no step is the one that quietly fails.
     */
    function test_everyRungOfTheLadderCostsTheSameToCross() public {
        uint256 size = 150e18;
        uint256 quoted = _quote(size);
        _buy(frontrunner, 210e18, 0);
        uint256 step01 = _shortfallBps(quoted, _quote(size));

        uint256 inBand1 = _quote(size);
        _buy(frontrunner, 210e18, 0);
        uint256 step12 = _shortfallBps(inBand1, _quote(size));

        console2.log("band 0 -> 1, bps:", step01);
        console2.log("band 1 -> 2, bps:", step12);
        assertApproxEqAbs(step12, step01, 2, "the rungs are the same height");
        assertLt(step12, 50, "and both fit inside the venue's 0.5% default");
    }

    // ---- what each tolerance survives ----------------------------------------

    /// 0.05%: smaller than any step in this ladder, so a one-band shift reverts it.
    function test_aFiveBasisPointToleranceCannotSurviveAOneBandShift() public {
        uint256 size = 150e18;
        uint256 quoted = _quote(size);
        uint256 minOut = (quoted * 9995) / 10000; // 0.05%

        _buy(frontrunner, 210e18, 0); // band 0 gone

        quoteTok.mint(taker, size);
        vm.startPrank(taker);
        quoteTok.approve(address(pool), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        vm.expectPartialRevert(BandPool.SlippageExceeded.selector);
        router.swap(address(pool), size, true, taker, minOut);
        vm.stopPrank();
    }

    /// 0.5% -- the venue default -- absorbs the 0 -> 1 step comfortably.
    function test_theDefaultHalfPercentSurvivesTheTightStep() public {
        uint256 size = 150e18;
        uint256 quoted = _quote(size);
        uint256 minOut = (quoted * 9950) / 10000; // 0.50%

        _buy(frontrunner, 210e18, 0);

        uint256 got = _buy(taker, size, minOut);
        assertGt(got, minOut, "the trade goes through");
    }

    /**
     * ...and now absorbs the wide step too, which it did not before the re-spacing.
     * This test asserted a revert when band 2 sat at 1.00%: the step into it was 89.2
     * bps and a default-slippage taker was refused by their own bound while the
     * liquidity sat there. At 0.50% the same shift goes through.
     */
    function test_theDefaultHalfPercentNowSurvivesTheWideStepToo() public {
        _buy(frontrunner, 210e18, 0); // now quoting in band 1
        uint256 size = 150e18;
        uint256 quoted = _quote(size);
        uint256 minOut = (quoted * 9950) / 10000; // 0.50%

        _buy(frontrunner, 210e18, 0); // band 1 gone too

        uint256 got = _buy(taker, size, minOut);
        assertGt(got, minOut, "the fill the old spacing refused");
    }

    /**
     * The creator's lever, still there. A ladder can be re-spaced live, over funded
     * bands, and the very next swap prices off the new spacing.
     */
    function test_theCreatorCanStillReSpaceTheLadder() public {
        // 0.10 / 0.20 / 0.30%, written as 20 / 40 / 60% of the 0.5% limit.
        uint32[] memory t = new uint32[](3);
        t[0] = 20000000; t[1] = 40000000; t[2] = 60000000;
        uint32[] memory m = new uint32[](3);
        m[0] = 100000000; m[1] = 150000000; m[2] = 200000000;
        vm.prank(address(0xC0FFEE));
        pool.configureBands(t, m);
        (uint32 tol2,) = pool.bandTolerances(2);
        assertEq(tol2, 300000, "band 2 now quotes 0.30%");

        _buy(frontrunner, 210e18, 0);
        uint256 size = 150e18;
        uint256 quoted = _quote(size);
        _buy(frontrunner, 210e18, 0);
        uint256 got = _buy(taker, size, (quoted * 9950) / 10000);
        assertGt(got, 0, "a tighter ladder still clears the default tolerance");
    }
}
