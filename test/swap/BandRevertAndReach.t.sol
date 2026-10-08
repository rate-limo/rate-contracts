// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {BandSwapRouter} from "../../src/swap/BandSwapRouter.sol";
import {BandPoolFactory} from "../../src/swap/BandPoolFactory.sol";
import {BandPositionManager} from "../../src/swap/BandPositionManager.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";
import {WalkTok, CountEngine} from "./GasBandCount.t.sol";

/// Honours the bound, and can be told to fail the way an uninitialised oracle does.
contract FlakyBook {
    error NotInitialized();

    uint256 public price = 2e8;
    bool public dead;

    function setDead(bool d) external { dead = d; }

    /// The listing price the pool anchors to until the TWAP can answer.

    function lmp() external view returns (uint256) { return price; }


    function twap(uint32) external view returns (uint256, uint32) {
        if (dead) revert NotInitialized();
        return (price, 300);
    }

    function convert(uint256 p, uint256 amount, bool isBid) external pure returns (uint256) {
        return isBid ? (amount * p) / 1e8 : (amount * 1e8) / p;
    }
}

/**
 * Two questions, both answered by measurement rather than by argument.
 *
 *  1. "If liquidity exists in a band the price can reach, the swap can never revert."
 *     Nearly true, and the exceptions are the interesting part.
 *
 *  2. "So bands 1 and 2 are never used when slippage is 0.05%."
 *     No -- and this is the one worth being precise about. A tight tolerance does not
 *     refuse the wide bands. It refuses being MOVED between quoting and executing. A
 *     trade quoted across all three bands fills across all three at 0.05%, because the
 *     quote it is measured against already included them.
 *
 * The engine's limit is 0.5%, so the factory's default fractions (20 / 60 / 100%) are
 * the 0.10 / 0.30 / 0.50% ladder.
 */
contract BandRevertAndReachTest is Test {
    BandPoolFactory factory;
    BandPositionManager manager;
    BandPool pool;
    BandSwapRouter router;
    WalkTok baseTok;
    WalkTok quoteTok;
    FlakyBook book;
    CountEngine eng;

    address lp = address(0xA11CE);
    address taker = address(0xABCD);
    address other = address(0xF00D);

    uint256 constant PER_BAND = 100e18;
    uint32 constant LIMIT = 500000; // 0.5%

    function setUp() public {
        router = new BandSwapRouter();
        baseTok = new WalkTok();
        quoteTok = new WalkTok();
        eng = new CountEngine();
        eng.setSwapRouter(address(router));
        eng.setSpread_(LIMIT);
        book = new FlakyBook();
        manager = new BandPositionManager();
        manager.initialize("");
        factory = new BandPoolFactory();
        factory.initialize(address(eng), address(manager), address(new BandPool()), address(0xC0FFEE));
        eng.setPoolFactory(address(factory));
        manager.setPoolFactory(address(factory));
        vm.prank(address(eng));
        pool = BandPool(factory.createPool(address(baseTok), address(quoteTok), address(book), address(0)));
        pool.syncLimit();
        vm.warp(1_000_000);
    }

    function _fund(uint8 band, uint256 amt) internal {
        uint8[] memory bands = new uint8[](1);
        uint256[] memory baseAmts = new uint256[](1);
        bands[0] = band;
        baseAmts[0] = amt;
        baseTok.mint(lp, amt);
        vm.startPrank(lp);
        baseTok.approve(address(manager), type(uint256).max);
        manager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: baseAmts,
                quoteAmounts: new uint256[](1),
                minShares: new uint128[](1),
                recipient: lp,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    function _fundAll() internal {
        _fund(0, PER_BAND);
        _fund(1, PER_BAND);
        _fund(2, PER_BAND);
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

    /// What this trade delivers against the CURRENT pool, without keeping it.
    function _quote(uint256 quoteIn) internal returns (uint256 out) {
        uint256 snap = vm.snapshotState();
        out = _buy(address(0xDEAD), quoteIn, 0);
        vm.revertToState(snap);
    }

    // =====================================================================
    // 1. When liquidity exists, what can still revert?
    // =====================================================================

    /// The ordinary case: liquidity anywhere, an honest quote, and it fills.
    function test_withLiquidityAnywhereAnHonestlyQuotedSwapFills() public {
        _fund(2, PER_BAND); // ONLY the widest band is funded
        uint256 size = 50e18;
        uint256 quoted = _quote(size);
        // Even a 1 bps tolerance is fine, because the quote already priced band 2.
        uint256 got = _buy(taker, size, (quoted * 9999) / 10000);
        assertGt(got, 0, "the wide band alone can serve a trade");
        (uint256 r2,) = pool.bandReserves(2);
        assertLt(r2, PER_BAND, "and it is what moved");
    }

    /// NoLiquidity fires only when no band can pay out at all.
    function test_noLiquidityIsTheEmptyPoolCaseAndOnlyThat() public {
        quoteTok.mint(taker, 10e18);
        vm.startPrank(taker);
        quoteTok.approve(address(pool), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        vm.expectRevert(BandPool.NoLiquidity.selector);
        router.swap(address(pool), 10e18, true, taker, 0);
        vm.stopPrank();
    }

    /**
     * The first real exception. A band holding liquidity is not enough: the pool
     * prices off the orderbook TWAP, and an orderbook with no observation reverts
     * NotInitialized. A pool can be fully funded and still refuse every swap.
     */
    function test_aFundedPoolStillRevertsWhenTheOracleHasNoObservation() public {
        _fundAll();
        book.setDead(true);
        quoteTok.mint(taker, 10e18);
        vm.startPrank(taker);
        quoteTok.approve(address(pool), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        vm.expectRevert(FlakyBook.NotInitialized.selector);
        router.swap(address(pool), 10e18, true, taker, 0);
        vm.stopPrank();
    }

    /**
     * The second, and the only one the taker controls. Liquidity is there and the
     * price is reachable; the taker's own bound is what refuses it.
     */
    function test_theTakersOwnBoundIsTheOtherWayAFundedPoolRefuses() public {
        _fundAll();
        uint256 size = 50e18;
        uint256 quoted = _quote(size);
        quoteTok.mint(taker, size);
        vm.startPrank(taker);
        quoteTok.approve(address(pool), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        // demanding more than the pool can produce
        vm.expectRevert(abi.encodeWithSelector(BandPool.SlippageExceeded.selector, quoted + 1, quoted));
        router.swap(address(pool), size, true, taker, quoted + 1);
        vm.stopPrank();
    }

    // =====================================================================
    // 2. Are bands 1 and 2 unreachable at 0.05% slippage?
    // =====================================================================

    /**
     * THE ANSWER: no. A trade sized to span all three bands, quoted honestly and
     * executed with a 0.05% tolerance, fills -- and every band's reserve moves.
     *
     * The tolerance is measured against a quote that already walked bands 1 and 2,
     * so there is nothing for it to object to.
     */
    function test_allThreeBandsFillAtFiveBasisPointsOfSlippage() public {
        _fundAll();
        // ~250 base wanted against 100 per band: has to reach all three.
        uint256 size = 520e18;
        uint256 quoted = _quote(size);
        uint256 minOut = (quoted * 9995) / 10000; // 0.05%

        uint256 got = _buy(taker, size, minOut);

        (uint256 r0,) = pool.bandReserves(0);
        (uint256 r1,) = pool.bandReserves(1);
        (uint256 r2,) = pool.bandReserves(2);
        console2.log("band 0 left:", r0);
        console2.log("band 1 left:", r1);
        console2.log("band 2 left:", r2);

        assertGt(got, minOut, "the trade filled at 0.05%");
        assertEq(r0, 0, "band 0 emptied");
        assertEq(r1, 0, "band 1 emptied");
        assertLt(r2, PER_BAND, "and band 2 was used too");
    }

    /// Even a single-basis-point tolerance is fine when nothing moves in between.
    function test_evenOneBasisPointFillsWhenTheStateDoesNotChange() public {
        _fundAll();
        uint256 size = 520e18;
        uint256 quoted = _quote(size);
        uint256 got = _buy(taker, size, (quoted * 9999) / 10000);
        assertGt(got, 0, "a tight bound is not a ban on the wide bands");
    }

    /**
     * What 0.05% actually refuses. Identical trade, identical tolerance -- the only
     * difference is that somebody else's trade lands first and moves which band the
     * fill comes from. THAT is what a tolerance is for, and 0.05% is too small to
     * absorb one band of movement.
     */
    function test_whatFiveBasisPointsRefusesIsBeingMovedNotTheBandItself() public {
        _fundAll();
        uint256 size = 150e18;
        uint256 quoted = _quote(size); // fills in band 0
        uint256 minOut = (quoted * 9995) / 10000;

        _buy(other, 210e18, 0); // drains band 0 ahead of us

        quoteTok.mint(taker, size);
        vm.startPrank(taker);
        quoteTok.approve(address(pool), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        vm.expectPartialRevert(BandPool.SlippageExceeded.selector); // pushed into band 1: a 29 bps step, past a 5 bps bound
        router.swap(address(pool), size, true, taker, minOut);
        vm.stopPrank();
    }

    /// And re-quoting after the shift makes the very same tolerance work again.
    function test_reQuotingAfterTheShiftLetsTheSameToleranceThrough() public {
        _fundAll();
        _buy(other, 210e18, 0); // band 0 gone first

        uint256 size = 150e18;
        uint256 quoted = _quote(size); // now honestly quoted in band 1
        uint256 got = _buy(taker, size, (quoted * 9995) / 10000);
        assertGt(got, 0, "0.05% against a CURRENT quote is fine in band 1");
    }
}
