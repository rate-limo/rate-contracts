// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {SwapRouter} from "../../src/swap/SwapRouter.sol";
import {ISwapRouter} from "../../src/swap/interfaces/ISwapRouter.sol";
import {IOrderbook} from "../../src/exchange/interfaces/IOrderbook.sol";
import {MockToken} from "../../src/mock/MockToken.sol";
import {Pool} from "../../src/swap/Pool.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";

/// The rounding-floor findings were all measured on an 18/18 pair, where `decDiff` is 1 and
/// drops out of `Orderbook.convert` entirely. On an asymmetric pair it does not: convert
/// computes base out as `(amount * 1e8 / price) * decDiff` and quote out as
/// `(amount * price / 1e8) / decDiff`, so the divisor -- and therefore the floor -- lands on
/// a different side and at a different magnitude.
///
/// This suite pins an 18-decimal base against a 6-decimal quote (the WETH/USDC shape) and
/// measures both floors directly, rather than extrapolating from the symmetric case.
contract AsymmetricDecimalsTest is PoolBaseSetup {
    SwapRouter router;
    ISwapRouter.RemainderConfig empty;

    MockToken baseToken; // 18 decimals
    MockToken quoteToken; // 6 decimals
    Pool asymPool;

    uint256 constant LISTED = 100e8;
    uint32 constant TIER = 5000000; // 5%
    uint256 constant BUY_FILL = 105e8;
    uint256 constant SELL_FILL = 95e8;

    function setUp() public override {
        super.setUp();
        router = new SwapRouter(address(poolFactory));
        matchingEngine.setSwapRouter(address(router));

        baseToken = new MockToken("Base18", "B18", 18);
        quoteToken = new MockToken("Quote6", "Q6", 6);

        baseToken.mint(trader1, 1000000e18);
        quoteToken.mint(trader1, 1000000e6);
        baseToken.mint(lp1, 1000000e18);
        quoteToken.mint(lp1, 1000000e6);

        matchingEngine.addPair(
            address(baseToken),
            address(quoteToken),
            LISTED,
            0,
            address(baseToken),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        vm.warp(block.timestamp + 600); // clear InsufficientHistory

        asymPool = Pool(poolFactory.getPool(address(baseToken), address(quoteToken)));

        vm.prank(lp1);
        baseToken.approve(address(asymPool), 1000000e18);
        vm.prank(lp1);
        quoteToken.approve(address(asymPool), 1000000e6);
        vm.prank(positionManager);
        // 1000 base (18dp) against 100,000 quote (6dp) -- roughly balanced at a price of 100.
        asymPool.addLiquidity(50e8, 150e8, TIER, 1000e18, 100000e6, lp1);
    }

    function _lmp() private view returns (uint256) {
        return IOrderbook(asymPool.orderbook()).lmp();
    }

    function _path(address a, address b) private pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function _buy(uint256 amountIn) private returns (uint256 out) {
        vm.startPrank(trader1);
        quoteToken.approve(address(router), amountIn);
        out = router.swap(
            _path(address(quoteToken), address(baseToken)),
            amountIn,
            0,
            trader1,
            ISwapRouter.RemainderMode.Refund,
            empty
        );
        vm.stopPrank();
    }

    function _sell(uint256 amountIn) private returns (uint256 out) {
        vm.startPrank(trader1);
        baseToken.approve(address(router), amountIn);
        out = router.swap(
            _path(address(baseToken), address(quoteToken)),
            amountIn,
            0,
            trader1,
            ISwapRouter.RemainderMode.Refund,
            empty
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ sanity

    function testTheAsymmetricPairTradesAtAll() public {
        uint256 out = _buy(1000e6); // 1000 USDC-shaped quote
        assertGt(out, 0, "the pair fills");
        assertEq(_lmp(), BUY_FILL, "and reports the tier bound like any other pair");
    }

    // ------------------------------------------------------------------ the floors

    /// The buy-side floor is unchanged in TOKEN units -- `(amount * 1e8) / price` floors
    /// before decDiff is applied, so it still bites below ~price/1e8 wei of quote. But the
    /// quote here has 6 decimals, so those same ~105 wei are 1e-4 USDC rather than 1e-16
    /// ETH: the floor is twelve orders of magnitude larger in economic terms.
    function testBuySideFloorIsUnchangedInTokenUnitsButLargerInValue() public {
        uint256 out = _buy(104); // just under price/1e8
        assertEq(out, 0, "still floors to zero output");

        setUp();
        out = _buy(105);
        assertGt(out, 0, "and clears at ~price/1e8 wei, exactly as on an 18/18 pair");
    }

    /// The finding the 18/18 measurements could not have shown. On a symmetric pair the
    /// sell side has NO floor above a price of 1.00, because quote out multiplies by price.
    /// Here it also divides by decDiff = 1e12, so a floor appears on the sell side too --
    /// and it sits far higher in token units than the buy-side one.
    function testSellSideGainsAFloorThatDoesNotExistOnASymmetricPair() public {
        uint256 out = _sell(1);
        assertEq(out, 0, "1 wei of base buys nothing -- on an 18/18 pair it would fill");

        setUp();
        out = _sell(1e9);
        assertEq(out, 0, "and so does 1e9 -- the floor is ~1e12/price, i.e. ~9.5e9 wei");

        setUp();
        out = _sell(1e11);
        assertGt(out, 0, "clearing at ~1e10 wei of base rather than the 1 wei of an 18/18 pair");
    }

    // ------------------------------------------------------------------ M5 holds here too

    /// The point of measuring: M5 was written and verified against 18/18, where the floor
    /// is one rounding unit. If it only guarded that case, an asymmetric pair would strand
    /// up to 1e12 wei of base per swap instead of ~105 wei of quote. It does not -- the
    /// guard is on `out == 0`, which is decimal-agnostic.
    function testSubRoundingSellIsRefundedNotConsumedOnAnAsymmetricPair() public {
        uint256 traderBefore = baseToken.balanceOf(trader1);
        uint256 poolBefore = baseToken.balanceOf(address(asymPool));

        uint256 out = _sell(1e9); // below the sell floor (~9.52e9 wei of base)

        assertEq(out, 0, "nothing could be bought");
        assertEq(baseToken.balanceOf(trader1), traderBefore, "and the input came back");
        assertEq(baseToken.balanceOf(address(asymPool)), poolBefore, "the pool holds no orphan");
        assertEq(_lmp(), LISTED, "no fill, no report");
    }

    function testSubRoundingBuyIsRefundedNotConsumedOnAnAsymmetricPair() public {
        uint256 traderBefore = quoteToken.balanceOf(trader1);
        uint256 poolBefore = quoteToken.balanceOf(address(asymPool));

        uint256 out = _buy(104);

        assertEq(out, 0);
        assertEq(quoteToken.balanceOf(trader1), traderBefore, "input refunded");
        assertEq(quoteToken.balanceOf(address(asymPool)), poolBefore, "nothing stranded");
    }

    // ------------------------------------------------------------------ M2 holds here too

    /// M2's threshold compares matched output against the tier's own depth, both in output
    /// units, so decimals cancel and the gate is scale-free. Worth pinning rather than
    /// assuming: a threshold that behaved differently per pair would be a config trap.
    function testReportGateIsDecimalAgnostic() public {
        _sell(1e13); // clears the sell floor, far below the report threshold
        assertEq(_lmp(), LISTED, "a fill this small still cannot move the price");

        setUp();
        _sell(1e18); // 1 whole base token
        assertEq(_lmp(), SELL_FILL, "and a real trade still can");
    }
}
