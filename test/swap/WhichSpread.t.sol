// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {SwapRouter} from "../../src/swap/SwapRouter.sol";
import {ISwapRouter} from "../../src/swap/interfaces/ISwapRouter.sol";
import {IOrderbook} from "../../src/exchange/interfaces/IOrderbook.sol";

/// Which spread governs a swap? Neither, then both -- one swap can touch the market spread
/// and the limit spread for two different purposes, and the price the swapper actually pays
/// is governed by neither.
///
///   the FILL price   -> no spread at all. twap(600) x the LP position's own slippageLimit.
///                       Pool.sol and SwapRouter.sol contain zero references to spread.
///   the PRICE REPORT -> MARKET spread. MatchingEngine.reportSwap calls
///                       getSpread(pair, _, true) for both bounds. Default 0.1%.
///   a RESTED remainder -> LIMIT spread. Both Pool._disposeLeftover and
///                       SwapRouter._restAsOrder place the leftover via limitBuy/limitSell,
///                       which read getSpread(pair, _, false). Default 3%.
///
/// Worth pinning because the two defaults differ by 30x, so which one applies changes the
/// answer by an order of magnitude, and nothing in the swap path names either of them.
contract WhichSpreadTest is PoolBaseSetup {
    SwapRouter router;
    ISwapRouter.RemainderConfig empty;

    uint256 constant LISTED = 100e8;
    uint32 constant TIER = 5000000; // 5% -- the LP's own tolerance
    uint256 constant BUY_FILL = 105e8;
    uint32 constant MKT = 100000; // 0.1%, dfltMkt*
    uint32 constant LMT = 3000000; // 3%, dfltLmt*

    function setUp() public override {
        super.setUp();
        router = new SwapRouter(address(poolFactory));
        matchingEngine.setSwapRouter(address(router));
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

    function _path(address a, address b) private pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    // ------------------------------------------------------------------ the fill

    /// The price the swapper pays comes from the LP's slippageLimit and the oracle, and
    /// moving EITHER spread does not touch it. Set the market spread to 0.1% and the limit
    /// spread to 3% -- the fill is still 105.00, because 5% is the LP's number and no spread
    /// is consulted on the settlement path at all.
    function testTheFillPriceIgnoresBothSpreads() public {
        matchingEngine.setSpread(address(token1), address(token2), MKT, MKT, true);
        matchingEngine.setSpread(address(token1), address(token2), LMT, LMT, false);

        vm.startPrank(trader1);
        token2.approve(address(router), 105e18);
        uint256 out = router.swap(
            ISwapRouter.SwapInput({
                path: _path(address(token2), address(token1)),
                amountIn: 105e18,
                minAmountOut: 0,
                recipient: trader1,
                remainderMode: ISwapRouter.RemainderMode.Refund,
                remainderConfig: empty
            })
        );
        vm.stopPrank();

        // 105 quote in at a price of 105 buys ~1 base, less the 0.1% taker fee.
        uint256 implied = (105e18 * 1e8) / out;
        assertApproxEqRel(implied, BUY_FILL, 0.002e18, "the fill is the LP's 5% tier, not any spread");
    }

    // ------------------------------------------------------------------ the report

    /// The report, by contrast, is railed by the MARKET spread -- getSpread(pair, _, true).
    /// Same swap, same fill, and the recorded price differs by 30x depending on which
    /// spread is configured how.
    function testTheReportIsRailedByTheMarketSpread() public {
        matchingEngine.setSpread(address(token1), address(token2), MKT, MKT, true);
        matchingEngine.setSpread(address(token1), address(token2), LMT, LMT, false);

        vm.startPrank(trader1);
        token2.approve(address(router), 105e18);
        router.swap(
            ISwapRouter.SwapInput({
                path: _path(address(token2), address(token1)),
                amountIn: 105e18,
                minAmountOut: 0,
                recipient: trader1,
                remainderMode: ISwapRouter.RemainderMode.Refund,
                remainderConfig: empty
            })
        );
        vm.stopPrank();

        assertEq(_lmp(), 10010000000, "100.00 + the 0.1% MARKET spread");
        assertTrue(_lmp() != 103e8, "and emphatically not the 3% limit spread");
    }

    /// Proof it is the market spread and not something else: widen only the market spread
    /// and the recorded price follows it, while the limit spread stays where it was.
    function testWideningOnlyTheMarketSpreadMovesTheReport() public {
        matchingEngine.setSpread(address(token1), address(token2), LMT, LMT, false); // limit 3%
        matchingEngine.setSpread(address(token1), address(token2), 2000000, 2000000, true); // market 2%

        vm.startPrank(trader1);
        token2.approve(address(router), 105e18);
        router.swap(
            ISwapRouter.SwapInput({
                path: _path(address(token2), address(token1)),
                amountIn: 105e18,
                minAmountOut: 0,
                recipient: trader1,
                remainderMode: ISwapRouter.RemainderMode.Refund,
                remainderConfig: empty
            })
        );
        vm.stopPrank();

        assertEq(_lmp(), 102e8, "the report tracked the MARKET spread to 2%");
    }

    /// And the converse: widening only the limit spread changes nothing about the report.
    function testWideningOnlyTheLimitSpreadDoesNotMoveTheReport() public {
        matchingEngine.setSpread(address(token1), address(token2), MKT, MKT, true); // market 0.1%
        matchingEngine.setSpread(address(token1), address(token2), 9000000, 9000000, false); // limit 9%

        vm.startPrank(trader1);
        token2.approve(address(router), 105e18);
        router.swap(
            ISwapRouter.SwapInput({
                path: _path(address(token2), address(token1)),
                amountIn: 105e18,
                minAmountOut: 0,
                recipient: trader1,
                remainderMode: ISwapRouter.RemainderMode.Refund,
                remainderConfig: empty
            })
        );
        vm.stopPrank();

        assertEq(_lmp(), 10010000000, "still the 0.1% market spread -- the limit spread is irrelevant here");
    }

    // ------------------------------------------------------------------ the rested remainder

    /// The third governor. A remainder rested via RemainderMode.RestAsOrder goes through
    /// MatchingEngine.limitBuy, which reads getSpread(pair, _, FALSE) -- the LIMIT spread.
    /// So the same transaction that had its report railed at 0.1% can place an order priced
    /// off a 3% bound, and the two numbers have nothing to do with each other.
    function testARestedRemainderIsGovernedByTheLimitSpread() public {
        matchingEngine.setSpread(address(token1), address(token2), MKT, MKT, true); // market 0.1%
        matchingEngine.setSpread(address(token1), address(token2), LMT, LMT, false); // limit 3%

        ISwapRouter.RemainderConfig memory cfg;
        cfg.restPrice = 103e8; // exactly the limit-spread bound above the listing price

        // More input than the tier can absorb, so there is a remainder to rest.
        vm.startPrank(trader1);
        token2.approve(address(router), 200000e18);
        router.swap(
            ISwapRouter.SwapInput({
                path: _path(address(token2), address(token1)),
                amountIn: 200000e18,
                minAmountOut: 0,
                recipient: trader1,
                remainderMode: ISwapRouter.RemainderMode.RestAsOrder,
                remainderConfig: cfg
            })
        );
        vm.stopPrank();

        // The bid rested at the limit-spread price, which the 0.1% market spread would
        // never have permitted for a taker action.
        (uint256 bidHead,) = matchingEngine.heads(address(token1), address(token2));
        assertEq(bidHead, 103e8, "rested at the 3% LIMIT bound, not the 0.1% market one");
    }
}
