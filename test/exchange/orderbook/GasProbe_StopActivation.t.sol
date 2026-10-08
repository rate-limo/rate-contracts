// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";
import {StopOrderEngine} from "../../../src/exchange/StopOrderEngine.sol";
import {console} from "forge-std/console.sol";

/**
 * What one stop activation costs, isolated.
 *
 * Three orders of the same shape, differing only in what the handoff finds:
 *
 *   noStopBook      no StopOrderEngine wired at all -- StopOrderHandoffLib returns
 *                   on its first line. The floor.
 *   emptyQueue      the engine is wired and matchRemainder runs, but activate()
 *                   pops nothing. The cost of asking.
 *   oneActivation   exactly one stop crosses, is placed in the book, and the
 *                   taker's second pass fills against it.
 *
 * The gap between `emptyQueue` and `oneActivation` is what a single activation costs,
 * and it is the number to watch when the resting price gains a rail: everything else
 * in the call is identical.
 */
contract GasProbeStopActivationTest is BaseSetup {
    uint256 private constant INITIAL_PRICE = 100e8;
    uint32 private constant WIDE = 20_000_000;

    StopOrderEngine private stopEngine;

    function setUp() public override {
        super.setUp();
        stopEngine = new StopOrderEngine(address(matchingEngine));
        matchingEngine.setStopOrderEngine(address(stopEngine));
        matchingEngine.addPair(
            address(token1), address(token2), INITIAL_PRICE, 0, address(token1),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        matchingEngine.setSpread(address(token1), address(token2), WIDE, WIDE, true);
        matchingEngine.setSpread(address(token1), address(token2), WIDE, WIDE, false);
        vm.startPrank(trader1);
        token1.approve(address(stopEngine), type(uint256).max);
        token2.approve(address(stopEngine), type(uint256).max);
        vm.stopPrank();
    }

    /// lmp to 88, below the stop trigger of 90, without going near the stop book.
    function _pushPriceUnderTheTrigger() private {
        vm.prank(trader1);
        matchingEngine.limitSell(IMatchingEngine.LimitOrderInput({
            base: address(token1), quote: address(token2), price: 88e8,
            amount: 1e18, isMaker: true, n: 2, recipient: trader1
        }));
        vm.prank(trader2);
        matchingEngine.limitBuy(IMatchingEngine.LimitOrderInput({
            base: address(token1), quote: address(token2), price: 88e8,
            amount: 88e18, isMaker: false, n: 1, recipient: trader2
        }));
    }

    /// The measured order. The regular book is empty by this point, so pass 1 matches
    /// nothing and the whole thing reaches the handoff.
    function _measureTaker() private returns (uint256 used) {
        vm.prank(trader2);
        uint256 before = gasleft();
        matchingEngine.limitBuy(IMatchingEngine.LimitOrderInput({
            base: address(token1), quote: address(token2), price: 88e8,
            amount: 88e18, isMaker: false, n: 3, recipient: trader2
        }));
        used = before - gasleft();
    }

    function test_gas_noStopBook() public {
        matchingEngine.setStopOrderEngine(address(0));
        _pushPriceUnderTheTrigger();
        console.log("noStopBook    ", _measureTaker());
    }

    function test_gas_emptyQueue() public {
        _pushPriceUnderTheTrigger();
        console.log("emptyQueue    ", _measureTaker());
    }

    function test_gas_oneActivation() public {
        vm.prank(trader1);
        stopEngine.placeStopLimit(
            address(token1), address(token2), false, 90e8, 80e8, 1e18, trader1
        );
        _pushPriceUnderTheTrigger();
        console.log("oneActivation ", _measureTaker());
    }
}
