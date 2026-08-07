// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PerpPoolUnitSetup} from "../PerpPoolUnitSetup.sol";
import {PerpPool} from "../../../src/futures/pools/PerpPool.sol";
import {IPerpPool} from "../../../src/futures/interfaces/IPerpPool.sol";
import {MockToken} from "../../../src/mock/MockToken.sol";
import {MockMatchingEngine, MockOrderbook} from "../mocks/MockMatchingEngine.sol";

contract PerpPoolClosePositionTest is PerpPoolUnitSetup {
    PerpPool pool;
    address mockEngineAddr;

    address seeder = address(0x5EED);

    function setUp() public {
        address poolAddr = setUpPool(10, 8000, 1000e18);
        pool = PerpPool(poolAddr);

        // Install real mock bytecode at the fixed `matchingEngine` address PerpPoolUnitSetup
        // already wired into the pool at construction time (same pattern as OpenPosition.t.sol).
        MockMatchingEngine deployed = new MockMatchingEngine();
        vm.etch(matchingEngine, address(deployed).code);
        mockEngineAddr = matchingEngine;

        MockOrderbook ob = new MockOrderbook(address(this));
        MockMatchingEngine(matchingEngine).setPair(address(baseToken), address(quoteToken), address(ob));
        MockMatchingEngine(matchingEngine).setPrice(address(baseToken), address(quoteToken), 100e8);

        quoteToken.mint(address(this), 100000e18); // fake spot pool liquidity

        // Pool now requires operator-seeded backing capital before any position can open -- the
        // OI cap measures pre-existing reserve, which starts at 0. Seed 10000e18 -> cap =
        // 10000e18 * 8000 / 10000 = 8000e18, comfortably covering this test's 1000e18 notional.
        quoteToken.mint(seeder, 10000e18);
        vm.prank(seeder);
        quoteToken.approve(address(pool), 10000e18);
        vm.prank(perpEngine);
        pool.seedReserve(address(quoteToken), 10000e18, seeder);

        quoteToken.mint(trader1, 1000e18);
        vm.prank(trader1);
        quoteToken.approve(address(pool), 1000e18);

        vm.prank(perpEngine);
        pool.openPosition(true, address(quoteToken), 100e18, 10, trader1); // notional=1000e18 @ entry 100e8
    }

    function testClosePositionInProfitPaysOutMarginPlusPnl() public {
        MockMatchingEngine(matchingEngine).setPrice(address(baseToken), address(quoteToken), 110e8); // +10%

        uint256 traderBalBefore = quoteToken.balanceOf(trader1);
        vm.prank(perpEngine);
        (int256 pnl, uint256 payout) = pool.closePosition(1, trader1);

        // contracts = 100e18*10/100e8 = 100000000000; priceDiff=10e8; pnl = priceDiff*contracts
        assertGt(pnl, 0);
        assertEq(payout, uint256(int256(100e18) + pnl));
        assertEq(quoteToken.balanceOf(trader1), traderBalBefore + payout);
    }

    function testClosePositionInLossPaysOutMarginMinusLoss() public {
        MockMatchingEngine(matchingEngine).setPrice(address(baseToken), address(quoteToken), 95e8); // -5%

        vm.prank(perpEngine);
        (int256 pnl, uint256 payout) = pool.closePosition(1, trader1);

        assertLt(pnl, 0);
        assertEq(payout, uint256(int256(100e18) + pnl));
    }

    function testClosePositionRevertsForNonOwner() public {
        vm.prank(perpEngine);
        vm.expectRevert();
        pool.closePosition(1, trader2);
    }

    function testClosePositionRemovesPositionFromLedger() public {
        vm.prank(perpEngine);
        pool.closePosition(1, trader1);

        IPerpPool.Position memory p = pool.getPosition(1);
        assertEq(p.owner, address(0));
    }

    function testClosePositionReducesOpenInterest() public {
        assertEq(pool.longOpenInterest(), 1000e18);
        vm.prank(perpEngine);
        pool.closePosition(1, trader1);
        assertEq(pool.longOpenInterest(), 0);
    }
}
