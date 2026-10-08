// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandBaseSetup} from "./BandBaseSetup.sol";
import {IMatchingEngine} from "../../src/exchange/interfaces/IMatchingEngine.sol";
import {StopOrderEngine} from "../../src/exchange/StopOrderEngine.sol";
import {console} from "forge-std/console.sol";

/**
 * What each way of trading actually costs, measured against one another.
 *
 * `BandBaseSetup` is the only fixture with all of it wired at once -- a real
 * MatchingEngine, Orderbook and oracle, and a real BandPool behind a real
 * BandSwapRouter, on ONE pair at ONE price. So every number below is directly
 * comparable; nothing differs but the path taken.
 *
 * ## Read these as ranges, not constants
 *
 * A single number for "a limit order" would be fiction. Three things move it by more
 * than the difference between the paths:
 *
 *  - **Cold vs warm.** The first order on a pair pays for every storage slot it
 *    touches at 2,100 gas instead of 100. Both are real: somebody is always first.
 *  - **Levels matched.** Bounded by `n`, and each level is a queue pop, a settlement
 *    and a log. The marginal cost is measured below and it is the number to use when
 *    sizing `n`.
 *  - **Whether it rests.** Making an order at a price level nobody occupies inserts
 *    into a sorted linked list; making at an existing level does not.
 *
 * ## Fees and spreads
 *
 * The fixture's: 0.1% taker fee both sides, 10% market and limit spreads. A tighter
 * spread does not change these costs -- it changes which branch of the make-price rule
 * is taken, and they cost the same.
 */
contract GasProbeOrderPathsTest is BandBaseSetup {
    StopOrderEngine private stopEngine;

    function setUp() public override {
        super.setUp();

        // Wire the stop engine the way addPair would have, had it been set first.
        stopEngine = new StopOrderEngine(address(matchingEngine));
        matchingEngine.setStopOrderEngine(address(stopEngine));
        vm.prank(address(matchingEngine));
        stopEngine.createBook(address(book), address(token1), address(token2));
        vm.prank(address(matchingEngine));
        book.setOperator(address(stopEngine));

        // Approvals out of the way, so no measurement pays for one.
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(users[i]);
            token1.approve(address(matchingEngine), type(uint256).max);
            token2.approve(address(matchingEngine), type(uint256).max);
            token1.approve(address(stopEngine), type(uint256).max);
            token2.approve(address(stopEngine), type(uint256).max);
            token2.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }

        // Bands small enough that a swap can walk all three without absurd size.
        _seedBands(10e18);
        // Past the oracle window, so a swap prices off the TWAP rather than the
        // listing-price fallback. That is the path a live pool takes.
        vm.warp(block.timestamp + 601);
    }

    // ---- measured calls -------------------------------------------------------

    function _mLimitSell(address who, uint256 price, uint256 amount, uint32 n)
        private returns (uint256 used)
    {
        vm.prank(who);
        uint256 g = gasleft();
        matchingEngine.limitSell(IMatchingEngine.LimitOrderInput({
            base: address(token1), quote: address(token2), price: price,
            amount: amount, isMaker: true, n: n, recipient: who
        }));
        used = g - gasleft();
    }

    function _mLimitBuy(address who, uint256 price, uint256 amount, uint32 n)
        private returns (uint256 used)
    {
        vm.prank(who);
        uint256 g = gasleft();
        matchingEngine.limitBuy(IMatchingEngine.LimitOrderInput({
            base: address(token1), quote: address(token2), price: price,
            amount: amount, isMaker: true, n: n, recipient: who
        }));
        used = g - gasleft();
    }

    function _mMarketBuy(address who, uint256 quoteIn, uint32 n) private returns (uint256 used) {
        vm.prank(who);
        uint256 g = gasleft();
        matchingEngine.marketBuy(IMatchingEngine.MarketOrderInput({
            base: address(token1), quote: address(token2), amount: quoteIn,
            isMaker: true, n: n, recipient: who, slippageLimit: 10000000
        }));
        used = g - gasleft();
    }

    function _mSwap(address who, uint256 quoteIn) private returns (uint256 used) {
        vm.prank(who);
        uint256 g = gasleft();
        router.swap(address(pool), quoteIn, true, who, 0);
        used = g - gasleft();
    }

    /// Asks at 101, 102, 103 -- inside the 10% spread, so each rests where it asked.
    function _restThreeAsks() private {
        _mLimitSell(trader1, 101e8, 1e18, 2);
        _mLimitSell(trader1, 102e8, 1e18, 2);
        _mLimitSell(trader1, 103e8, 1e18, 2);
    }

    // ---- limit orders ---------------------------------------------------------
    //
    // One measurement per test. Calling setUp() inside a test does NOT reset storage,
    // so a second measurement in the same body runs warm and reads lower than the
    // first -- which is how the marginal subtractions underflowed on the first
    // attempt. Every test below starts from an identical cold fixture, so numbers
    // across tests are comparable; the one place warming is intended it is explicit.

    /// Cold, warm, new price level, existing price level. Four sells that match
    /// nothing, so the whole cost is deposit + make. Warming is the point here.
    function test_gas_limitOrder_make() public {
        uint256 cold = _mLimitSell(trader1, 101e8, 1e18, 2);
        uint256 warmNewLevel = _mLimitSell(trader1, 102e8, 1e18, 2);
        uint256 warmSameLevel = _mLimitSell(trader1, 102e8, 1e18, 2);
        uint256 warmOtherTrader = _mLimitSell(trader2, 102e8, 1e18, 2);

        console.log("limit make, cold (first order on the pair) ", cold);
        console.log("limit make, warm, new price level          ", warmNewLevel);
        console.log("limit make, warm, existing price level     ", warmSameLevel);
        console.log("limit make, warm, existing level, new maker", warmOtherTrader);
    }

    function test_gas_limitOrder_take1() public {
        _restThreeAsks();
        console.log("limit take, 1 level matched + make         ", _mLimitBuy(trader2, 103e8, 400e18, 1));
    }

    function test_gas_limitOrder_take3() public {
        _restThreeAsks();
        console.log("limit take, 3 levels matched + make        ", _mLimitBuy(trader2, 103e8, 400e18, 3));
    }

    /// The same take, second time round. A live pair is warm, so this is the number a
    /// regular trader actually pays -- and it is the only one comparable to the warm
    /// swap below.
    function test_gas_limitOrder_take1_warm() public {
        _restThreeAsks();
        _mLimitBuy(trader2, 103e8, 400e18, 1);
        _restThreeAsks();
        console.log("limit take, 1 level, warm                  ", _mLimitBuy(trader2, 103e8, 400e18, 1));
    }

    // ---- market orders --------------------------------------------------------
    //
    // The same shape without a price: the engine derives the limit from lmp and the
    // market spread, so a market buy is a limit buy plus one mktPrice read.

    function test_gas_marketOrder_take1() public {
        _restThreeAsks();
        console.log("market buy, 1 level matched + make         ", _mMarketBuy(trader2, 400e18, 1));
    }

    function test_gas_marketOrder_take3() public {
        _restThreeAsks();
        console.log("market buy, 3 levels matched + make        ", _mMarketBuy(trader2, 400e18, 3));
    }

    function test_gas_marketOrder_take1_warm() public {
        _restThreeAsks();
        _mMarketBuy(trader2, 400e18, 1);
        _restThreeAsks();
        console.log("market buy, 1 level, warm                  ", _mMarketBuy(trader2, 400e18, 1));
    }

    // ---- stop orders ----------------------------------------------------------

    /// Placement is its own transaction and buys nothing but a queue entry: custody
    /// moves to StopLimitOrderbook and a trigger price is inserted. No matching.
    function test_gas_stopOrder_place() public {
        vm.prank(trader1);
        uint256 g = gasleft();
        uint32 id = stopEngine.placeStopLimit(
            address(token1), address(token2), false, 95e8, 92e8, 1e18, trader1
        );
        uint256 place = g - gasleft();

        vm.prank(trader1);
        uint256 g2 = gasleft();
        stopEngine.cancel(address(token1), address(token2), false, id);
        uint256 cancel = g2 - gasleft();

        vm.prank(trader1);
        uint256 g3 = gasleft();
        stopEngine.placeStopMarket(IMatchingEngine.StopMarketInput({
            base: address(token1), quote: address(token2), isBid: false,
            stopPrice: 95e8, amount: 1e18, n: 2,
            slippageLimit: 10000000, deadline: 0, recipient: trader1
        }));
        uint256 placeMarket = g3 - gasleft();

        console.log("stop-limit place (dormant)                 ", place);
        console.log("stop-limit cancel                          ", cancel);
        console.log("stop-market place (dormant)                ", placeMarket);
    }

    /// Drive lmp under the trigger without waking anything. The ask must be made while
    /// lmp is still the listing price -- `_limitSell` drops lmp to the new ask head
    /// AFTER the make, so a stop placed later would be rejected as already crossed.
    /// The n=1 taker is fully filled, and `matchAt` reports the whole budget spent on
    /// that branch, so its handoff returns before activating anything.
    function _armWithoutWaking() private {
        _mLimitSell(trader1, 90e8, 1e18, 2);
        _mLimitBuy(trader2, 90e8, 90e18, 1);
    }

    function test_gas_stopOrder_activation_control() public {
        _armWithoutWaking();
        console.log("taker order, no stop in the queue          ", _mLimitBuy(trader2, 95e8, 200e18, 3));
    }

    function test_gas_stopOrder_activation_withStop() public {
        vm.prank(trader1);
        stopEngine.placeStopLimit(
            address(token1), address(token2), false, 95e8, 92e8, 1e18, trader1
        );
        _armWithoutWaking();
        console.log("taker order, one stop activates + fills    ", _mLimitBuy(trader2, 95e8, 200e18, 3));
    }

    // ---- the pool -------------------------------------------------------------
    //
    // A swap never touches either book. It walks bands, settles, and reports one price.

    function test_gas_swap_1band() public {
        console.log("swap, 1 band, cold                         ", _mSwap(trader1, 500e18));
    }

    function test_gas_swap_3bands() public {
        console.log("swap, 3 bands, cold                        ", _mSwap(trader1, 2500e18));
    }

    function test_gas_swap_warm() public {
        _mSwap(trader1, 200e18);
        console.log("swap, 1 band, warm (second swap on pair)   ", _mSwap(trader2, 200e18));
    }
}
