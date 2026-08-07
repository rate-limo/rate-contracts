// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {SwapRouter} from "../../src/swap/SwapRouter.sol";
import {ISwapRouter} from "../../src/swap/interfaces/ISwapRouter.sol";
import {IPool} from "../../src/swap/interfaces/IPool.sol";
import {IOrderbook} from "../../src/exchange/interfaces/IOrderbook.sol";
import {ORACLE_CARDINALITY} from "../../src/exchange/libraries/Oracle.sol";

/// Guards the edge cases that matched-price reporting opened and that the five mitigations
/// close. Each test states the pre-mitigation value it replaced, so a regression reads as a
/// return to a known-bad number rather than as an unexplained diff.
///
/// The mitigations, and the finding each closes:
///   M1  two-sided spread rail                    (MatchingEngine.reportSwap)
///   M2  report gated on fill size, never price   (Pool._fillTiersDirect)
///   M3  rail anchored to the block's open price  (Orderbook.lmpAtBlockOpen)
///   M4  ORACLE_CARDINALITY 512 -> 1024           (Oracle)
///   M5  input that buys nothing is not consumed  (Pool._fillTiersDirect)
contract SwapPriceReportEdgesTest is PoolBaseSetup {
    SwapRouter router;
    ISwapRouter.RemainderConfig empty;

    uint256 constant LISTED = 100e8;
    uint256 constant DENOM = 100000000;
    uint32 constant TIER = 5000000; // 5%
    uint256 constant BUY_FILL = (LISTED * (DENOM + TIER)) / DENOM; // 105e8
    uint32 constant PROD_SPREAD = 100000; // 0.1%, the dfltMkt* default

    function setUp() public override {
        super.setUp();
        router = new SwapRouter(address(poolFactory));
        matchingEngine.setSwapRouter(address(router));
        _seedLiquidity();
    }

    function _seedLiquidity() private {
        vm.prank(lp1);
        token1.approve(address(pool), 10000e18);
        vm.prank(lp1);
        token2.approve(address(pool), 10000e18);
        vm.prank(positionManager);
        pool.addLiquidity(50e8, 150e8, TIER, 1000e18, 1000e18, lp1);
    }

    function _lmp() private view returns (uint256) {
        return IOrderbook(pool.orderbook()).lmp();
    }

    function _twap() private view returns (uint256 t) {
        (t,) = IOrderbook(pool.orderbook()).twap(600);
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

    // ================================================ M2: price impact costs capital again

    /// Was: 210 wei bought 2 wei of base and moved the recorded price the full 5%, so the
    /// cost of a 5% print was gas alone. Now the fill is below MIN_REPORT_FRACTION of the
    /// tier and earns no report.
    function testDustSwapCannotMoveThePrice() public {
        assertEq(_lmp(), LISTED);
        _buy(210);
        assertEq(_lmp(), LISTED, "was 105e8 before M2");
    }

    /// The property that makes M2 legitimate rather than a fudge: it gates the REPORT, not
    /// the PRICE. The dust swap still executes, still fills at the tier bound, and the
    /// swapper still receives exactly what the bound entitles them to -- 210 wei of quote
    /// buys 2 wei of base, i.e. a price of 105. It simply does not get to set the market.
    ///
    /// This is what keeps lmp meaning "a price someone really paid": every price still
    /// written is a real fill, and the gate only ever removes prints, never invents them.
    function testDustStillFillsAtTheBoundEvenThoughItCannotReport() public {
        uint256 out = _buy(210);

        assertEq(out, 2, "the swap executed and filled at the tier bound");
        assertEq((210 * 1e8) / out, BUY_FILL, "at a price of 105.00, exactly as before");
        assertEq(_lmp(), LISTED, "but the public reference is untouched");
    }

    /// Was: a dust swap and one 10^19 times larger wrote byte-identical prices.
    function testDustAndWhaleNoLongerWriteTheSamePrice() public {
        _buy(210);
        uint256 dust = _lmp();

        setUp();
        _buy(2100e18);
        uint256 whale = _lmp();

        assertEq(dust, LISTED, "dust prints nothing");
        assertEq(whale, BUY_FILL, "a real trade still prints");
        assertTrue(dust != whale, "was identical before M2");
    }

    /// The regression guard in the other direction, and the reason MIN_REPORT_FRACTION is
    /// 0.0001% rather than the 0.01% first tried: a threshold that silences real trades is
    /// a worse bug than the one it fixes. At 0.01% a 10e18 buy against 1000e18 of depth
    /// stopped reporting, along with four other legitimate cases.
    function testRealTradesStillReport() public {
        _buy(0.2e18);
        assertEq(_lmp(), BUY_FILL, "a 0.2e18 buy is economically real and must still print");
    }

    /// Pins where the boundary actually falls, so moving the constant has to move a test.
    function testTheReportingBoundary() public {
        _buy(0.05e18);
        assertEq(_lmp(), LISTED, "below the threshold: fills, does not print");

        setUp();
        _buy(0.11e18);
        assertEq(_lmp(), BUY_FILL, "above it: prints");
    }

    // ================================================ M2/M3: the oracle walk is closed

    /// Was: 12,600 wei of flow across one full TWAP window walked lmp to 106.18 and the
    /// oracle to 103.11 at the production spread, for the cost of gas. Now none of those
    /// sixty swaps clears the reporting threshold, so the pair does not move at all.
    function testDustSwapsCannotWalkTheOracle() public {
        matchingEngine.setSpread(address(token1), address(token2), PROD_SPREAD, PROD_SPREAD, true);

        uint256 before = token2.balanceOf(trader1);
        for (uint256 i = 0; i < 60; i++) {
            _buy(210);
            vm.warp(block.timestamp + 10);
        }

        assertEq(before - token2.balanceOf(trader1), 12600, "same 12,600 wei of flow as before");
        assertEq(_lmp(), LISTED, "was 106.18 before M2");
        assertEq(_twap(), LISTED, "was 103.11 before M2");
    }

    // ================================================ M1: the rail is two-sided

    /// Was: a zero spread -- the strongest circuit breaker the system can express -- did
    /// not stop a buy writing the price 4.5% DOWN, because a buy was only ever given a
    /// ceiling. Now both bounds collapse onto lmp, the clamped write equals the current
    /// price, and `newLmp == lmp` short-circuits before anything is written.
    function testZeroSpreadNowFreezesThePrice() public {
        vm.prank(trader2);
        matchingEngine.limitBuy(address(token1), address(token2), 110e8, 100e18, true, 1, trader2);
        assertEq(_lmp(), 110e8);

        matchingEngine.setSpread(address(token1), address(token2), 0, 0, true);

        _buy(1e18);

        assertEq(_lmp(), 110e8, "was 105e8 before M1 -- a 4.5% move through a zero spread");
    }

    /// The mirror, at the production spread where the rail actually engages. A resting ask
    /// drags lmp to 91.00; the pool still quotes off the 100.00 oracle so the sell fills at
    /// 95.00 -- a 4.4% move UP on a sell. The rail now bounds that to 0.1%.
    ///
    /// Mean reversion still happens, it just walks instead of snapping: the cap re-arms
    /// every block, so a genuinely mispriced pair converges over several blocks rather than
    /// in one swap. That slowdown is the price of the bound, and it is deliberate.
    function testSellRailBitesAtTheProductionSpread() public {
        vm.prank(trader2);
        matchingEngine.limitSell(address(token1), address(token2), 91e8, 10e18, true, 1, trader2);
        assertEq(_lmp(), 91e8);

        matchingEngine.setSpread(address(token1), address(token2), PROD_SPREAD, PROD_SPREAD, true);

        _sell(1e18);

        assertEq(_lmp(), 9109100000, "91.00 + 0.1%, was 95.00 before M1");
    }

    // ================================================ M3: the rail bounds a block

    /// Was: the rail applied per report, so thirteen swaps in one transaction each got a
    /// fresh 1% cap measured against their predecessor's write and compounded to the tier
    /// bound. Anchoring to the block's opening price bounds the batch as a batch.
    ///
    /// vm.roll is load-bearing: Foundry holds block.number fixed, so the listing write
    /// claims block 1 and no swap ever records an opening price. Without rolling, M3 reads
    /// as inert and this test would pass whether or not the mitigation works.
    function testBatchInOneBlockIsBoundedAsABatch() public {
        matchingEngine.setSpread(address(token1), address(token2), 1000000, 1000000, true); // 1%
        vm.roll(block.number + 1);

        for (uint256 i = 0; i < 13; i++) {
            _buy(1e18);
        }

        assertEq(_lmp(), 10100000000, "one 1% cap for the whole block, was 105e8 before M3");
    }

    /// And the cap re-arms, so sustained honest flow is slowed rather than frozen out.
    function testCapReArmsEachBlock() public {
        matchingEngine.setSpread(address(token1), address(token2), 1000000, 1000000, true);
        vm.roll(block.number + 1);

        _buy(1e18);
        uint256 afterFirstBlock = _lmp();

        vm.roll(block.number + 1);
        _buy(1e18);

        assertEq(afterFirstBlock, 10100000000, "block one is capped at +1%");
        assertGt(_lmp(), afterFirstBlock, "block two gets its own cap");
    }

    // ================================================ M4: the buffer outlasts the window

    /// Was: 512 slots at the maximum write rate of one per second span 511 seconds, under
    /// Pool's 600-second window -- so a pair written every second silently averaged over
    /// less history than the pool believed, and the party doing the writing is the one who
    /// benefits from less smoothing.
    ///
    /// Asserted as the invariant rather than by flooding a pair, because the invariant is
    /// the actual guarantee: whatever the write rate, a full buffer must still be able to
    /// answer the window Pool asks for.
    function testOracleBufferOutlastsTheTwapWindow() public view {
        uint256 maxSpanSeconds = uint256(ORACLE_CARDINALITY) - 1; // one write per second
        assertGe(
            maxSpanSeconds,
            uint256(pool.TWAP_WINDOW()),
            "a saturated buffer must still cover the window Pool requests"
        );
    }

    // ================================================ M5: dust is refunded, not confiscated

    /// Was: input below the rounding floor was recorded as spent while convert() floored
    /// the output to zero, so the swap consumed it and _settleDirect skipped the tier --
    /// the tokens stayed in the pool credited to no one. Now the tier walk breaks and the
    /// remainder flows to _disposeLeftover.
    function testSubRoundingInputIsRefundedNotConsumed() public {
        uint256 quoteBefore = token2.balanceOf(trader1);
        uint256 poolQuoteBefore = token2.balanceOf(address(pool));

        uint256 out = _buy(1);

        assertEq(out, 0, "nothing could be bought at this size");
        assertEq(token2.balanceOf(trader1), quoteBefore, "was 1 wei poorer before M5");
        assertEq(token2.balanceOf(address(pool)), poolQuoteBefore, "and the pool holds no orphan");
        assertEq(_lmp(), LISTED, "no fill, so nothing reported");
    }

    // ================================================ still open, by design

    /// NOT mitigated, and deliberately so: a pair with a healthy two-sided book but no
    /// in-range pool position is unswappable, because direct settlement has no path that
    /// crosses resting orders. That is the trade-off the design was chosen for -- changing
    /// it means changing the design, not adding a guard. Pinned so it stays a known
    /// property rather than becoming a surprise.
    function testHealthyBookWithNoPoolLiquidityIsStillUnswappable() public {
        vm.prank(trader2);
        matchingEngine.limitSell(address(token1), address(token2), 105e8, 50e18, true, 1, trader2);
        vm.prank(trader2);
        matchingEngine.limitBuy(address(token1), address(token2), 95e8, 50e18, true, 1, trader2);

        vm.prank(positionManager);
        pool.removeLiquidity(1, 1000e18, 1000e18, lp1);

        vm.startPrank(trader1);
        token2.approve(address(router), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IPool.NoLiquidityInRange.selector, LISTED));
        router.swap(
            _path(address(token2), address(token1)), 1e18, 0, trader1, ISwapRouter.RemainderMode.Refund, empty
        );
        vm.stopPrank();
    }
}
