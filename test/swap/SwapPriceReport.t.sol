// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {SwapRouter} from "../../src/swap/SwapRouter.sol";
import {ISwapRouter} from "../../src/swap/interfaces/ISwapRouter.sol";
import {IPool} from "../../src/swap/interfaces/IPool.sol";
import {IOrderbook} from "../../src/exchange/interfaces/IOrderbook.sol";

/// Swaps used to be invisible to the price: Pool.swap settles off-book and wrote no lmp
/// and no oracle observation, so the TWAP it prices against could only be moved by order
/// book activity. These cover the report that closes that loop -- the router handing the
/// engine the price the swapper and the pool actually matched at, so `lmp` keeps meaning
/// what its name says whether the fill happened on the book or in the pool.
///
/// Organised as a matrix: every case is asserted on BOTH sides. The two sides are not
/// symmetric in the amounts that reach them -- this LP deposits 1000e18 of each token at a
/// price near 100, so the quote side is ~100x thinner in base-equivalent terms and a sell
/// exhausts its tier for ~10.5e18 where a buy needs ~105000e18. Where a case behaves
/// differently on one side, that difference is the point of the test, not an oversight.
contract SwapPriceReportTest is PoolBaseSetup {
    SwapRouter router;
    ISwapRouter.RemainderConfig empty;

    // PoolBaseSetup lists at 100e8 and sets BOTH spreads to 10%.
    uint256 constant LISTED = 100e8;
    uint256 constant SPREAD = 10000000; // 10%, DENOM-scaled
    uint256 constant DENOM = 100000000;

    // The LP's slippage limit, and so the price its liquidity trades at.
    uint32 constant TIER = 5000000; // 5%
    uint32 constant WIDE = 8000000; // 8%, used by the two-tier cases
    uint256 constant BUY_FILL = (LISTED * (DENOM + TIER)) / DENOM; // 105e8
    uint256 constant SELL_FILL = (LISTED * (DENOM - TIER)) / DENOM; // 95e8
    uint256 constant BUY_WIDE = (LISTED * (DENOM + WIDE)) / DENOM; // 108e8
    uint256 constant SELL_WIDE = (LISTED * (DENOM - WIDE)) / DENOM; // 92e8

    /// Mirrors of the engine's events, so the matrix can assert the emitted payload and
    /// not just the resulting storage. Both are declared non-indexed/indexed exactly as
    /// MatchingEngine declares them -- a mismatch here would silently never match.
    event NewMarketPrice(address pair, uint256 price, bool isBid);
    event SwapPriceReport(address indexed pair, uint256 lmpBefore, uint256 reported, uint256 lmpAfter, bool isBuy);

    /// Queues both expectations, in the order reportSwap emits them. `reported` and
    /// `written` differ exactly when the spread rail clamped the write -- carrying both is
    /// the whole reason SwapPriceReport exists alongside NewMarketPrice, so every case
    /// asserts them independently rather than assuming they are equal.
    function _expectReport(uint256 lmpBefore, uint256 reported, uint256 written, bool isBuy) private {
        address pair = pool.orderbook();
        vm.expectEmit(true, true, true, true, address(matchingEngine));
        emit NewMarketPrice(pair, written, isBuy);
        vm.expectEmit(true, true, true, true, address(matchingEngine));
        emit SwapPriceReport(pair, lmpBefore, reported, written, isBuy);
    }

    /// Approve FIRST, then arm the expectation, then swap. vm.expectEmit matches against
    /// the logs of the next call onward, and `token.approve` emits `Approval` -- arming
    /// before the approval makes every expectation fail on that log instead of reaching
    /// the report. Splitting the prank is the whole reason these variants exist.
    function _buyExpecting(uint256 amountIn, uint256 lmpBefore, uint256 reported, uint256 written)
        private
        returns (uint256 out)
    {
        vm.prank(trader1);
        token2.approve(address(router), amountIn);
        _expectReport(lmpBefore, reported, written, true);
        vm.prank(trader1);
        out = router.swap(
            _path(address(token2), address(token1)), amountIn, 0, trader1, ISwapRouter.RemainderMode.Refund, empty
        );
    }

    function _sellExpecting(uint256 amountIn, uint256 lmpBefore, uint256 reported, uint256 written)
        private
        returns (uint256 out)
    {
        vm.prank(trader1);
        token1.approve(address(router), amountIn);
        _expectReport(lmpBefore, reported, written, false);
        vm.prank(trader1);
        out = router.swap(
            _path(address(token1), address(token2)), amountIn, 0, trader1, ISwapRouter.RemainderMode.Refund, empty
        );
    }

    /// topic0 of SwapPriceReport, for the cases that must emit nothing at all.
    function _reportTopic() private pure returns (bytes32) {
        return keccak256("SwapPriceReport(address,uint256,uint256,uint256,bool)");
    }

    function _assertNoReportLogged() private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == _reportTopic()) {
                revert("a report was emitted when none should have been");
            }
        }
    }

    function setUp() public override {
        super.setUp();
        router = new SwapRouter(address(poolFactory));
        // Replaces PoolBaseSetup's trader1 stand-in with the real router.
        matchingEngine.setSwapRouter(address(router));
        _addPosition(TIER);
    }

    function _addPosition(uint32 slippage) private {
        vm.prank(lp1);
        token1.approve(address(pool), 10000e18);
        vm.prank(lp1);
        token2.approve(address(pool), 10000e18);
        vm.prank(positionManager);
        pool.addLiquidity(50e8, 150e8, slippage, 1000e18, 1000e18, lp1);
    }

    function _lmp() private view returns (uint256) {
        return IOrderbook(pool.orderbook()).lmp();
    }

    function _path(address a, address b) private pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function _buy(uint256 amountIn) private returns (uint256 out) {
        vm.startPrank(trader1);
        token2.approve(address(router), amountIn);
        out = router.swap(
            _path(address(token2), address(token1)), amountIn, 0, trader1, ISwapRouter.RemainderMode.Refund, empty
        );
        vm.stopPrank();
    }

    function _sell(uint256 amountIn) private returns (uint256 out) {
        vm.startPrank(trader1);
        token1.approve(address(router), amountIn);
        out = router.swap(
            _path(address(token1), address(token2)), amountIn, 0, trader1, ISwapRouter.RemainderMode.Refund, empty
        );
        vm.stopPrank();
    }

    // ================================================================== 1. direction

    function testBuyRaisesMarketPrice() public {
        assertEq(_lmp(), LISTED, "precondition: lmp is the listing price");
        _buyExpecting(100e18, LISTED, BUY_FILL, BUY_FILL);
        assertGt(_lmp(), LISTED, "a buy must move the price up");
    }

    function testSellLowersMarketPrice() public {
        assertEq(_lmp(), LISTED, "precondition: lmp is the listing price");
        _sellExpecting(5e18, LISTED, SELL_FILL, SELL_FILL);
        assertLt(_lmp(), LISTED, "a sell must move the price down");
    }

    // ================================================================== 2. it is the fill

    /// The whole point: lmp becomes the price the swap traded at, not a number derived
    /// from it. The LP quotes at TWAP * (1 +/- 5%), the swapper trades there, and that is
    /// what the pair records.
    function testLmpBecomesTheExactPriceTheBuyFilledAt() public {
        _buyExpecting(100e18, LISTED, BUY_FILL, BUY_FILL);
        assertEq(_lmp(), BUY_FILL, "lmp is the tier bound the buy actually filled at");
    }

    function testLmpBecomesTheExactPriceTheSellFilledAt() public {
        _sellExpecting(1e18, LISTED, SELL_FILL, SELL_FILL);
        assertEq(_lmp(), SELL_FILL, "lmp is the tier bound the sell actually filled at");
    }

    /// With one tier on each side and both derived from the same TWAP, the sides are
    /// symmetric in PRICE -- 5% up for a buy, 5% down for a sell -- because that is where
    /// the LP quoted, not because of how much depth sat behind each quote.
    function testSidesAreSymmetricAroundTheTwap() public {
        _buy(5e18);
        uint256 up = _lmp() - LISTED;

        setUp();

        _sell(5e18);
        uint256 down = LISTED - _lmp();

        assertEq(up, BUY_FILL - LISTED);
        assertEq(down, LISTED - SELL_FILL);
        assertEq(up, down, "equal and opposite, despite wildly unequal depth");
    }

    // ================================================================== 3. corroboration

    /// Checks the report against the tokens that moved rather than against the constant.
    /// The buyer pays quote and receives base net of the taker fee, so the price implied
    /// by the transfer sits a hair ABOVE the reported fill price.
    function testReportedPriceMatchesWhatTheBuyerActuallyPaid() public {
        uint256 amountIn = 210e18;
        uint256 out = _buy(amountIn);

        uint256 implied = (amountIn * 1e8) / out; // quote per base, 1e8-scaled like lmp
        uint256 reported = _lmp();

        assertGe(implied, reported, "fee makes the paid price the higher of the two");
        assertLt(implied - reported, reported / 500, "and only by the fee, not by a repricing");
    }

    /// The mirror, and the inequality flips: the seller delivers base and receives quote
    /// net of the fee, so the price implied by the transfer sits a hair BELOW the report.
    function testReportedPriceMatchesWhatTheSellerActuallyReceived() public {
        uint256 amountIn = 2e18;
        uint256 out = _sell(amountIn);

        uint256 implied = (out * 1e8) / amountIn; // quote per base
        uint256 reported = _lmp();

        assertLe(implied, reported, "fee makes the received price the lower of the two");
        assertLt(reported - implied, reported / 500, "and only by the fee");
    }

    // ================================================================== 4. size is irrelevant

    /// Size does not enter into it. A price is a price: two units filled at 105 and two
    /// thousand units filled at 105 both mean the last trade happened at 105. This is the
    /// assertion that would fail under any flow-weighted scheme.
    function testTinyAndHugeBuysAtTheSameTierReportTheSamePrice() public {
        _buyExpecting(1e18, LISTED, BUY_FILL, BUY_FILL);
        uint256 small = _lmp();

        setUp(); // fresh pair state

        // Identical payload from a swap 5000x the size -- the event carries no size term.
        _buyExpecting(5000e18, LISTED, BUY_FILL, BUY_FILL);
        uint256 large = _lmp();

        assertEq(small, BUY_FILL);
        assertEq(large, small, "the price a trade happened at does not depend on its size");
    }

    /// Same on the sell side, and the sizes have to be chosen differently: the sell tier
    /// is exhausted by ~10.5e18 of base, so 5000e18 would spill out of the tier entirely
    /// rather than testing what this test is about.
    function testTinyAndHugeSellsAtTheSameTierReportTheSamePrice() public {
        _sellExpecting(0.001e18, LISTED, SELL_FILL, SELL_FILL);
        uint256 small = _lmp();

        setUp();

        _sellExpecting(10e18, LISTED, SELL_FILL, SELL_FILL);
        uint256 large = _lmp();

        assertEq(small, SELL_FILL);
        assertEq(large, small, "size-independence holds on the thin side too");
    }

    // ================================================================== 5. spanning tiers

    /// Tiers fill tightest-first, so a swap that eats through the 5% tier and into a wider
    /// one reports the WIDER price -- the one the final unit changed hands at. This
    /// mirrors MatchingLib leaving lmp at the last level it walked, and it is why the
    /// field is the last bound rather than the first.
    function testBuySpanningTwoTiersReportsTheWorseOne() public {
        _addPosition(WIDE);

        _buyExpecting(500000e18, LISTED, BUY_WIDE, BUY_WIDE); // more than the 5% tier can fill

        assertEq(_lmp(), BUY_WIDE, "the last tier touched sets the price");
    }

    /// The sell side reaches its second tier for three orders of magnitude less input,
    /// because the quote side of this position is ~100x thinner in base-equivalent terms.
    /// Same rule, same outcome: the worse of the two bounds is what gets recorded.
    function testSellSpanningTwoTiersReportsTheWorseOne() public {
        _addPosition(WIDE);

        _sellExpecting(15e18, LISTED, SELL_WIDE, SELL_WIDE); // tier 0 is exhausted by ~10.5e18

        assertEq(_lmp(), SELL_WIDE, "the last tier touched sets the price, downward");
    }

    // ================================================================== 6. tier untouched

    /// A swap small enough to stay inside the tight tier never sees the wide one.
    function testBuyInsideTheTightTierIgnoresTheWiderOne() public {
        _addPosition(WIDE);

        _buyExpecting(10e18, LISTED, BUY_FILL, BUY_FILL);

        assertEq(_lmp(), BUY_FILL, "untouched liquidity must not move the price");
    }

    function testSellInsideTheTightTierIgnoresTheWiderOne() public {
        _addPosition(WIDE);

        _sellExpecting(1e18, LISTED, SELL_FILL, SELL_FILL);

        assertEq(_lmp(), SELL_FILL, "untouched liquidity must not move the price, either way");
    }

    // ================================================================== 7. the rail

    /// The market spread is a bound on the report, not its source. Tighten it below the
    /// LP's quote and the write is clamped: the swap still fills at its tier bound, but
    /// the pair refuses to record a move larger than its own circuit breaker allows.
    function testBuyReportIsClampedToTheMarketSpread() public {
        uint32 tight = 1000000; // 1% market spread
        matchingEngine.setSpread(address(token1), address(token2), tight, tight, true);

        // reported 105.00, written 101.00 -- an indexer can see the clamp
        _buyExpecting(100e18, LISTED, BUY_FILL, (LISTED * (DENOM + 1000000)) / DENOM);

        assertEq(_lmp(), (LISTED * (DENOM + tight)) / DENOM, "clamped to the pair's own bound");
        assertLt(_lmp(), BUY_FILL, "which is strictly below where the trade happened");
    }

    function testSellReportIsClampedToTheMarketSpread() public {
        uint32 tight = 1000000; // 1%
        matchingEngine.setSpread(address(token1), address(token2), tight, tight, true);

        // reported 95.00, written 99.00
        _sellExpecting(1e18, LISTED, SELL_FILL, (LISTED * (DENOM - 1000000)) / DENOM);

        assertEq(_lmp(), (LISTED * (DENOM - tight)) / DENOM, "clamped on the way down too");
        assertGt(_lmp(), SELL_FILL, "strictly above where the trade happened");
    }

    /// And below the cap the reported price passes through untouched, on both sides.
    function testUnclampedWhenTheBuyIsInsideTheSpread() public {
        uint256 ceiling = (LISTED * (DENOM + SPREAD)) / DENOM;

        _buyExpecting(1000000e18, LISTED, BUY_FILL, BUY_FILL);

        assertLe(_lmp(), ceiling, "a single swap can never move past the cap");
        assertEq(_lmp(), BUY_FILL, "and below the cap it passes through untouched");
    }

    function testUnclampedWhenTheSellIsInsideTheSpread() public {
        uint256 floor = (LISTED * (DENOM - SPREAD)) / DENOM;

        _sellExpecting(10000e18, LISTED, SELL_FILL, SELL_FILL);

        assertGe(_lmp(), floor, "a single swap can never move past the cap");
        assertEq(_lmp(), SELL_FILL, "and inside it the fill price is recorded verbatim");
    }

    // ================================================================== 8. divergence

    /// "A buy raises the price" is only true while lmp still agrees with the TWAP. The
    /// reported price is ABSOLUTE -- derived from twap(600) -- while the rail is relative
    /// to lmp, and each direction only gets one side of it (a buy gets a ceiling, a sell
    /// a floor). So when the book has ratcheted lmp above TWAP * (1 + s) -- which resting
    /// limit orders can do without a single token changing hands -- a buy fills BELOW lmp
    /// and writes it down.
    ///
    /// That is the pool doing its job, not a bug: the swapper really did trade there, and
    /// recording it pulls a book-inflated lmp back toward the oracle.
    function testBuyLowersLmpWhenTheBookHasRatchetedItAboveTheTwap() public {
        vm.prank(trader2);
        matchingEngine.limitBuy(address(token1), address(token2), 110e8, 100e18, true, 1, trader2);
        assertEq(_lmp(), 110e8, "precondition: the book moved lmp with no trade behind it");

        (uint256 twap,) = IOrderbook(pool.orderbook()).twap(600);
        assertLt(twap, _lmp(), "precondition: the oracle has not followed it");

        _buyExpecting(100e18, 110e8, BUY_FILL, BUY_FILL);

        assertEq(_lmp(), BUY_FILL, "the swap writes where it actually filled");
        assertLt(_lmp(), 110e8, "which is DOWN, even though this was a buy");
    }

    /// The exact mirror. A resting ask drags lmp below TWAP * (1 - s), and the next sell
    /// writes the price UP. Both halves have to be pinned: the asymmetry lives in the
    /// rail, and a change that fixed one direction while leaving the other would pass a
    /// single-sided test.
    function testSellRaisesLmpWhenTheBookHasRatchetedItBelowTheTwap() public {
        vm.prank(trader2);
        matchingEngine.limitSell(address(token1), address(token2), 91e8, 10e18, true, 1, trader2);
        assertEq(_lmp(), 91e8, "precondition: the book moved lmp with no trade behind it");

        (uint256 twap,) = IOrderbook(pool.orderbook()).twap(600);
        assertGt(twap, _lmp(), "precondition: the oracle has not followed it");

        _sellExpecting(1e18, 91e8, SELL_FILL, SELL_FILL);

        assertEq(_lmp(), SELL_FILL, "the swap writes where it actually filled");
        assertGt(_lmp(), 91e8, "which is UP, even though this was a sell");
    }

    // ================================================================== 9. nothing filled

    /// Below the rounding floor there is no price to report, so the pair is untouched.
    /// `convert` computes base out as `amount * 1e8 / price`, so at a price of 105 any
    /// input under ~105 wei floors to zero output.
    function testDustBuyBelowTheRoundingFloorReportsNothing() public {
        vm.recordLogs();
        uint256 out = _buy(1);

        assertEq(out, 0, "nothing filled");
        assertEq(_lmp(), LISTED, "so nothing was reported and the price is untouched");
        _assertNoReportLogged(); // and no event was emitted either
    }

    /// The sell side has NO rounding floor at this price, and the asymmetry is arithmetic
    /// rather than incidental: quote out is `amount * price / 1e8`, which multiplies where
    /// the buy divides. At any price above 1.00 a single wei of base still produces a
    /// non-zero fill, where the same wei of quote buys nothing.
    ///
    /// So the two sides still differ in whether they FILL -- but no longer in whether they
    /// PRINT. Before MIN_REPORT_FRACTION this one wei moved the recorded price the full 5%
    /// while its buy-side twin did nothing; now neither clears the reporting threshold, and
    /// the sell is simply a fill that does not get to set the market.
    ///
    /// The floor would move to the sell side for a pair listed below 1.00.
    function testDustSellFillsButNoLongerMovesThePrice() public {
        vm.recordLogs();
        uint256 out = _sell(1);

        assertGt(out, 0, "1 wei of base is still a fill on this side");
        assertEq(_lmp(), LISTED, "but below the reporting threshold -- was 95e8 before M2");
        _assertNoReportLogged();
    }

    // ================================================================== access

    function testDirectPoolSwapIsRejected() public {
        vm.prank(trader1);
        vm.expectRevert(abi.encodeWithSelector(IPool.NotRouter.selector, trader1, address(router)));
        pool.swap(100e18, true, trader1, false);
    }

    function testOnlyRouterCanReport() public {
        vm.prank(trader1);
        vm.expectRevert();
        matchingEngine.reportSwap(address(token1), address(token2), true, 105e8);
    }

    // ================================================================== oracle

    /// The report exists so pool volume reaches the TWAP at all. Writing lmp records an
    /// observation, so a swap followed by elapsed time must drag the average -- which no
    /// amount of pool volume could do before.
    function testBuyVolumeReachesTheTwap() public {
        (uint256 twapBefore,) = IOrderbook(pool.orderbook()).twap(600);
        assertEq(twapBefore, LISTED, "precondition: nothing has moved the average yet");

        _buy(500e18);
        vm.warp(block.timestamp + 600);

        (uint256 twapAfter,) = IOrderbook(pool.orderbook()).twap(600);
        assertGt(twapAfter, twapBefore, "pool volume must now reach the TWAP");
    }

    function testSellVolumeReachesTheTwap() public {
        (uint256 twapBefore,) = IOrderbook(pool.orderbook()).twap(600);
        assertEq(twapBefore, LISTED);

        _sell(5e18);
        vm.warp(block.timestamp + 600);

        (uint256 twapAfter,) = IOrderbook(pool.orderbook()).twap(600);
        assertLt(twapAfter, twapBefore, "and must drag it downward on a sell");
    }

    /// Sustained one-way flow keeps moving the price, but through the oracle rather than
    /// directly: each fill drags the TWAP, and the next swap prices off the moved average.
    /// The feedback is deliberately slow -- one swap cannot bootstrap itself, because the
    /// TWAP it prices against is averaged over 10 minutes.
    function testRepeatedBuysCompoundThroughTheTwap() public {
        _buy(50e18);
        uint256 afterFirst = _lmp();
        vm.warp(block.timestamp + 60);
        _buy(50e18);
        uint256 afterSecond = _lmp();

        assertEq(afterFirst, BUY_FILL);
        assertGt(afterSecond, afterFirst, "sustained flow keeps moving the price");
    }

    function testRepeatedSellsCompoundThroughTheTwap() public {
        _sell(1e18);
        uint256 afterFirst = _lmp();
        vm.warp(block.timestamp + 60);
        _sell(1e18);
        uint256 afterSecond = _lmp();

        assertEq(afterFirst, SELL_FILL);
        assertLt(afterSecond, afterFirst, "and keeps moving it down on the sell side");
    }
}
