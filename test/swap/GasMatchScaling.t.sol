// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8;

import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {console2} from "forge-std/console2.sol";

// Measurement harness (untracked): production Pool.swap gas as a function of matched
// positions, now that swap settles directly. Same shape as every earlier measurement in
// this series: N positions at N distinct tolerances so the swap crosses N tiers; amountIn
// slightly undershoots total depth so the Nth tier partially fills.
contract GasMatchScalingTest is PoolBaseSetup {
    function setUp() public override {
        super.setUp();
        vm.prank(lp1);
        token1.approve(address(pool), 10000000e18);
    }

    function _measure(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            vm.prank(positionManager);
            pool.addLiquidity(50e8, 150e8, uint32(1000000 + i * 400000), 2e18, 0, lp1);
        }
        uint256 amountIn = 190e18 * n;
        vm.prank(trader1);
        token2.approve(address(pool), amountIn);
        vm.prank(trader1);
        uint256 g0 = gasleft();
        (uint256 amountOut,,) = pool.swap(amountIn, true, trader1, false);
        uint256 used = g0 - gasleft();
        require(amountOut > 0, "no out");
        console2.log(n, used);
    }

    function testGasMatch1() public { _measure(1); }
    function testGasMatch2() public { _measure(2); }
    function testGasMatch3() public { _measure(3); }
    function testGasMatch5() public { _measure(5); }
    function testGasMatch10() public { _measure(10); }
    function testGasMatch20() public { _measure(20); }
}
