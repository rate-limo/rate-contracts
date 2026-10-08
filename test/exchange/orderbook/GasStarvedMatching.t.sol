pragma solidity >=0.8;

import {MatchingEngine} from "../../../src/exchange/MatchingEngine.sol";
import {MatchingLib} from "../../../src/exchange/libraries/MatchingLib.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";
import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * An order that runs low on gas mid-match must REST, not revert.
 *
 * ## The failure this pins
 *
 * An order's cost depends on what it matches, and the caller fixes the gas limit
 * before knowing what it will meet. Measured on RISE Testnet: a `limitBuy` that
 * matches nothing costs ~240,000 gas; the same call against a book with one
 * resting ask costs ~373,000. An order priced into an empty book and mined a
 * moment after someone rests an ask therefore arrives about a third short.
 *
 * Before `MATCH_GAS_RESERVE` the EVM stopped execution mid-write and the whole
 * transaction reverted -- no fill, no resting order, and EMPTY revert data, so
 * nothing downstream could name a cause. Worse, `TransferHelper` caught the
 * resulting failed sub-call and reported the string "TFF", which reads as an
 * approval problem and sends the trader to fix something that was never wrong.
 *
 * The guard turns that into the exit the loop already had: stop matching, and
 * let the caller rest what is left. A partial fill plus an order on the book is
 * what a trader expects from a sweep that ran out of room.
 */
contract GasStarvedMatchingTest is BaseSetup {
    /// Deep enough that sweeping the whole book is expensive.
    uint32 constant LEVELS = 8;

    function _listAndRestAsks() internal {
        matchingEngine.addPair(
            address(token1),
            address(token2),
            300000000,
            0,
            address(token1),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        // One ask per price level, so a buy crossing all of them pays for LEVELS
        // separate matches rather than one big one.
        for (uint32 i = 0; i < LEVELS; i++) {
            vm.prank(trader1);
            matchingEngine.limitSell(
                IMatchingEngine.LimitOrderInput({
                    base: address(token1),
                    quote: address(token2),
                    price: 300000000 + i * 1000000,
                    amount: 1e18,
                    isMaker: true,
                    n: 1,
                    recipient: trader1
                })
            );
        }
    }

    /**
     * A bid priced above every resting ask and sized to take them all, so with
     * ample gas it sweeps the book and the ONLY reason to stop early is the reserve.
     *
     * `isMaker` decides what happens to what is left over, and the two outcomes are
     * different -- `_detMake` rests the remainder only for a MAKER order; a taker's
     * is transferred straight back. Both beat a revert, which returns nothing and
     * keeps the fee, but only one of them puts an order on the book.
     */
    function _sweep(uint256 gasCap, bool isMaker) internal returns (bool ok) {
        bytes memory call_ = abi.encodeCall(
            MatchingEngine.limitBuy,
            (
                IMatchingEngine.LimitOrderInput({
                    base: address(token1),
                    quote: address(token2),
                    price: 400000000,
                    amount: 100e18,
                    isMaker: isMaker,
                    n: LEVELS,
                    recipient: trader2
                })
            )
        );
        vm.prank(trader2);
        (ok,) = address(matchingEngine).call{gas: gasCap}(call_);
    }

    /// With room to spare the book is swept -- the guard must not fire early.
    function test_amplGas_sweepsTheBookAndNeverHalts() public {
        _listAndRestAsks();

        vm.recordLogs();
        assertTrue(_sweep(30_000_000, true), "a well-funded sweep must succeed");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertFalse(_sawHalt(logs), "the reserve must not fire when gas is ample");

        // Not "every ask is gone": the bid is also capped by the pair's spread
        // limit, so the top level stays out of reach for a reason that has
        // nothing to do with gas. What matters here is that it worked through
        // the book rather than stopping at the first level.
        (, uint256 askHead) = matchingEngine.heads(address(token1), address(token2));
        assertGt(askHead, 300000000, "an unconstrained sweep should have taken several levels");
    }

    /**
     * Constrained gas: the order must survive, stop matching, and rest.
     *
     * The three assertions are the whole contract of this change:
     *  - the call does NOT revert (previously it did, with empty revert data);
     *  - asks REMAIN, proving it stopped before finishing;
     *  - a bid is on the book, proving the remainder rested rather than vanishing.
     */
    function test_lowGas_haltsAndRestsRemainderInsteadOfReverting() public {
        _listAndRestAsks();

        (, uint256 askHeadBefore) = matchingEngine.heads(address(token1), address(token2));
        assertGt(askHeadBefore, 0, "setup should leave asks resting");

        vm.recordLogs();
        // A 700,000 cap does not cover a full sweep of this book, so the reserve
        // fires and the remainder rests. ONE cap is a sample, not the property --
        // how much gas is actually left when the guard fires depends on where the
        // cap falls relative to one unit of work, so the failure is periodic in the
        // cap. `ReserveSweep.t.sol` sweeps the range and is what sizes the reserve;
        // this test pins the OUTCOME (partial fill, order on the book) at one cap.
        //
        // Do not re-derive the reserve from a number here. This comment used to read
        // "a full sweep measures 676,351 gas ... the reserve holds back 300,000,
        // leaving ~400,000 for matching", which was measured warm and made a 300,000
        // reserve look sufficient when the tail alone costs ~353,000 cold.
        bool ok = _sweep(700_000, true);
        assertTrue(ok, "a gas-starved order must rest, not revert");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(_sawHalt(logs), "matching should have halted for gas");

        (uint256 bidHead, uint256 askHead) = matchingEngine.heads(address(token1), address(token2));
        assertGt(askHead, 0, "it should have stopped before taking every ask");
        assertGt(bidHead, 0, "the unmatched remainder must be resting on the book");
    }

    /// A TAKER order halted for gas keeps its fill and is refunded the rest.
    function test_lowGas_takerIsRefundedRatherThanReverted() public {
        _listAndRestAsks();

        uint256 before = token2.balanceOf(trader2);
        vm.recordLogs();
        assertTrue(_sweep(700_000, false), "a gas-starved taker must not revert");
        assertTrue(_sawHalt(vm.getRecordedLogs()), "matching should have halted for gas");

        // It spent something (it filled some levels) but nothing like the whole
        // 100e18 it offered -- the unmatched part came back.
        uint256 spent = before - token2.balanceOf(trader2);
        assertGt(spent, 0, "it should have filled something");
        assertLt(spent, 100e18, "the unmatched remainder must be refunded, not kept");

        (uint256 bidHead,) = matchingEngine.heads(address(token1), address(token2));
        assertEq(bidHead, 0, "a taker order rests nothing -- that is what isMaker is for");
    }

    function _sawHalt(Vm.Log[] memory logs) internal pure returns (bool) {
        bytes32 topic = keccak256("MatchingHaltedForGas(address,uint256,uint32)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) return true;
        }
        return false;
    }
}
