// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {MatchingEngine} from "../../../src/exchange/MatchingEngine.sol";
import {MatchingLib} from "../../../src/exchange/libraries/MatchingLib.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";
import {Orderbook} from "../../../src/exchange/orderbooks/Orderbook.sol";
import {StopOrderEngine} from "../../../src/exchange/StopOrderEngine.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * A gas-starved order that has matched NOTHING reverts `InsufficientGasToMatch`.
 *
 * Halt-and-rest (`GasStarvedMatching.t.sol`) is right after a partial fill. With zero
 * matches it was a trap, found on RISE KPRF1448/tUSD on 2026-10-04: the order "succeeded"
 * by resting its whole amount ON the opposite head -- a bid and an ask both at 500 -- and
 * that success was what `eth_estimateGas` converged on, because its binary search returns
 * the cheapest gas limit that does not revert. Wallets were quoted a limit that could not
 * match, and the book locked.
 *
 * forge cannot call `eth_estimateGas`, so this pins the property it relies on: across a
 * sweep of gas limits, EVERY limit that succeeds on a crossing book has matched at least
 * one order, and every one that fails says why. The cheapest succeeding limit -- the
 * estimate -- therefore buys a fill.
 */
contract GasStarvedZeroMatchTest is BaseSetup {
    uint256 constant PRICE = 3e8;

    bytes32 constant MATCHED = keccak256(
        "OrderMatched(address,uint16,uint256,bool,uint256,uint256,bool,(address,address,uint256,uint256,uint256,uint256,uint64))"
    );
    bytes32 constant HALTED = keccak256("MatchingHaltedForGas(address,uint256,uint32)");

    /// Listed per test rather than in setUp: a stop book is created at `addPair`, so the
    /// stop case must wire its StopOrderEngine first.
    function _list() internal {
        matchingEngine.addPair(
            address(token1), address(token2), PRICE, 0, address(token1),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        book = Orderbook(payable(orderbookFactory.getPair(address(token1), address(token2))));
    }

    function _ask(uint256 price) internal {
        vm.prank(trader1);
        matchingEngine.limitSell(IMatchingEngine.LimitOrderInput({
            base: address(token1), quote: address(token2), price: price,
            amount: 1e18, isMaker: true, n: 1, recipient: trader1
        }));
    }

    function _bid(uint256 price, uint256 cap, bool isMaker)
        internal
        returns (bool ok, bytes memory ret, uint256 matched, bool halted)
    {
        bytes memory call_ = abi.encodeCall(MatchingEngine.limitBuy, (
            IMatchingEngine.LimitOrderInput({
                base: address(token1), quote: address(token2), price: price,
                amount: 10e18, isMaker: isMaker, n: 5, recipient: trader2
            })
        ));
        vm.recordLogs();
        vm.prank(trader2);
        (ok, ret) = address(matchingEngine).call{gas: cap}(call_);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == MATCHED) matched++;
            else if (logs[i].topics[0] == HALTED) halted = true;
        }
    }

    function _isNamed(bytes memory ret) internal pure returns (bool) {
        return ret.length == 4 && bytes4(ret) == MatchingLib.InsufficientGasToMatch.selector;
    }

    /// The RISE shape: a crossing bid sent with too little gas to take even one ask.
    function test_zeroMatch_revertsByName_andLeavesTheBookAlone() public {
        _list();
        _ask(PRICE);
        (bool ok, bytes memory ret, uint256 matched,) = _bid(PRICE, 600_000, true);
        assertFalse(ok, "a crossing order that can afford no match must revert");
        assertTrue(_isNamed(ret), "with InsufficientGasToMatch, not empty out-of-gas data");
        assertEq(matched, 0);
        assertEq(book.askHead(), PRICE, "the ask is untouched");
        assertEq(book.bidHead(), 0, "and nothing rests on it -- no locked book");
    }

    /// The guard only fires inside the matching loop, so an order that does not cross
    /// rests at the same low gas limit exactly as before.
    function test_nonCrossingOrder_atTheSameGas_stillRests() public {
        _list();
        _ask(PRICE);
        (bool ok,,,) = _bid(PRICE - 1e6, 600_000, true);
        assertTrue(ok, "a bid below the ask never reaches the guard");
        assertEq(book.bidHead(), PRICE - 1e6);
    }

    /// The estimateGas property, over a ladder of five asks.
    function test_everySucceedingGasLimit_buysAFill() public {
        _list();
        bool sawNamed;
        bool sawPartial;
        for (uint256 cap = 450_000; cap <= 1_600_000; cap += 10_000) {
            uint256 snap = vm.snapshotState();
            for (uint256 i = 0; i < 5; i++) _ask(PRICE + i * 1e6);
            (bool ok, bytes memory ret, uint256 matched, bool halted) = _bid(PRICE + 10e6, cap, true);
            vm.revertToState(snap);
            if (ok) {
                assertGt(matched, 0, string.concat("succeeded with zero matches at cap ", vm.toString(cap)));
                if (halted) sawPartial = true;
            } else {
                assertTrue(_isNamed(ret), string.concat("unnamed revert at cap ", vm.toString(cap)));
                sawNamed = true;
            }
        }
        assertTrue(sawNamed, "the sweep must reach the zero-match revert, or it proves nothing");
        assertTrue(sawPartial, "and a partial fill that halts and rests -- that path is kept");
    }

    /// Partial fills keep the documented behaviour: halt, keep the fill, rest the rest.
    function test_partialFill_stillHaltsAndRestsTheRemainder() public {
        _list();
        for (uint256 cap = 600_000; cap <= 1_600_000; cap += 10_000) {
            uint256 snap = vm.snapshotState();
            for (uint256 i = 0; i < 5; i++) _ask(PRICE + i * 1e6);
            (bool ok,, uint256 matched, bool halted) = _bid(PRICE + 10e6, cap, true);
            if (ok && halted) {
                assertGt(matched, 0);
                assertGt(book.bidHead(), 0, "the remainder rests");
                vm.revertToState(snap);
                return;
            }
            vm.revertToState(snap);
        }
        revert("no cap produced a partial fill that halted");
    }

    /**
     * The stop-order passes are NOT strict. They run inside another trader's transaction,
     * after that trader's own pass, with their own `i` starting at zero -- so a strict guard
     * there would revert a taker's whole order because a stop it woke ran short of gas.
     *
     * Here the regular book is empty, so the taker's own pass never enters the matching loop
     * and cannot reach the guard: any `InsufficientGasToMatch` would have to come from the
     * stop pass. The sweep requires there is none, and that at least one limit DID halt in
     * the stop pass and still succeeded -- otherwise the sweep never exercised the path.
     */
    function test_stopPass_haltsRatherThanReverting() public {
        StopOrderEngine stopEngine = new StopOrderEngine(address(matchingEngine));
        matchingEngine.setStopOrderEngine(address(stopEngine));
        _list();
        matchingEngine.setSpread(address(token1), address(token2), 20_000_000, 20_000_000, true);
        matchingEngine.setSpread(address(token1), address(token2), 20_000_000, 20_000_000, false);
        vm.startPrank(trader1);
        token1.approve(address(stopEngine), type(uint256).max);
        stopEngine.placeStopLimit(address(token1), address(token2), false, 29e7, 25e7, 1e18, trader1);
        vm.stopPrank();
        // lmp under the trigger with a trade that empties the book.
        _ask(28e7);
        vm.prank(trader2);
        matchingEngine.limitBuy(IMatchingEngine.LimitOrderInput({
            base: address(token1), quote: address(token2), price: 28e7,
            amount: 28e7 * 1e10, isMaker: false, n: 1, recipient: trader2
        }));
        assertEq(book.askHead(), 0, "setup: the regular book is empty");

        bool sawStopHalt;
        for (uint256 cap = 300_000; cap <= 2_000_000; cap += 10_000) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret,, bool halted) = _bid(28e7, cap, false);
            vm.revertToState(snap);
            assertFalse(!ok && _isNamed(ret), string.concat("a stop pass reverted by name at cap ", vm.toString(cap)));
            if (ok && halted) sawStopHalt = true;
        }
        assertTrue(sawStopHalt, "no cap halted inside the stop pass, so this proved nothing");
    }
}
