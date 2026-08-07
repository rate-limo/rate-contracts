// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8;

import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {console2} from "forge-std/console2.sol";

// TEMPORARY measurement harness: the third architecture -- no pool involvement at all.
// N maker orders rest on the book at N distinct prices (their ~212k-each placement gas is
// paid by the makers, NOT by this swap); the swapper then sends a single taker-only order
// (isMaker=false -> remainder refunds, never rests) that crosses all N. Mirrors the other
// two harnesses: amountIn slightly undershoots total depth so the Nth fill is partial.
contract GasTakerOnlyTest is PoolBaseSetup {
    function _measure(uint256 n) internal {
        // Rest N asks from trader2 (engine approvals already granted in PoolBaseSetup),
        // 0.4% price steps upward from 100.4 -- inside the 10% admin spread bound.
        uint256 topPrice;
        for (uint256 i = 0; i < n; i++) {
            topPrice = (100e8 * (1e8 + 400000 + i * 400000)) / 1e8;
            vm.prank(trader2);
            matchingEngine.limitSell(address(token1), address(token2), topPrice, 2e18, true, 1, trader2);
        }
        uint256 amountIn = 190e18 * n;
        uint256 baseBefore = token1.balanceOf(trader1);
        vm.prank(trader1);
        uint256 g0 = gasleft();
        // Match cap = n exactly: the engine rejects >20 (TooManyMatches), and amountIn
        // undershoots total depth so the Nth fill is partial -- n matches always suffice.
        matchingEngine.limitBuy(
            address(token1), address(token2), topPrice, amountIn, false, uint32(n), trader1
        );
        uint256 used = g0 - gasleft();
        require(token1.balanceOf(trader1) > baseBefore, "no fill");
        console2.log(n, used);
    }

    function testGasTaker1() public { _measure(1); }
    function testGasTaker2() public { _measure(2); }
    function testGasTaker3() public { _measure(3); }
    function testGasTaker5() public { _measure(5); }
    function testGasTaker10() public { _measure(10); }
    function testGasTaker20() public { _measure(20); }
}
