// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {BandSwapRouter} from "../../src/swap/BandSwapRouter.sol";
import {Oracle} from "../../src/exchange/libraries/Oracle.sol";
import {WalkTok, CountEngine} from "./GasBandCount.t.sol";

/**
 * Behaves like a real Orderbook at t0: initialised, holding the listing price in
 * `lmp`, and reverting InsufficientHistory for every window until time passes.
 * TwapSeeding.t.sol pins that this is exactly what a freshly listed pair does.
 */
contract YoungBook {
    uint256 public lmp;
    uint256 public bornAt;
    uint256 public liveTwap;
    bool public broken;

    constructor(uint256 listing) {
        lmp = listing;
        bornAt = block.timestamp;
        liveTwap = listing;
    }

    function setBroken(bool b) external { broken = b; }
    function setTwap(uint256 p) external { liveTwap = p; }
    function setLmp(uint256 p) external { lmp = p; }

    function twap(uint32 window) external view returns (uint256, uint32) {
        if (broken) revert("orderbook is broken");
        uint32 age = uint32(block.timestamp - bornAt);
        if (age < window) revert Oracle.InsufficientHistory(window, age);
        return (liveTwap, age);
    }

    function convert(uint256 p, uint256 amount, bool isBid) external pure returns (uint256) {
        return isBid ? (amount * p) / 1e8 : (amount * 1e8) / p;
    }
}

/**
 * A market must be tradable the moment it is listed.
 *
 * A pair is created and priced in one transaction, and the oracle's only observation
 * is that transaction's timestamp -- so `twap` has nothing to average and reverts for
 * ANY window, not merely for 300 seconds. The pool this replaces failed closed on
 * exactly this, for its first 600 seconds.
 */
contract BandFreshPairTest is Test {
    BandPool pool;
    BandSwapRouter router;
    WalkTok baseTok;
    WalkTok quoteTok;
    YoungBook book;
    CountEngine eng;

    uint256 constant LISTING = 2e8;
    /// The position manager, as far as the pool knows: any id it is handed is valid.
    address pm = address(0xBEEF);
    address taker = address(0xABCD);
    address creator = address(0xC0FFEE);

    function setUp() public {
        router = new BandSwapRouter();
        vm.warp(1_000_000);
        baseTok = new WalkTok();
        quoteTok = new WalkTok();
        eng = new CountEngine();
        eng.setSwapRouter(address(router));
        book = new YoungBook(LISTING);

        pool = new BandPool();
        // 0.10 / 0.30 / 0.50% as fractions of the engine's 10% limit.
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
        // The limit comes from the engine alone; the young book has no part in it.
        pool.syncLimit();
        eng.listPool(address(pool));

        uint8[] memory bands = new uint8[](3);
        uint256[] memory baseAmts = new uint256[](3);
        for (uint8 i = 0; i < 3; i++) {
            bands[i] = i;
            baseAmts[i] = 100e18;
        }
        baseTok.mint(pm, 300e18);
        vm.startPrank(pm);
        baseTok.approve(address(pool), type(uint256).max);
        pool.increase(1, bands, baseAmts, new uint256[](3));
        vm.stopPrank();
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

    /// The pool captures the listing price at creation, from the same transaction.
    function test_thePoolRecordsTheListingPriceWhenItIsCreated() public view {
        assertEq(pool.seedPrice(), LISTING);
    }

    /// The orderbook genuinely cannot answer -- not a contrived failure.
    function test_theOrderbookHasNoTwapAtAll() public {
        vm.expectRevert(abi.encodeWithSelector(Oracle.InsufficientHistory.selector, uint32(1), uint32(0)));
        book.twap(1);
    }

    /// The point of the change: a market listed one second ago trades.
    function test_aPairListedThisSecondIsSwappable() public {
        uint256 out = _buy(20e18);
        assertGt(out, 0, "the pool is open the moment it is funded");
        // Priced off the listing price plus band 0's tolerance, as the TWAP would.
        assertApproxEqRel(out, (uint256(20e18) * 1e8) / 200200000, 2e15, "band 0's bound");
    }

    /// And it keeps working right across the boundary, with no jump.
    function test_theHandoverToTheRealTwapIsSeamless() public {
        uint256 before_ = _buy(1e18);
        vm.warp(block.timestamp + 301); // the window has now elapsed
        uint256 after_ = _buy(1e18);
        assertApproxEqRel(after_, before_, 1e15, "a quiet pair's TWAP IS the listing price");
    }

    /// Once the TWAP answers, it is what prices the pool -- the seed is not sticky.
    function test_theSeedIsNotUsedOnceTheTwapCanAnswer() public {
        vm.warp(block.timestamp + 301);
        book.setTwap(4e8); // the market has genuinely moved
        uint256 out = _buy(20e18);
        assertApproxEqRel(out, (uint256(20e18) * 1e8) / 400400000, 2e15, "priced off 4.00, not the 2.00 seed");
    }

    /**
     * The fallback is narrow on purpose. An orderbook failing for any reason OTHER
     * than a missing window must take the swap with it -- pricing off a stale constant
     * because the price feed is broken is how a pool gets drained quietly.
     */
    function test_anyOtherOrderbookFailureStillTakesTheSwapDown() public {
        book.setBroken(true);
        quoteTok.mint(taker, 10e18);
        vm.startPrank(taker);
        quoteTok.approve(address(pool), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        vm.expectRevert(bytes("orderbook is broken"));
        router.swap(address(pool), 10e18, true, taker, 0);
        vm.stopPrank();
    }

    /// A pool listed at price zero has no anchor and says so rather than dividing by it.
    function test_aPoolWithNoListingPriceRefusesRatherThanGuessing() public {
        YoungBook zero = new YoungBook(0);
        BandPool p2 = new BandPool();
        uint32[] memory t = new uint32[](1);
        t[0] = 1000000;
        uint32[] memory m = new uint32[](1);
        m[0] = 100000000;
        p2.initialize(BandPool.InitParams({
            id: 2, base: address(baseTok), quote: address(quoteTok),
            orderbook: address(zero), engine: address(eng),
            positionManager: address(this), creator: creator, maturity: 600,
            spreadFracs: t, feeMultipliers: m
        }));
        p2.syncLimit();
        eng.listPool(address(p2));
        baseTok.mint(address(this), 10e18);
        baseTok.approve(address(p2), type(uint256).max);
        uint8[] memory b = new uint8[](1);
        uint256[] memory ba = new uint256[](1);
        ba[0] = 10e18;
        p2.increase(1, b, ba, new uint256[](1));

        quoteTok.mint(taker, 1e18);
        vm.startPrank(taker);
        quoteTok.approve(address(p2), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        vm.expectRevert(BandPool.NoAnchorPrice.selector);
        router.swap(address(p2), 1e18, true, taker, 0);
        vm.stopPrank();
    }
}
