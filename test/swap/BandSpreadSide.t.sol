// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandBaseSetup} from "./BandBaseSetup.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {IMatchingEngine} from "../../src/exchange/interfaces/IMatchingEngine.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * WHY the pool follows the MARKET spread, and when the rail still refuses what it traded.
 *
 * The engine keeps two spread limits per pair. It is tempting to reason from what a
 * band resembles -- it offers liquidity and waits, so surely the limit-order bound
 * governs where it may quote -- and that reasoning is wrong. A band never places a
 * limit order. It has no interaction with `limitBuy`/`limitSell` at all.
 *
 * What it does do is fill a swap and report the matched price, and `reportSwap`
 * clamps that report with `getSpread(pair, side, TRUE)` -- the market one. So the
 * market spread is the bound the pool's own output is measured against downstream, and
 * it is the one `syncLimit` copies into the pool.
 *
 * v1 showed the failure this prevents: a band fitted to a wide spread, then left behind
 * when the spread narrowed, traded at 0.50% while the book recorded 0.10%. v2 moves the
 * bands with the spread, so that gap cannot open from a spread change. It still opens
 * from the ANCHOR: bands hang off the 300s TWAP, the rail off the block's opening lmp,
 * and when the book moves the TWAP lags it. Then a band quotes past the rail, fills
 * there, and the book records the clamp -- the pool computing its next bounds from a
 * price it never traded at, for as long as the lag lasts.
 */
contract BandSpreadSideTest is BandBaseSetup {
    uint32 constant PRODUCTION = 100000; // 0.10%, the engine's dfltMktBuy/Sell
    uint32 constant WIDE = 10000000; // 10%, what the fixture ships

    function setUp() public override {
        super.setUp();
        // Out of the listing block, whose setLmp opened it from zero: until the next
        // block the rail would anchor on the live lmp rather than a block open.
        vm.roll(block.number + 1);
    }

    function _setMarketSpread(uint32 s) internal {
        matchingEngine.setSpread(address(token1), address(token2), s, s, true);
    }

    /**
     * Move the BOOK to `price` with one ordinary match. Nothing of the taker's reaches
     * the pool: every band bound is above `price`, so the fallback's own limit-price bound
     * refuses the remainder -- asserted, because a pool print here would silently change
     * the state the case starts from.
     */
    function _bookTradesAt(uint256 price) internal {
        vm.startPrank(trader2);
        token1.approve(address(matchingEngine), type(uint256).max);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1), quote: address(token2), price: price,
                amount: 1e18, isMaker: true, n: 2, recipient: trader2
            })
        );
        vm.stopPrank();
        vm.recordLogs();
        vm.startPrank(trader1);
        token2.approve(address(matchingEngine), type(uint256).max);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1), quote: address(token2), price: price,
                amount: (price * 1e18) / 1e8, isMaker: false, n: 1, recipient: trader1
            })
        );
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 routed = keccak256("RemainderRoutedToPool(address,address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != routed, "the pool took no part");
        }
        assertEq(_lmp(), price, "the book printed the match");
    }

    /**
     * v1's case, replayed: fund at the wide spread, narrow, trade into the outer band.
     * v1 recorded a clamp one fifth of what band 2 traded at. v2 recorded what it traded:
     * narrowing moved band 2 to 5% of the new 0.10% limit, and the report passes the rail
     * untouched.
     *
     * And it is the MARKET spread that moved it. The limit-order spread is still the
     * fixture's 10%, and the pool never read it.
     */
    function test_narrowingTheSpreadKeepsTheRecordOnWhatThePoolTraded() public {
        _seedBands(100e18); // every band, while the fixture's 10% spread is in force
        _setMarketSpread(PRODUCTION);
        assertEq(matchingEngine.getSpread(address(book), true, false), WIDE, "the limit spread is untouched");
        assertEq(pool.pairLimit(true), PRODUCTION, "the pool follows the market spread");

        assertEq(_lmp(), LISTING, "nothing has moved yet");

        // Big enough to exhaust bands 0 and 1 and fill inside band 2.
        uint256 out = _buy(trader1, 60_000e18);
        assertGt(out, 0, "the trade filled");

        (uint32 t2,) = pool.bandTolerances(2);
        uint256 bandTwoBound = (LISTING * (1e8 + uint256(t2))) / 1e8;
        uint256 ceiling = (LISTING * (1e8 + PRODUCTION)) / 1e8;
        assertEq(_lmp(), bandTwoBound, "the book records the price band 2 traded at");
        assertLt(_lmp(), ceiling, "inside the rail, so the rail did not decide it");
    }

    /**
     * The same swap under a roomy spread: the report tracks the band that filled, so
     * lmp says what the pool did.
     */
    function test_withARoomySpreadTheRecordKeepsUp() public {
        _seedBands(100e18);
        _setMarketSpread(WIDE);

        _buy(trader1, 60_000e18);

        uint256 ceiling = (LISTING * (1e8 + WIDE)) / 1e8;
        assertLt(_lmp(), ceiling, "nowhere near the clamp, so the clamp is not what set it");
        assertGt(_lmp(), LISTING, "and the book moved with the trade");
    }

    /**
     * Where the gap still opens. The book trades 1% down; the next block opens there and
     * its ceiling is 0.10% above 99. The pool's TWAP has seen twelve seconds of that and
     * still sits near 100, so even band 0 -- 0.001% above the anchor -- fills above the
     * ceiling. The trade happens at the band's bound, lmp moves by the clamp, and the
     * difference is the anchor's lag, not the ladder.
     */
    function test_aLaggingAnchorTradesAtAPriceTheRailWillNotRecord() public {
        vm.warp(block.timestamp + 600); // a real TWAP, not the listing fallback
        _seedBands(1_000e18);
        _setMarketSpread(PRODUCTION);

        _bookTradesAt(99e8);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);

        uint256 ceiling = (_lmp() * (1e8 + PRODUCTION)) / 1e8;
        (uint32 t0,) = pool.bandTolerances(0);
        uint256 bandZeroBound = (pool.anchorPrice() * (1e8 + uint256(t0))) / 1e8;
        assertGt(bandZeroBound, ceiling, "the tightest band already quotes past the rail");

        uint256 out = _buy(trader1, 5_000e18); // inside band 0
        assertGt(out, 0, "the trade filled");
        assertEq(_lmp(), ceiling, "the report was clamped to the block-open ceiling");
        assertGt(bandZeroBound - ceiling, (PRODUCTION * ceiling) / 1e8, "a real gap: wider than the spread itself");
    }

    /**
     * A spread of ZERO must not pin anything.
     *
     * v1's worry was a deposit reading a spread that did not exist yet and freezing the
     * ladder at it. v2 has nothing to freeze: a zero limit makes every tolerance zero, so
     * every band idles -- it neither refuses the deposit nor quotes at the anchor -- and
     * the moment a spread exists the same bands quote their fraction of it.
     */
    function test_anAbsentSpreadDoesNotPin() public {
        _setMarketSpread(0);
        _seedBands(1e18); // accepted: a deposit is never refused for the spread

        vm.startPrank(trader1);
        token2.approve(address(router), type(uint256).max);
        vm.expectRevert(BandPool.NoLiquidity.selector);
        router.swap(address(pool), 10e18, true, trader1, 0);
        vm.stopPrank();

        _setMarketSpread(PRODUCTION);
        (uint32 f2,,,,) = pool.bands(2);
        (uint32 t2,) = pool.bandTolerances(2);
        assertEq(f2, 5000000, "the fraction was never touched");
        assertEq(t2, 5000, "and now means 5% of the spread it eventually read");
        assertGt(_buy(trader1, 10e18), 0, "the same bands trade");
    }
}
