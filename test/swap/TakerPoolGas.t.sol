// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {MatchingEngine} from "../../src/exchange/MatchingEngine.sol";
import {MatchingLib} from "../../src/exchange/libraries/MatchingLib.sol";
import {IMatchingEngine} from "../../src/exchange/interfaces/IMatchingEngine.sol";
import {BandBaseSetup} from "./BandBaseSetup.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * `MATCH_GAS_RESERVE` must also cover the TAKER tail, which ends in a POOL SWAP.
 *
 * ## The gap this closes
 *
 * `test/exchange/orderbook/ReserveSweep.t.sol` sweeps gas caps for maker AND taker orders,
 * and its taker cases prove less than they appear to: it runs on `OrderbookBaseSetup`, which
 * wires no band pool. `PoolFallbackLib.route` opens with
 *
 *     address pool = IOrderbook(pair).getPool();
 *     if (pool == address(0)) return remaining;
 *
 * so there the taker tail is a refund and nothing else. That matters because the taker tail is
 * the LONGER one: `detMake` approves the pool, calls `swap`, reports the price through the rail
 * and refunds the rest, where a maker's tail is one `placeBid`. Sizing the reserve against the
 * maker tail alone leaves the expensive path unmeasured.
 *
 * This suite runs the same sweep on `BandBaseSetup` -- a real engine, orderbook, oracle, band
 * pool, manager and router -- with the pool funded, so the swap actually executes.
 *
 * ## What it found, and what changed (2026-10-04)
 *
 * Below ~610,000 the engine used to halt with `matched: 0` and hand the whole amount to the
 * pool, which DECLINED it: `route` passed the order's own price as a GROSS `minOut` while the
 * pool pays out NET of its fee, so it answered `SlippageExceeded(50.000e18, 49.900e18)` --
 * short by exactly its fee -- and the taker was refunded. Two things changed:
 *
 *   * `route` now deducts the pool's band-0 fee from `minOut` (PoolFallbackLib), so a pool
 *     filling at the order's price is accepted. Only a worse PRICE is refused.
 *   * a taker starved before its FIRST match no longer gets that far: it reverts
 *     `InsufficientGasToMatch` (MatchingLib), so the cheapest gas limit that succeeds -- what
 *     `eth_estimateGas` converges on -- always buys at least one fill.
 *
 * So this file's property is now: no gas limit makes a taker with a pool revert WITHOUT A
 * NAME. An unnamed revert is out of gas mid-write, which is what the reserve exists to prevent.
 *
 * The pool carries its own second guard, `BandPool.SWAP_GAS_RESERVE = 180_000`, which halts the
 * band walk only once `t > 0`.
 */
contract TakerPoolGasTest is BandBaseSetup {
    uint32 constant LEVELS = 6;

    /// Coarse on purpose: each sample seeds bands and a book, so a fine step is very expensive.
    uint256 constant CAP_LO = 400_000;
    uint256 constant CAP_HI = 2_000_000;
    uint256 constant CAP_STEP = 50_000;

    bytes32 constant MATCHED = keccak256(
        "OrderMatched(address,uint16,uint256,bool,uint256,uint256,bool,(address,address,uint256,uint256,uint256,uint256,uint64))"
    );
    bytes32 constant POOLED = keccak256("RemainderRoutedToPool(address,address,uint256,uint256)");

    function _restAsks() internal {
        for (uint32 i = 0; i < LEVELS; i++) {
            vm.startPrank(trader1);
            token1.approve(address(matchingEngine), type(uint256).max);
            matchingEngine.limitSell(IMatchingEngine.LimitOrderInput({
                base: address(token1), quote: address(token2),
                price: LISTING + i * 1e8, amount: 1e18,
                isMaker: true, n: 1, recipient: trader1
            }));
            vm.stopPrank();
        }
    }

    /// A book and a funded pool, so both venues are reachable from one order.
    function _venues() internal {
        _seedBands(100e18);
        _restAsks();
    }

    /// `isMaker: false`, so the remainder goes to the pool and then home -- never onto the book.
    function _takerBuy(uint256 cap)
        internal
        returns (bool ok, uint256 matched, bool pooled)
    {
        (ok, matched, pooled,) = _takerBuyRaw(cap);
    }

    function _takerBuyRaw(uint256 cap)
        internal
        returns (bool ok, uint256 matched, bool pooled, bytes memory ret)
    {
        vm.startPrank(trader2);
        token2.approve(address(matchingEngine), type(uint256).max);
        vm.stopPrank();

        bytes memory call_ = abi.encodeCall(MatchingEngine.limitBuy, (
            IMatchingEngine.LimitOrderInput({
                base: address(token1), quote: address(token2),
                price: LISTING + 5e8, amount: 5000e18,
                isMaker: false, n: LEVELS, recipient: trader2
            })
        ));
        vm.recordLogs();
        vm.prank(trader2);
        (ok, ret) = address(matchingEngine).call{gas: cap}(call_);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == MATCHED) matched++;
            else if (logs[i].topics[0] == POOLED) pooled = true;
        }
    }

    /// Guards the suite itself: if the pool leg never runs, every assertion below is vacuous.
    /// This is the check whose absence made ReserveSweep's taker cases look like coverage.
    function test_theSweepIsNotVacuous_poolLegRuns() public {
        _venues();
        (bool ok,, bool pooled) = _takerBuy(30_000_000);
        assertTrue(ok, "an amply funded taker must succeed");
        assertTrue(pooled, "RemainderRoutedToPool must fire, or this fixture proves nothing");
    }

    /// The property: no gas limit makes a taker with a pool revert without a name, and every
    /// limit that succeeds bought something -- from the book or the pool.
    function test_takerWithPool_neverReverts() public {
        for (uint256 cap = CAP_LO; cap <= CAP_HI; cap += CAP_STEP) {
            uint256 snap = vm.snapshotState();
            _venues();
            (bool ok, uint256 matched, bool pooled, bytes memory ret) = _takerBuyRaw(cap);
            vm.revertToState(snap);
            if (ok) assertTrue(matched > 0 || pooled, "a succeeding taker must have filled something");
            else ok = ret.length == 4 && bytes4(ret) == MatchingLib.InsufficientGasToMatch.selector;
            assertTrue(ok, string.concat(
                "a gas-starved TAKER reverted at cap ", vm.toString(cap),
                ". MATCH_GAS_RESERVE does not cover the pool tail."
            ));
        }
    }

    /// A taker too starved to fill anything reverts BY NAME, keeps its money and leaves no
    /// allowance behind. It used to "succeed" here having done nothing, which is the path
    /// `eth_estimateGas` settled on -- so wallets were quoted a limit that could never fill.
    function test_starvedTaker_revertsByNameAndLeavesNoAllowance() public {
        _venues();
        uint256 quoteBefore = token2.balanceOf(trader2);
        uint256 baseBefore = token1.balanceOf(trader2);

        (bool ok, uint256 matched, bool pooled, bytes memory ret) = _takerBuyRaw(600_000);

        assertFalse(ok, "a taker that cannot afford one match must revert");
        assertEq(bytes4(ret), MatchingLib.InsufficientGasToMatch.selector, "and say why");
        assertEq(matched, 0, "nothing matched");
        assertFalse(pooled, "nothing reached the pool");
        assertEq(token2.balanceOf(trader2), quoteBefore, "a taker that filled nothing must be whole");
        assertEq(token1.balanceOf(trader2), baseBefore, "nothing was bought");
        assertEq(
            token2.allowance(address(matchingEngine), address(pool)),
            0,
            "route() must clear the allowance it set when the swap did not happen"
        );
    }
}
