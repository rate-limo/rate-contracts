// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandBaseSetup} from "./BandBaseSetup.sol";

/**
 * What the TWAP anchor costs a swap, isolated.
 *
 * A band works out its fill price as `twap(300) × (1 ± tolerance)`. A rung would store
 * the price instead, so this call disappears from the swap path entirely. This probe
 * exists to size that saving before the rung design is committed to, rather than
 * asserting it.
 *
 * Measured under `isolate = true`, so the reads are cold the way a real transaction's
 * are -- see the gas section of contracts/CLAUDE.md for why a warm measurement here
 * would understate it.
 */
contract GasProbe_AnchorCost is BandBaseSetup {
    function test_gas_anchor_twapRead() public {
        _seedBands(1_000e18);
        // move time on so the window is populated rather than reverting InsufficientHistory
        vm.warp(block.timestamp + 1_200);

        uint256 g = gasleft();
        (uint256 price,) = book.twap(300);
        uint256 used = g - gasleft();
        emit log_named_uint("twap(300) read, warm-ish                  ", used);
        emit log_named_uint("  price it returned                       ", price);
        assertGt(price, 0);
    }

    function test_gas_anchor_twapRead_cold() public {
        _seedBands(1_000e18);
        vm.warp(block.timestamp + 1_200);
        // a fresh observation index each call is the realistic case: every swap on a
        // live pair reads a buffer somebody else has written since.
        uint256 g = gasleft();
        (uint256 p1,) = book.twap(300);
        uint256 first = g - gasleft();
        g = gasleft();
        (uint256 p2,) = book.twap(300);
        uint256 second = g - gasleft();
        emit log_named_uint("twap(300), first read in the call frame   ", first);
        emit log_named_uint("twap(300), second read (everything warm)  ", second);
        assertGt(p1, 0);
        assertGt(p2, 0);
    }
}
