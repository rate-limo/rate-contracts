// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {BandSwapRouter} from "../../src/swap/BandSwapRouter.sol";
import {StubToken, StubEngine} from "./BandPoolBase.sol";

/// Counts writes, so a test can assert the pool never moves the price it reads.
contract WatchedBook {
    uint256 public price = 2e8;
    uint256 public writes;

    function lmp() external view returns (uint256) { return price; }
    function twap(uint32) external view returns (uint256, uint32) { return (price, 300); }
    /// Only the engine may really call this; here it just records that something did.
    function setLmp(uint256 p) external { price = p; writes++; }
    function convert(uint256 p, uint256 amount, bool isBid) external pure returns (uint256) {
        return isBid ? (amount * p) / 1e8 : (amount * 1e8) / p;
    }
}

/**
 * The pool reads a price from the orderbook. Does it write one back?
 *
 * Not itself. `BandPool.swap` returns `matchedPrice` and stops; it holds no reference
 * that could write the book. The loop is closed one level up: `BandSwapRouter` takes
 * that price and calls `MatchingEngine.reportSwap`, which clamps it to the pair's rail
 * and writes lmp -- what the TWAP is built from. BandRealStack pins that loop against
 * the real engine.
 *
 * This file isolates the half of it the pool owns. The engine here is a stub that
 * RECORDS the report and writes nothing, so what remains is the pool's own relationship
 * to price: bands follow the ORDERBOOK's TWAP, and only the book. However much the pool
 * trades, if nothing writes the book the anchor does not move -- which is exactly why
 * the report is not optional (see BandSwapRouter's header).
 */
contract BandPriceFeedbackTest is Test {
    BandPool pool;
    BandSwapRouter router;
    StubToken baseTok;
    StubToken quoteTok;
    WatchedBook book;
    StubEngine eng;

    /// The position manager is just an address here: the pool takes whatever id it is handed.
    address pm = address(0xBEEF);
    address taker = address(0xABCD);
    address creator = address(0xC0FFEE);

    function setUp() public {
        router = new BandSwapRouter();
        vm.warp(1_000_000);
        baseTok = new StubToken();
        quoteTok = new StubToken();
        book = new WatchedBook();
        eng = new StubEngine();
        eng.setSwapRouter(address(router));

        pool = new BandPool();
        // Fractions of the stub's 10% limit: 0.1 / 0.3 / 0.5%, the ladder v1 shipped.
        uint32[] memory t = new uint32[](3);
        t[0] = 1000000; t[1] = 3000000; t[2] = 5000000;
        uint32[] memory m = new uint32[](3);
        m[0] = 100000000; m[1] = 200000000; m[2] = 300000000;
        pool.initialize(BandPool.InitParams({
            id: 1, base: address(baseTok), quote: address(quoteTok),
            orderbook: address(book), engine: address(eng),
            positionManager: pm, creator: creator, maturity: 600,
            spreadFracs: t, feeMultipliers: m
        }));
        pool.syncLimit();
        eng.listPool(address(pool));

        // One position holding all three bands, as the manager would deposit it.
        baseTok.mint(pm, 3_000e18);
        vm.prank(pm);
        baseTok.approve(address(pool), type(uint256).max);
        uint8[] memory bands = new uint8[](3);
        uint256[] memory baseAmounts = new uint256[](3);
        uint256[] memory quoteAmounts = new uint256[](3);
        for (uint8 i = 0; i < 3; i++) {
            bands[i] = i;
            baseAmounts[i] = 1_000e18;
        }
        vm.prank(pm);
        pool.increase(1, bands, baseAmounts, quoteAmounts);
    }

    function _buy(uint256 quoteIn) internal returns (uint256) {
        quoteTok.mint(taker, quoteIn);
        vm.startPrank(taker);
        quoteTok.approve(address(pool), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        uint256 out = router.swap(address(pool), quoteIn, true, taker, 0);
        vm.stopPrank();
        return out;
    }

    /// A single swap writes nothing back to the book itself; it hands its price upward.
    function test_aSwapDoesNotReportItsPriceToTheOrderbook() public {
        _buy(100e18);
        assertEq(book.writes(), 0, "the pool never called setLmp");
        assertEq(book.price(), 2e8, "so the anchor did not move");
        assertEq(eng.reports(), 1, "the router reported to the engine instead -- the only way back");
    }

    /**
     * Nor does sustained one-way flow. Buying out most of the pool's base -- which on
     * any real venue is a price signal -- leaves the anchor exactly where it started,
     * so the next trade is quoted off a price the pool's own activity has contradicted.
     */
    function test_sustainedBuyingDoesNotMoveTheAnchorAtAll() public {
        for (uint256 i = 0; i < 4; i++) _buy(1_000e18);

        (uint256 r0,) = pool.bandReserves(0);
        (uint256 r1,) = pool.bandReserves(1);
        (uint256 r2,) = pool.bandReserves(2);
        console2.log("base left, band 0/1/2:", r0, r1, r2);

        // Dust, not zero: convert() floors on both legs of the round trip, so a band
        // taken to the wei keeps a remainder rather than underflowing. Fuzzed in
        // BandSwapFailures; here it just means the assertion has to allow it.
        assertLt(r0, 1e12, "band 0 bought out but for dust");
        assertLt(r1, 1_000e18, "and band 1 eaten into");
        assertEq(book.writes(), 0, "and still not one write to the book");
        assertEq(book.price(), 2e8, "the anchor is exactly where it was listed");
    }

    /**
     * The bands are still quoting off the stale anchor afterwards. Whatever the pool
     * has just been telling the world about supply, band 2 still offers base at
     * 2.020 -- the same price it offered before the pool was swept.
     */
    function test_afterTheSweepTheBandsStillQuoteTheOriginalPrice() public {
        for (uint256 i = 0; i < 4; i++) _buy(1_000e18);
        uint256 before_ = _buy(1_000e18);

        // A fresh identical trade prices identically: no drift, none at all.
        uint256 after_ = _buy(1_000e18);
        assertApproxEqRel(after_, before_, 1e15, "the pool cannot reprice itself");
    }

    /**
     * The anchor DOES move when the orderbook moves, which is the design. This is
     * what "bands follow the market" actually means: they follow the book, and only
     * the book.
     */
    function test_theAnchorTracksTheORDERBOOKAndOnlyTheOrderbook() public {
        uint256 atTwoThousand = _buy(1_000e18);
        book.setLmp(24e7); // the book traded up 20%
        uint256 atTwentyFourHundred = _buy(1_000e18);
        assertLt(atTwentyFourHundred, atTwoThousand, "less base per quote at a higher price");
        assertApproxEqRel(atTwentyFourHundred, (atTwoThousand * 1e8) / 12e7, 2e15, "moved with the book");
    }
}
