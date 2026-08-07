// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {IPool} from "../../src/swap/interfaces/IPool.sol";

contract AddLiquidityTest is PoolBaseSetup {
    function testAddLiquidityAgainstRealListedPair() public {
        super.setUp();

        vm.prank(lp1);
        token1.approve(address(pool), 1000e18);
        vm.prank(lp1);
        token2.approve(address(pool), 1000e18);

        vm.prank(positionManager);
        uint256 positionId = pool.addLiquidity(80e8, 120e8, 1000000, 500e18, 500e18, lp1);

        IPool.Position memory p = pool.getPosition(positionId);
        assertEq(p.baseAmount, 500e18);
        assertEq(p.quoteAmount, 500e18);
        assertTrue(p.active);
    }

    function testMultiplePositionsGetSequentialIds() public {
        super.setUp();

        vm.startPrank(lp1);
        token1.approve(address(pool), 1000e18);
        token2.approve(address(pool), 1000e18);
        vm.stopPrank();

        vm.startPrank(positionManager);
        uint256 id1 = pool.addLiquidity(80e8, 120e8, 1000000, 100e18, 100e18, lp1);
        uint256 id2 = pool.addLiquidity(90e8, 110e8, 500000, 100e18, 100e18, lp1);
        vm.stopPrank();

        assertEq(id1, 1);
        assertEq(id2, 2);
    }
}
