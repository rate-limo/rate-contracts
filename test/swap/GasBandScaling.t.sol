// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {BandPoolBase} from "./BandPoolBase.sol";

/**
 * The measurement this whole design was aimed at, kept as a permanent test rather
 * than a one-off. Any future change that reads a position during a swap
 * reintroduces the slope, and nothing else in the suite would notice.
 *
 * The pool this replaces measured 3,684 gas per idle position at 5 matched and
 * 11,904 at 20 -- dead linear, with ~2,401 idle positions enough to make a
 * full-width swap consume a 30M block.
 */
contract GasBandScalingTest is BandPoolBase {
    function _measure(uint256 lps) internal {
        for (uint256 i = 0; i < lps; i++) _addTo(0, 1_000e18);
        vm.prank(taker);
        uint256 g0 = gasleft();
        router.swap(address(pool), 100e18, true, taker, 0);
        console2.log(lps, g0 - gasleft());
    }

    function testLps1() public { _measure(1); }
    function testLps50() public { _measure(50); }
    function testLps100() public { _measure(100); }
    function testLps200() public { _measure(200); }
    function testLps1000() public { _measure(1000); }

    /// The pass condition is flatness, not a target.
    ///
    /// Two FRESH pools rather than one: after a swap a band holds both base and
    /// quote, and a base-only deposit into a two-sided band correctly mints zero
    /// shares under the lesser-ratio rule. Depositing between swaps would be
    /// measuring that rule, not the scaling property.
    ///
    /// The first fresh pool pays the cold-access cost of the router, tokens, book and
    /// engine; one discarded pool warms them so both measurements see the same state.
    function test_swapGasIsFlatInLpCount() public {
        _freshPoolSwapGas(1);
        uint256 withOne = _freshPoolSwapGas(1);
        uint256 withThousand = _freshPoolSwapGas(1000);
        console2.log("1 LP", withOne);
        console2.log("1000 LPs", withThousand);
        assertLt(withThousand, withOne + 5000, "swap gas must not grow with LP count");
    }
}
