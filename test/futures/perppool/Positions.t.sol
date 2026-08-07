// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PerpEngineBaseSetup} from "../PerpEngineBaseSetup.sol";
import {PerpPool} from "../../../src/futures/pools/PerpPool.sol";
import {IPerpPool} from "../../../src/futures/interfaces/IPerpPool.sol";

contract PositionsTest is PerpEngineBaseSetup {
    address pool;

    function positionsSetUp() internal {
        perpEngineSetUp();
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(stablecoin);
        pool = perpEngine.addPool(address(token1), address(stablecoin), collaterals, 10, 8000, 0);

        // Deviation A: seed the pool's reserve before any trader can open -- PerpPool rejects
        // every open on an unseeded pool (OpenInterestCapExceeded against a zero cap). This test
        // contract deployed PerpEngine, so it holds MARKET_MAKER_ROLE and can route seed capital
        // through the engine's seedPool passthrough (mirrors EndToEnd.t.sol's working pattern).
        stablecoin.mint(address(this), 10000e18);
        stablecoin.approve(pool, 10000e18);
        perpEngine.seedPool(pool, address(stablecoin), 10000e18);

        vm.prank(trader1);
        stablecoin.approve(pool, 100000e18);
        vm.prank(trader2);
        stablecoin.approve(pool, 100000e18);
    }

    function testLong() public {
        positionsSetUp();
        vm.prank(trader1);
        uint256 id = perpEngine.long(pool, address(stablecoin), 100e18, 5);
        IPerpPool.Position memory p = PerpPool(pool).getPosition(id);
        assertTrue(p.isLong);
        assertEq(p.owner, trader1);
    }

    function testShort() public {
        positionsSetUp();
        vm.prank(trader2);
        uint256 id = perpEngine.short(pool, address(stablecoin), 100e18, 5);
        IPerpPool.Position memory p = PerpPool(pool).getPosition(id);
        assertFalse(p.isLong);
        assertEq(p.owner, trader2);
    }

    function testCloseLongPosition() public {
        positionsSetUp();
        vm.prank(trader1);
        uint256 id = perpEngine.long(pool, address(stablecoin), 100e18, 5);

        vm.prank(trader1);
        (, uint256 payout) = perpEngine.closePosition(pool, id);
        assertEq(payout, 100e18); // price unchanged since listing, no pnl

        IPerpPool.Position memory p = PerpPool(pool).getPosition(id);
        assertEq(p.owner, address(0));
    }

    function testCloseShortPosition() public {
        positionsSetUp();
        vm.prank(trader2);
        uint256 id = perpEngine.short(pool, address(stablecoin), 100e18, 5);

        vm.prank(trader2);
        (, uint256 payout) = perpEngine.closePosition(pool, id);
        assertEq(payout, 100e18);
    }

    function testMultipleIndependentPositionsGetSequentialIds() public {
        positionsSetUp();
        vm.prank(trader1);
        uint256 id1 = perpEngine.long(pool, address(stablecoin), 100e18, 5);
        vm.prank(trader2);
        uint256 id2 = perpEngine.short(pool, address(stablecoin), 100e18, 3);

        assertEq(id1, 1);
        assertEq(id2, 2);

        IPerpPool.Position memory p1 = PerpPool(pool).getPosition(id1);
        IPerpPool.Position memory p2 = PerpPool(pool).getPosition(id2);
        assertEq(p1.leverage, 5);
        assertEq(p2.leverage, 3);
    }
}
