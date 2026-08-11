// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MatchingEngine} from "../../src/exchange/MatchingEngine.sol";
import {StopOrderEngine} from "../../src/exchange/StopOrderEngine.sol";
import {OrderbookFactory} from "../../src/exchange/orderbooks/OrderbookFactory.sol";
import {PoolFactory} from "../../src/swap/PoolFactory.sol";
import {PositionManager} from "../../src/swap/PositionManager.sol";
import {SwapRouter} from "../../src/swap/SwapRouter.sol";
import {Pool} from "../../src/swap/Pool.sol";
import {IPool} from "../../src/swap/interfaces/IPool.sol";
import {ISwapRouter} from "../../src/swap/interfaces/ISwapRouter.sol";
import {WETH9} from "../../src/mock/WETH9.sol";
import {MockToken} from "../../src/mock/MockToken.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";

/// Executes the exact sequence script/swap/RiseTestnetSwap.s.sol broadcasts, from nothing,
/// and then trades through the result. A deploy script that compiles but mis-wires produces
/// a chain that looks healthy and cannot trade, so compiling it is not verification --
/// running it and completing a swap is.
///
/// The negative case matters more than the positive one: Pool.swap is onlyRouter and reads
/// the router off the engine, so a deployment that skips setSwapRouter deploys cleanly,
/// lists pairs, accepts liquidity, and reverts every single swap. That failure is invisible
/// until a user tries to trade, which is why it is pinned here.
contract DeploymentWiringTest is Test {
    MatchingEngine engine;
    StopOrderEngine stopOrderEngine;
    OrderbookFactory orderbookFactory;
    PoolFactory poolFactory;
    PositionManager positionManager;
    SwapRouter router;
    WETH9 weth;
    MockToken base;
    MockToken quote;

    address admin = address(this);
    address lp = address(0xA11CE);
    address trader = address(0xB0B);

    uint256 constant LISTING = 100e8;

    /// Everything up to, but not including, the swap-system deploy -- i.e. the state the
    /// existing script/exchange/RiseTestnet.s.sol leaves behind.
    function _deployExchange() internal {
        weth = new WETH9();
        engine = new MatchingEngine();
        orderbookFactory = new OrderbookFactory();
        orderbookFactory.initialize(address(engine));
        engine.initialize(address(orderbookFactory), admin, address(weth));

        engine.setDefaultSpread(100000, 100000, true); // production market default, 0.1%
        engine.setDefaultSpread(3000000, 3000000, false); // production limit default, 3%
        engine.setDefaultFee(true, 0);
        engine.setDefaultFee(false, 100000);

        stopOrderEngine = new StopOrderEngine(address(engine));
        engine.setStopOrderEngine(address(stopOrderEngine));

        base = new MockToken("Base", "BASE", 18);
        quote = new MockToken("Quote", "QUOTE", 18);
        base.mint(lp, 1000000e18);
        quote.mint(lp, 1000000e18);
        base.mint(trader, 1000000e18);
        quote.mint(trader, 1000000e18);
    }

    /// The sequence DeploySwapSystem.run() broadcasts, in order.
    function _deploySwapSystem(bool wireRouter) internal {
        poolFactory = new PoolFactory();
        poolFactory.initialize(address(engine));

        router = new SwapRouter(address(poolFactory));

        positionManager = new PositionManager();
        positionManager.initialize("ipfs://iter-positions/{id}.json");
        positionManager.setPoolFactory(address(poolFactory));
        positionManager.setRouter(address(router));
        poolFactory.setPositionManager(address(positionManager));

        engine.setPoolFactory(address(poolFactory));
        if (wireRouter) {
            engine.setSwapRouter(address(router));
        }
    }

    function _listPairAndSeed() internal returns (Pool pool) {
        engine.addPair(
            address(base), address(quote), LISTING, 0, address(base), ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        vm.warp(block.timestamp + 600); // the oracle window must elapse before any swap

        pool = Pool(poolFactory.getPool(address(base), address(quote)));

        vm.startPrank(lp);
        base.approve(address(pool), type(uint256).max);
        quote.approve(address(pool), type(uint256).max);
        base.approve(address(positionManager), type(uint256).max);
        quote.approve(address(positionManager), type(uint256).max);
        positionManager.addLiquidity(address(pool), 50e8, 150e8, 5000000, 1000e18, 1000e18);
        vm.stopPrank();
    }

    function _path() internal view returns (address[] memory p) {
        p = new address[](2);
        p[0] = address(quote);
        p[1] = address(base);
    }

    // ------------------------------------------------------------------ the happy path

    function testDeployedSystemIsFullyWired() public {
        _deployExchange();
        _deploySwapSystem(true);

        assertEq(engine.poolFactory(), address(poolFactory), "engine.poolFactory");
        assertEq(engine.swapRouter(), address(router), "engine.swapRouter");
        assertEq(engine.getStopOrderEngine(), address(stopOrderEngine), "engine.stopOrderEngine");
        assertEq(stopOrderEngine.matchingEngine(), address(engine), "stopOrderEngine.matchingEngine");
        assertTrue(poolFactory.impl() != address(0), "pool implementation deployed by initialize()");
        assertEq(poolFactory.positionManager(), address(positionManager), "factory.positionManager");
        assertEq(positionManager.poolFactory(), address(poolFactory), "pm.poolFactory");
        assertEq(positionManager.router(), address(router), "pm.router");
    }

    /// Listing a pair after the wiring gives it a pool, which is the whole reason
    /// setPoolFactory has to happen before any pair is created.
    function testListingAPairCreatesItsPool() public {
        _deployExchange();
        _deploySwapSystem(true);
        Pool pool = _listPairAndSeed();

        assertTrue(address(pool) != address(0), "addPair created a pool");
        assertTrue(poolFactory.isClone(address(pool)), "and it is a clone of the implementation");
        assertEq(pool.activePositionsLength(), 1, "seeded with the LP's position");
    }

    /// The end-to-end proof: a real swap through the deployed system.
    function testAUserCanActuallySwap() public {
        _deployExchange();
        _deploySwapSystem(true);
        _listPairAndSeed();

        ISwapRouter.RemainderConfig memory cfg;
        uint256 baseBefore = base.balanceOf(trader);

        vm.startPrank(trader);
        quote.approve(address(router), 100e18);
        uint256 out = router.swap(_path(), 100e18, 0, trader, ISwapRouter.RemainderMode.Refund, cfg);
        vm.stopPrank();

        assertGt(out, 0, "the swap filled");
        assertEq(base.balanceOf(trader) - baseBefore, out, "and the trader received it");
    }

    // ------------------------------------------------------------------ the invisible failure

    /// Skip exactly one line -- engine.setSwapRouter -- and everything still deploys, the
    /// pair still lists, the pool still takes liquidity, and every swap reverts. This is the
    /// state the existing deploy scripts would have produced, since none of them calls it.
    function testSkippingSetSwapRouterBricksEverySwap() public {
        _deployExchange();
        _deploySwapSystem(false); // the only difference
        _listPairAndSeed();

        assertEq(engine.swapRouter(), address(0), "unwired, as the current scripts leave it");

        ISwapRouter.RemainderConfig memory cfg;
        vm.startPrank(trader);
        quote.approve(address(router), 100e18);
        vm.expectRevert(abi.encodeWithSelector(IPool.NotRouter.selector, address(router), address(0)));
        router.swap(_path(), 100e18, 0, trader, ISwapRouter.RemainderMode.Refund, cfg);
        vm.stopPrank();
    }

    /// And the fix is applyable after the fact, so a chain deployed without it is recoverable
    /// by an admin call rather than a redeploy.
    function testWiringTheRouterAfterwardsRepairsIt() public {
        _deployExchange();
        _deploySwapSystem(false);
        _listPairAndSeed();

        engine.setSwapRouter(address(router)); // the one missing call

        ISwapRouter.RemainderConfig memory cfg;
        vm.startPrank(trader);
        quote.approve(address(router), 100e18);
        uint256 out = router.swap(_path(), 100e18, 0, trader, ISwapRouter.RemainderMode.Refund, cfg);
        vm.stopPrank();

        assertGt(out, 0, "recovered without redeploying anything");
    }

    // ------------------------------------------------------------------ the config decision

    /// Records what the production spread defaults mean for this deployment, on the same
    /// stack the script builds. The swap fills at the LP's 5% tier but the 0.1% market
    /// spread rails the report, so lmp holds 100.10 -- a price nobody traded at.
    ///
    /// This is the chosen configuration, pinned so the behaviour is a decision on record
    /// rather than a surprise after launch.
    function testProductionSpreadMeansTheRailNotTheFillIsRecorded() public {
        _deployExchange();
        _deploySwapSystem(true);
        _listPairAndSeed();

        ISwapRouter.RemainderConfig memory cfg;
        vm.startPrank(trader);
        quote.approve(address(router), 105e18);
        uint256 out = router.swap(_path(), 105e18, 0, trader, ISwapRouter.RemainderMode.Refund, cfg);
        vm.stopPrank();

        uint256 impliedFill = (105e18 * 1e8) / out;
        assertApproxEqRel(impliedFill, 105e8, 0.002e18, "the trader paid the 5% tier bound");

        uint256 recorded = MatchingEngine(payable(address(engine))).mktPrice(address(base), address(quote));
        assertEq(recorded, 10010000000, "but the pair records 100.10 -- the 0.1% market rail");
    }
}
