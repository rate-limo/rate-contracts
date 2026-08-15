// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {IOrderbook} from "../../src/exchange/interfaces/IOrderbook.sol";
import {Oracle} from "../../src/exchange/libraries/Oracle.sol";
import {MockToken} from "../../src/mock/MockToken.sol";
import {Orderbook} from "../../src/exchange/orderbooks/Orderbook.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {IMatchingEngine} from "../../src/exchange/interfaces/IMatchingEngine.sol";

/// How a pair's TWAP comes into existence. Every price in the swap-reporting work is
/// measured against "TWAP 100.00", and that number is not stored anywhere -- it is
/// reconstructed from a single seed observation plus the live lmp. This pins the seeding
/// path, because two of its properties are load-bearing and neither is obvious:
///
///   1. The listing's own setLmp writes NO observation (same-timestamp dedup), so a fresh
///      pair holds exactly one observation and it carries no price at all.
///   2. That makes twap(600) revert for the pair's first 600 seconds -- and Pool.swap
///      calls twap(600) unconditionally, so a newly listed pair is unswappable until the
///      window has elapsed.
contract TwapSeedingTest is PoolBaseSetup {
    MockToken newBase;
    MockToken newQuote;
    Orderbook fresh;

    uint256 constant LISTING = 250e8;

    function setUp() public override {
        super.setUp();
        // A pair listed NOW, without PoolBaseSetup's 600s warp, so the seeding state is
        // observable before any history exists.
        newBase = new MockToken("New", "NEW", 18);
        newQuote = new MockToken("Cash", "CASH", 18);
        matchingEngine.addPair(
            address(newBase),
            address(newQuote),
            LISTING,
            0,
            address(newBase),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        fresh = Orderbook(payable(matchingEngine.getPair(address(newBase), address(newQuote))));
    }

    // ------------------------------------------------------------------ what exists at t0

    /// `Oracle.initialize` writes slot 0 as {blockTimestamp: now, priceCumulative: 0}. It is
    /// a TIME ANCHOR, not a price -- the listing price is nowhere in the buffer. lmp holds
    /// it, and twap reconstructs the average by extrapolating the live lmp forward from the
    /// anchor.
    function testTheSeedIsATimeAnchorNotAPrice() public view {
        assertEq(fresh.lmp(), LISTING, "the listing price lives in lmp, not the oracle");
    }

    /// The listing calls createBook (which seeds the oracle at block.timestamp) and then
    /// setLmp(listingPrice) in the SAME transaction. Oracle.write no-ops when an observation
    /// already exists for this timestamp, so the listing adds nothing: the buffer holds one
    /// observation whose age is zero, and any window request reverts.
    function testAFreshPairHasNoHistoryAtAll() public {
        vm.expectRevert(abi.encodeWithSelector(Oracle.InsufficientHistory.selector, uint32(600), uint32(0)));
        fresh.twap(600);

        // Not a 600-specific problem -- there is no history for ANY window.
        vm.expectRevert(abi.encodeWithSelector(Oracle.InsufficientHistory.selector, uint32(1), uint32(0)));
        fresh.twap(1);
    }

    /// The consequence Pool documents as a deliberate fail-safe: _prepareSwap calls
    /// twap(TWAP_WINDOW) before anything else, so the revert above closes the pool for the
    /// pair's first 600 seconds. Every swap fixture in this repo warps past it in setUp.
    function testTheWindowMustElapseBeforeAnyWindowIsAnswerable() public {
        vm.warp(block.timestamp + 599);
        vm.expectRevert(abi.encodeWithSelector(Oracle.InsufficientHistory.selector, uint32(600), uint32(599)));
        fresh.twap(600);

        vm.warp(block.timestamp + 1); // exactly 600s old
        (uint256 price, uint32 window) = fresh.twap(600);
        assertEq(window, 600, "the seed is now old enough to answer");
        assertEq(price, LISTING, "and the average is the listing price, exactly");
    }

    // ------------------------------------------------------------------ what it averages

    /// With one observation and no writes, twap extrapolates the live lmp across the whole
    /// window: (lmp * elapsed - 0) / elapsed = lmp. So the TWAP a pool prices against for
    /// its entire quiet life is the listing price, to the wei -- which is why every case in
    /// the reporting work reads "TWAP 100.00" on a fixture listed at 100e8.
    function testAQuietPairsTwapIsExactlyTheListingPrice() public {
        vm.warp(block.timestamp + 600);
        (uint256 atWindow,) = fresh.twap(600);

        vm.warp(block.timestamp + 86400); // a day later, still no trades
        (uint256 aDayLater, uint32 window) = fresh.twap(600);

        assertEq(atWindow, LISTING);
        assertEq(aDayLater, LISTING, "no activity means no drift, ever");
        assertEq(window, 87000, "and the window keeps stretching -- it is a floor, not a target");
    }

    /// The seed stays the oldest retained observation until the buffer wraps, so the
    /// returned window grows without bound on a quiet pair. Pool discards this value, which
    /// is why a quiet pair silently prices off an average far longer than the 600s it asked
    /// for -- conservative here, but unchecked.
    function testTheReturnedWindowIsAFloorNotAPromise() public {
        vm.warp(block.timestamp + 3000);
        (, uint32 window) = fresh.twap(600);
        assertEq(window, 3000, "asked for 600, got 3000");
    }

    // ------------------------------------------------------------------ the first real write

    /// The first setLmp after listing is what finally puts a price into the buffer -- and it
    /// carries the OUTGOING price forward, not the incoming one. So the observation written
    /// when the price moves to X records the interval that was spent at the listing price.
    /// That one-step lag is why a single trade cannot move the TWAP it just priced against.
    function testTheFirstWriteRecordsTheOutgoingPrice() public {
        vm.warp(block.timestamp + 600);
        (uint256 before,) = fresh.twap(600);
        assertEq(before, LISTING);

        // Move the price via the book, then let the full window pass.
        newBase.mint(trader2, 1000e18);
        newQuote.mint(trader2, 1000000e18);
        vm.prank(trader2);
        newQuote.approve(address(matchingEngine), 1000000e18);
        vm.prank(trader2);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(newBase),
                quote: address(newQuote),
                price: 255e8,
                amount: 100e18,
                isMaker: true,
                n: 1,
                recipient: trader2
            })
        );
        assertEq(fresh.lmp(), 255e8, "lmp moved immediately");

        (uint256 rightAfter,) = fresh.twap(600);
        assertEq(rightAfter, LISTING, "but the average has not -- zero time has elapsed at 255");

        vm.warp(block.timestamp + 600);
        (uint256 later,) = fresh.twap(600);
        assertEq(later, 255e8, "only after a full window does the average reach the new price");
    }
}
