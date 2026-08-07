// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PerpPoolUnitSetup} from "../PerpPoolUnitSetup.sol";
import {PerpPool} from "../../../src/futures/pools/PerpPool.sol";
import {IPerpPool} from "../../../src/futures/interfaces/IPerpPool.sol";
import {MockToken} from "../../../src/mock/MockToken.sol";
import {MockMatchingEngine, MockOrderbook} from "../mocks/MockMatchingEngine.sol";

contract PerpPoolOpenPositionTest is PerpPoolUnitSetup {
    PerpPool pool;
    MockMatchingEngine mockEngine;

    address seeder = address(0x5EED);

    function setUp() public {
        // Realistic production-flavored default: 8000 bps (80%) utilization, matching Init.t.sol
        // and the plan's actual default. The pool must be seeded with operator-provided backing
        // capital before any trader can open a position -- see seedReserve on PerpPool.
        address poolAddr = setUpPool(10, 8000, 1000e18);
        pool = PerpPool(poolAddr);

        // Redeploy setUpPool's matchingEngine as a real mock at the address PerpPool already
        // points to is not possible post-deploy, so this task's tests use vm.etch to install
        // real mock bytecode at the fixed `matchingEngine` address PerpPoolUnitSetup already
        // wired into the pool at construction time.
        MockMatchingEngine deployed = new MockMatchingEngine();
        vm.etch(matchingEngine, address(deployed).code);

        // fake spot pool holding quote liquidity, registered behind a fake orderbook
        MockOrderbook ob = new MockOrderbook(address(this));
        MockMatchingEngine(matchingEngine).setPair(address(baseToken), address(quoteToken), address(ob));

        MockMatchingEngine(matchingEngine).setPrice(address(baseToken), address(quoteToken), 100e8); // $100
        quoteToken.mint(address(this), 5000e18); // this test contract IS the fake spot pool

        // Seed the pool with operator backing capital before any trader acts. 10000e18 seed ->
        // cap = 10000e18 * 8000 / 10000 = 8000e18, comfortably covering the happy-path tests'
        // notional (e.g. trader1's 100e18 * 5 = 500e18).
        quoteToken.mint(seeder, 10000e18);
        vm.prank(seeder);
        quoteToken.approve(address(pool), 10000e18);
        vm.prank(perpEngine);
        pool.seedReserve(address(quoteToken), 10000e18, seeder);

        quoteToken.mint(trader1, 20000e18);
        vm.prank(trader1);
        quoteToken.approve(address(pool), 20000e18);
    }

    function testOpenPositionTransfersRealCollateral() public {
        uint256 poolBalBefore = quoteToken.balanceOf(address(pool));
        uint256 traderBalBefore = quoteToken.balanceOf(trader1);
        uint256 reserveBefore = pool.reserveOf(address(quoteToken));

        vm.prank(perpEngine);
        pool.openPosition(true, address(quoteToken), 100e18, 5, trader1);

        assertEq(quoteToken.balanceOf(address(pool)), poolBalBefore + 100e18);
        assertEq(quoteToken.balanceOf(trader1), traderBalBefore - 100e18);
        assertEq(pool.reserveOf(address(quoteToken)), reserveBefore + 100e18);
    }

    function testOpenPositionSizesNotionalFromMarginTimesLeverage() public {
        vm.prank(perpEngine);
        uint256 id = pool.openPosition(true, address(quoteToken), 100e18, 5, trader1);

        IPerpPool.Position memory p = pool.getPosition(id);
        assertEq(p.margin, 100e18);
        assertEq(p.leverage, 5);
        assertEq(p.entryPrice, 100e8);
        assertEq(p.owner, trader1);
        assertTrue(p.isLong);
        assertEq(pool.longOpenInterest(), 100e18 * 5);
    }

    function testOpenPositionRevertsForUnacceptedCollateral() public {
        MockToken rogue = new MockToken("Rogue", "RGE", 18);
        rogue.mint(trader1, 100e18);
        vm.prank(trader1);
        rogue.approve(address(pool), 100e18);

        vm.prank(perpEngine);
        vm.expectRevert();
        pool.openPosition(true, address(rogue), 100e18, 5, trader1);
    }

    function testOpenPositionRevertsAboveMaxLeverage() public {
        vm.prank(perpEngine);
        vm.expectRevert();
        pool.openPosition(true, address(quoteToken), 100e18, 11, trader1); // pool max is 10
    }

    function testOpenPositionRevertsWhenNotCalledByPerpEngine() public {
        vm.expectRevert();
        pool.openPosition(true, address(quoteToken), 100e18, 5, trader1);
    }

    function testOpenPositionRevertsWhenSpotLiquidityBelowMinimum() public {
        // drain the fake spot pool below the 1000e18 minSpotLiquidity threshold
        quoteToken.transfer(address(0xdead), quoteToken.balanceOf(address(this)));

        vm.prank(perpEngine);
        vm.expectRevert();
        pool.openPosition(true, address(quoteToken), 100e18, 5, trader1);
    }

    function testOpenPositionRevertsWhenOpenInterestCapExceeded() public {
        // Pool was seeded with 10000e18 in setUp -> cap = 10000e18 * 8000 / 10000 = 8000e18.
        // Attempt a position whose notional alone breaches that cap: 1000e18 margin * 10x
        // leverage = 10000e18 notional > 8000e18 cap.
        vm.prank(perpEngine);
        vm.expectRevert(abi.encodeWithSelector(PerpPool.OpenInterestCapExceeded.selector, 10000e18, 8000e18));
        pool.openPosition(true, address(quoteToken), 1000e18, 10, trader1);
    }

    function testFirstPositionOpensOnSeededPoolAtDefaultUtilization() public {
        // The exact regression scenario the review demanded: a plain first open at the
        // realistic 8000 bps default utilization on a seeded pool must succeed -- this was
        // mathematically impossible before the seedReserve + pre-deposit cap check fix.
        vm.prank(perpEngine);
        uint256 id = pool.openPosition(true, address(quoteToken), 100e18, 5, trader1);

        IPerpPool.Position memory p = pool.getPosition(id);
        assertEq(p.margin, 100e18);
        assertEq(pool.longOpenInterest(), 500e18);
    }

    function testOpenPositionRevertsOnUnseededPool() public {
        // A second pool from the same factory, deliberately left unseeded, must refuse any
        // leveraged open -- an unfunded pool correctly declines to take on risk. This documents
        // intended behavior, not a bug. PerpPoolFactory keys pools by (base, quote), so a fresh
        // base/quote pair is needed to avoid PoolAlreadyExists against the seeded pool from
        // setUp().
        MockToken base2 = new MockToken("Base2", "BASE2", 18);
        MockToken quote2 = new MockToken("Quote2", "QUOTE2", 18);
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(quote2);

        vm.prank(perpEngine);
        address unseededPoolAddr =
            factory.createPerpPool(address(base2), address(quote2), collaterals, 10, 8000, 1000e18);
        PerpPool unseededPool = PerpPool(unseededPoolAddr);

        // Wire up the same matchingEngine mock (shared across pools from this factory) with a
        // price and spot-liquidity pair for the new base2/quote2 market so the cap check --
        // not an earlier price/liquidity gate -- is what this test actually exercises.
        MockMatchingEngine(matchingEngine).setPrice(address(base2), address(quote2), 100e8);
        MockOrderbook ob2 = new MockOrderbook(address(this));
        MockMatchingEngine(matchingEngine).setPair(address(base2), address(quote2), address(ob2));
        quote2.mint(address(this), 5000e18); // this test contract is the fake spot pool for ob2 too

        quote2.mint(trader1, 100e18);
        vm.prank(trader1);
        quote2.approve(address(unseededPool), 100e18);

        vm.prank(perpEngine);
        vm.expectRevert(abi.encodeWithSelector(PerpPool.OpenInterestCapExceeded.selector, 500e18, 0));
        unseededPool.openPosition(true, address(quote2), 100e18, 5, trader1);
    }

    function testSeedReserveOnlyCallableByPerpEngine() public {
        quoteToken.mint(address(this), 100e18);
        quoteToken.approve(address(pool), 100e18);

        vm.expectRevert();
        pool.seedReserve(address(quoteToken), 100e18, address(this));
    }
}
