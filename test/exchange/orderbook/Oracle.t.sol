// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8;

import {Test} from "forge-std/Test.sol";
import {Oracle, ORACLE_CARDINALITY} from "../../../src/exchange/libraries/Oracle.sol";
import {OracleHarness} from "../OracleHarness.sol";

/// @notice Unit tests for the `Oracle` TWAP ring buffer in isolation (no Orderbook/MatchingEngine
/// setup needed -- see docs/swap/design.md for how this plugs into `Orderbook.setLmp`, and
/// `test/exchange/orderbook/PriceOracle.t.sol` for the integration-level tests against the real
/// contract, including the same-block-manipulation scenario against actual trades).
contract OracleTest is Test {
    OracleHarness harness;

    function setUp() public {
        harness = new OracleHarness();
    }

    function testInitializeSeedsSlotZero() public {
        harness.initialize(1000);
        (uint32 ts, uint256 cumulative, bool initialized) = harness.observationAt(0);
        assertEq(ts, 1000);
        assertEq(cumulative, 0);
        assertTrue(initialized);
        assertEq(harness.index(), 0);
    }

    function testInitializeRevertsOnSecondCall() public {
        harness.initialize(1000);
        vm.expectRevert(Oracle.AlreadyInitialized.selector);
        harness.initialize(2000);
    }

    function testWriteRevertsIfNotInitialized() public {
        vm.expectRevert(Oracle.NotInitialized.selector);
        harness.write(1000, 100);
    }

    /// @notice The very first `write` call lands in the same block `initialize` seeded slot 0
    /// in -- the listing sequence relies on this being a safe no-op (the seed observation must
    /// survive untouched, not get silently overwritten by the first real write racing it in the
    /// same block).
    function testFirstWriteInSameBlockAsInitializeIsANoOp() public {
        harness.initialize(1000);
        harness.write(1000, 999999); // same timestamp as initialize
        assertEq(harness.index(), 0); // did not advance
        (uint32 ts, uint256 cum, bool initialized) = harness.observationAt(0);
        assertEq(ts, 1000);
        assertEq(cum, 0); // untouched by the throttled write's price argument
        assertTrue(initialized);
    }

    function testWriteThrottlesToOncePerBlock() public {
        harness.initialize(1000);
        harness.write(1100, 100); // index -> 1, cumulative = 100 * 100 = 10000
        assertEq(harness.index(), 1);
        (uint32 ts1, uint256 cum1, ) = harness.observationAt(1);

        // Second write in the *same* block (same timestamp) must no-op: index unchanged, and
        // the slot's data must reflect only the first write, not this second call's price.
        harness.write(1100, 999999);
        assertEq(harness.index(), 1);
        (uint32 ts2, uint256 cum2, ) = harness.observationAt(1);
        assertEq(ts2, ts1);
        assertEq(cum2, cum1);
        assertEq(cum1, 10000);
    }

    function testTwapOverConstantPriceEqualsThatPrice() public {
        harness.initialize(1000);
        harness.write(1600, 100); // price 100 held for 600s

        (uint256 price, uint32 window) = harness.twap(1600, 100, 500);
        assertEq(price, 100);
        assertEq(window, 600); // actual window is the full retained history, >= requested 500
    }

    /// @notice Every other twap test in this file resolves `_findAtLeast`'s binary search to the
    /// oldest retained observation (logical position 0) -- including the full-buffer wraparound
    /// test below, which just moves *which* observation counts as "oldest". None of them
    /// exercise the search actually landing on an *interior* observation, which is where the
    /// library's own docstring says the load-bearing `mid = (lo+hi+1)/2` lo/hi bias lives. This
    /// test constructs six observations spaced 100s apart and requests a window that must
    /// resolve to the middle one (neither oldest nor newest).
    function testTwapFindsAnInteriorObservationNotJustOldestOrNewest() public {
        harness.initialize(0);
        for (uint32 t = 100; t <= 500; t += 100) {
            harness.write(t, 100); // constant price -- isolates the search target, not the math
        }
        // Six observations at t = 0, 100, 200, 300, 400, 500 (logical positions 0..5). Querying
        // "now" = 500 with minSecondsAgo = 250: ages are 500,400,300,200,100,0 for positions
        // 0..5 respectively. Position 2 (t=200, age=300) is the newest one still >= 250 old;
        // position 3 (t=300, age=200) is not. So the target must be position 2 -- interior,
        // not position 0 (oldest) or position 5 (newest).
        (uint256 price, uint32 window) = harness.twap(500, 100, 250);
        // cumulative(200)=100*200=20000, cumulative(500)=100*500=50000.
        // (50000-20000)/(500-200) = 30000/300 = 100.
        assertEq(price, 100);
        assertEq(window, 300); // 500 - 200, confirming the target was t=200 (position 2), not t=0
    }

    function testTwapReflectsWeightedAverageAcrossPriceChanges() public {
        harness.initialize(1000);
        harness.write(1300, 100); // price 100 held for [1000,1300) = 300s
        harness.write(1500, 200); // price 200 held for [1300,1500) = 200s
        // currentPrice from 1500 onward is 300 (not yet written -- simulates the live lmp
        // after the last trade, extrapolated forward at query time).

        (uint256 price, uint32 window) = harness.twap(1500, 300, 500);
        // (100*300 + 200*200) / 500 = 70000 / 500 = 140
        assertEq(price, 140);
        assertEq(window, 500);
    }

    function testTwapExtrapolatesToQueryTimeUsingCurrentPrice() public {
        harness.initialize(1000);
        harness.write(1300, 100); // [1000,1300) @ 100
        harness.write(1500, 200); // [1300,1500) @ 200
        // Query 50s after the last write, with no new write yet -- currentPrice (300) must be
        // weighted for the [1500,1550) gap via extrapolation, not ignored.
        (uint256 price, uint32 window) = harness.twap(1550, 300, 550);
        // (100*300 + 200*200 + 300*50) / 550 = 85000 / 550 = 154 (integer division)
        assertEq(price, 154);
        assertEq(window, 550);
    }

    function testTwapRevertsWhenHistoryInsufficient() public {
        harness.initialize(1000);
        vm.expectRevert(abi.encodeWithSelector(Oracle.InsufficientHistory.selector, uint32(10), uint32(0)));
        harness.twap(1000, 100, 10);
    }

    function testTwapRevertsOnZeroWindow() public {
        harness.initialize(1000);
        vm.expectRevert(abi.encodeWithSelector(Oracle.InvalidWindow.selector, uint32(0)));
        harness.twap(1000, 100, 0);
    }

    /// @notice The core security property: a single-block price manipulation immediately before
    /// a query only shifts the TWAP by a small fraction of the true deviation, unlike reading
    /// `lmp()` directly (which would report the manipulated price with 100% weight).
    function testTwapResistsSingleBlockManipulation() public {
        harness.initialize(0);
        // Stable, organic price of 100 held for a full 600-second window.
        harness.write(600, 100);

        // Attacker's trade lands at t=600 (same instant as the write above establishes the end
        // of the stable period) and moves the *live* price 10x to 1000. A victim transaction
        // reads twap() one second later, in the very next block.
        uint256 manipulatedPrice = 1000;
        (uint256 twapPrice, uint32 window) = harness.twap(601, manipulatedPrice, 590);

        // (100*600 + 1000*1) / 601 = 61000 / 601 = 101 (integer division) -- ~1% off true price,
        // versus lmp() alone reporting 1000 (a 900% deviation from the true pre-attack price).
        assertEq(twapPrice, 101);
        assertEq(window, 601);
        assertLt(twapPrice, 150); // nowhere close to the manipulated price
    }

    function testBufferWraparoundEvictsOldestObservation() public {
        harness.initialize(0);

        uint16 cardinality = _cardinality();
        // Write exactly `cardinality` observations at t=1..cardinality, each holding price 100.
        // The write at t=cardinality wraps the ring buffer index back to 0, overwriting the
        // original t=0 seed observation.
        for (uint32 t = 1; t <= cardinality; t++) {
            harness.write(t, 100);
        }
        assertEq(harness.index(), 0); // wrapped exactly back to slot 0

        // The original t=0 observation is gone; oldest retained is now at t=1, giving only
        // `cardinality - 1` seconds of real history. Requesting exactly `cardinality -1` succeeds
        // with the full available window.
        (uint256 price, uint32 window) = harness.twap(cardinality, 100, cardinality - 1);
        assertEq(price, 100);
        assertEq(window, cardinality - 1);
    }

    /// @notice The buffer-capacity case that reverting unconditionally would get wrong: once the
    /// ring buffer is fully wrapped (every slot has been written at least once), the oldest
    /// observation it can possibly retain is a hard capacity limit, not a bootstrap gap. A market
    /// that writes at least once every block on a fast chain can be in this state *forever* for
    /// large `minSecondsAgo` values -- reverting here would permanently brick every caller
    /// requesting that window. Instead this degrades: return the longest window the buffer
    /// actually has, and let the caller see that via the returned `actualWindow`.
    function testTwapDegradesInsteadOfRevertingWhenBufferAtCapacity() public {
        harness.initialize(0);
        uint16 cardinality = _cardinality();
        for (uint32 t = 1; t <= cardinality; t++) {
            harness.write(t, 100);
        }

        // Request a window the buffer's fixed capacity can never satisfy, no matter how much
        // real time passes -- e.g. 10x the buffer's total capacity. Must not revert.
        (uint256 price, uint32 window) = harness.twap(cardinality, 100, uint32(cardinality) * 10);
        assertEq(price, 100);
        assertEq(window, cardinality - 1); // the longest window a full buffer of one-per-block writes can give
    }

    /// @notice Companion to the above: confirms the *not-yet-wrapped* case still reverts rather
    /// than silently degrading, since degrading there would mean fabricating history that never
    /// happened (as opposed to the at-capacity case, which degrades to real, if shorter, history).
    function testTwapStillRevertsWhenBufferNotYetWrapped() public {
        OracleHarness fresh = new OracleHarness();
        fresh.initialize(0);
        fresh.write(10, 100); // buffer far from full -- only 2 observations exist

        vm.expectRevert(
            abi.encodeWithSelector(Oracle.InsufficientHistory.selector, uint32(1000), uint32(10))
        );
        fresh.twap(10, 100, 1000);
    }

    function _cardinality() internal pure returns (uint16) {
        return ORACLE_CARDINALITY;
    }
}
