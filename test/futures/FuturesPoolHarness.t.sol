// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FuturesPool} from "../../src/futures/libraries/FuturesPool.sol";

contract FuturesPoolHarness {
    function contractsOf(uint256 margin, uint256 entryPrice, uint32 leverage) external pure returns (uint256) {
        return FuturesPool._contracts(margin, entryPrice, leverage);
    }

    function pnlOf(uint256 margin, uint256 entryPrice, uint32 leverage, uint256 mktPrice, bool isLong)
        external
        pure
        returns (int256)
    {
        return FuturesPool._pnl(margin, entryPrice, leverage, mktPrice, isLong);
    }

    function maintenanceMarginBpsOf(uint32 poolMaxLeverage) external pure returns (uint256) {
        return FuturesPool._maintenanceMarginBps(poolMaxLeverage);
    }

    function isLiquidatableOf(
        uint256 margin,
        uint256 entryPrice,
        uint32 leverage,
        uint256 mktPrice,
        bool isLong,
        uint32 poolMaxLeverage
    ) external pure returns (bool) {
        return FuturesPool._isLiquidatable(margin, entryPrice, leverage, mktPrice, isLong, poolMaxLeverage);
    }

    function liquidationSplitOf(uint256 margin, uint32 liqFeeBps) external pure returns (uint256, uint256) {
        return FuturesPool._liquidationSplit(margin, liqFeeBps);
    }
}

contract FuturesPoolTest is Test {
    FuturesPoolHarness harness;

    function setUp() public {
        harness = new FuturesPoolHarness();
    }

    function testContractsIsNotionalDividedByEntryPrice() public {
        // margin=1000, leverage=10 -> notional=10000; entryPrice=50 -> 200 contracts
        assertEq(harness.contractsOf(1000, 50, 10), 200);
    }

    function testPnlPositiveWhenLongAndPriceRises() public {
        // margin=1000, entryPrice=100, leverage=10 -> 100 contracts; price 100 -> 110 = +10/contract -> +1000
        int256 pnl = harness.pnlOf(1000, 100, 10, 110, true);
        assertEq(pnl, 1000);
    }

    function testPnlNegativeWhenLongAndPriceFalls() public {
        int256 pnl = harness.pnlOf(1000, 100, 10, 90, true);
        assertEq(pnl, -1000);
    }

    function testPnlPositiveWhenShortAndPriceFalls() public {
        int256 pnl = harness.pnlOf(1000, 100, 10, 90, false);
        assertEq(pnl, 1000);
    }

    // The actual bug fix: maintenance margin must derive from the POOL's configured max
    // leverage, not from any individual position's chosen leverage. Hyperliquid's own worked
    // example: max leverage 20x -> maintenance margin is always 2.5% (250 bps of 10000),
    // regardless of what leverage a specific trader picked.
    function testMaintenanceMarginDerivesFromPoolMaxLeverageNotPositionLeverage() public {
        assertEq(harness.maintenanceMarginBpsOf(20), 250);
        // a position that chose 2x leverage on a pool whose max is 20x still gets the pool's
        // fixed 2.5% maintenance margin, not 5000/2=2500 (25%) computed from its own leverage
        assertEq(harness.maintenanceMarginBpsOf(20), 250);
    }

    function testIsLiquidatableTrueWhenAccountValueBelowRequiredMargin() public {
        // margin=100, entryPrice=100, leverage=10 -> 10 contracts, notional=1000 at entry
        // price crashes to 80 (long): pnl = (80-100)*10 = -200, accountValue = 100-200 = -100
        // openNotional at mkt = 10*80 = 800; maintenanceMarginBps(poolMaxLeverage=10) = 500 (5%)
        // requiredMargin = 800*500/10000 = 40. accountValue(-100) < requiredMargin(40) -> true
        bool liquidatable = harness.isLiquidatableOf(100, 100, 10, 80, true, 10);
        assertTrue(liquidatable);
    }

    function testIsLiquidatableFalseWhenAccountValueHealthy() public {
        // small price move, position stays well collateralized
        bool liquidatable = harness.isLiquidatableOf(100, 100, 10, 99, true, 10);
        assertFalse(liquidatable);
    }

    function testLiquidationSplitRoutesFeeAndRemainderCorrectly() public {
        (uint256 feeFund, uint256 poolFund) = harness.liquidationSplitOf(1000, 500); // 5% fee
        assertEq(feeFund, 50);
        assertEq(poolFund, 950);
    }

    function testLiquidationSplitWithZeroFeeRoutesEverythingToPool() public {
        // Hyperliquid's default: no explicit clearance fee, the whole remaining margin is the
        // pool's compensation for taking the position over
        (uint256 feeFund, uint256 poolFund) = harness.liquidationSplitOf(1000, 0);
        assertEq(feeFund, 0);
        assertEq(poolFund, 1000);
    }
}
