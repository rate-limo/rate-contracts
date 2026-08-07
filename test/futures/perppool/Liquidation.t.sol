// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PerpPoolUnitSetup} from "../PerpPoolUnitSetup.sol";
import {PerpPool} from "../../../src/futures/pools/PerpPool.sol";
import {IPerpPool} from "../../../src/futures/interfaces/IPerpPool.sol";
import {MockMatchingEngine, MockOrderbook} from "../mocks/MockMatchingEngine.sol";

contract PerpPoolLiquidationTest is PerpPoolUnitSetup {
    PerpPool pool;
    address mockEngineAddr;

    address seeder = address(0x5EED);

    function setUp() public {
        // pool max leverage 10 -> maintenance margin fixed at 5% (feeDenom/(2*10) = 500bps)
        address poolAddr = setUpPool(10, 8000, 1000e18);
        pool = PerpPool(poolAddr);

        // Install real mock bytecode at the fixed `matchingEngine` address PerpPoolUnitSetup
        // already wired into the pool at construction time (same pattern as ClosePosition.t.sol;
        // vm.getDeployedCode cross-file artifact lookups proved brittle in Task 5).
        MockMatchingEngine deployed = new MockMatchingEngine();
        vm.etch(matchingEngine, address(deployed).code);
        mockEngineAddr = matchingEngine;

        MockOrderbook ob = new MockOrderbook(address(this));
        MockMatchingEngine(matchingEngine).setPair(address(baseToken), address(quoteToken), address(ob));
        MockMatchingEngine(matchingEngine).setPrice(address(baseToken), address(quoteToken), 100e8);

        quoteToken.mint(address(this), 100000e18); // fake spot pool liquidity

        // Pools must be seeded with backing capital before any position can open -- the OI cap
        // measures pre-existing reserve, which starts at 0. Seed 10000e18 -> cap = 10000e18 *
        // 8000 / 10000 = 8000e18, comfortably covering this test's 1000e18 notional.
        quoteToken.mint(seeder, 10000e18);
        vm.prank(seeder);
        quoteToken.approve(address(pool), 10000e18);
        vm.prank(perpEngine);
        pool.seedReserve(address(quoteToken), 10000e18, seeder);

        quoteToken.mint(trader1, 1000e18);
        vm.prank(trader1);
        quoteToken.approve(address(pool), 1000e18);

        vm.prank(perpEngine);
        pool.openPosition(true, address(quoteToken), 100e18, 10, trader1); // notional=1000e18 @ 100e8
    }

    function testLiquidateRevertsWhenPositionIsHealthy() public {
        MockMatchingEngine(matchingEngine).setPrice(address(baseToken), address(quoteToken), 100.5e8);
        vm.expectRevert();
        pool.liquidate(1);
    }

    function testLiquidateRoutesRemainingMarginToPoolReserve() public {
        // Since Task 4's fix, the trader's 100e18 margin already entered reserveOf at OPEN
        // (check-then-transfer). So "routing collateral to the pool" at liquidation time means
        // the pool RETAINS that already-deposited margin instead of paying it back out to the
        // trader -- reserveOf does not grow further, it simply doesn't shrink. That retention
        // (nothing leaves the pool, the trader gets zero back) IS the fix for the original bug
        // (collateral vanishing / being wrongly refunded).
        uint256 reserveBefore = pool.reserveOf(address(quoteToken));
        uint256 traderBalBefore = quoteToken.balanceOf(trader1);

        // crash the price hard enough to breach the fixed 5% maintenance margin
        MockMatchingEngine(matchingEngine).setPrice(address(baseToken), address(quoteToken), 80e8);

        (uint256 feeFund, uint256 poolFund) = pool.liquidate(1);

        assertEq(feeFund, 0); // default liquidation fee is 0, matches Hyperliquid's no-clearance-fee model
        assertGt(poolFund, 0);
        assertEq(pool.reserveOf(address(quoteToken)), reserveBefore); // margin retained, nothing left the pool
        assertEq(quoteToken.balanceOf(trader1), traderBalBefore); // trader gets nothing back
    }

    function testLiquidateDeletesThePosition() public {
        MockMatchingEngine(matchingEngine).setPrice(address(baseToken), address(quoteToken), 80e8);
        pool.liquidate(1);

        IPerpPool.Position memory p = pool.getPosition(1);
        assertEq(p.owner, address(0));
    }

    function testLiquidateReducesOpenInterest() public {
        MockMatchingEngine(matchingEngine).setPrice(address(baseToken), address(quoteToken), 80e8);
        assertEq(pool.longOpenInterest(), 1000e18);
        pool.liquidate(1);
        assertEq(pool.longOpenInterest(), 0);
    }

    function testLiquidateWithConfiguredFeeSplitsBetweenFeeRecipientAndPool() public {
        address feeRecipient = address(0xFEE);
        vm.prank(perpEngine);
        pool.setLiquidationFeeRecipient(feeRecipient);
        vm.prank(perpEngine);
        pool.setLiquidationFeeBps(500); // 5%

        MockMatchingEngine(matchingEngine).setPrice(address(baseToken), address(quoteToken), 80e8);

        uint256 reserveBefore = pool.reserveOf(address(quoteToken));
        uint256 recipientBalBefore = quoteToken.balanceOf(feeRecipient);

        (uint256 feeFund, uint256 poolFund) = pool.liquidate(1);

        assertGt(feeFund, 0);
        assertEq(feeFund + poolFund, 100e18); // margin fully accounted for between fee and pool
        assertEq(quoteToken.balanceOf(feeRecipient), recipientBalBefore + feeFund); // fee actually paid out
        assertEq(pool.reserveOf(address(quoteToken)), reserveBefore - feeFund); // only the fee left the reserve
    }

    function testLiquidateIsPermissionless() public {
        MockMatchingEngine(matchingEngine).setPrice(address(baseToken), address(quoteToken), 80e8);
        vm.prank(address(0xC0FFEE)); // arbitrary caller, not perpEngine
        pool.liquidate(1);
    }
}
