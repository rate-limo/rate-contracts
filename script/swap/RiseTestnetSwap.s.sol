// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MatchingEngine} from "../../src/exchange/MatchingEngine.sol";
import {PoolFactory} from "../../src/swap/PoolFactory.sol";
import {PositionManager} from "../../src/swap/PositionManager.sol";
import {SwapRouter} from "../../src/swap/SwapRouter.sol";

/// Deploys the swap system and performs the wiring the exchange scripts never did.
///
/// The existing per-chain scripts under script/exchange stop at MatchingEngine +
/// OrderbookFactory. Nothing anywhere deploys PoolFactory / PositionManager / SwapRouter,
/// and nothing calls the three admin setters that bind them together. Two of those setters
/// are not optional:
///
///   * MatchingEngine.setPoolFactory  -- without it addPair creates no pool for the pair.
///   * MatchingEngine.setSwapRouter   -- Pool.swap is onlyRouter and reads this address off
///                                       the engine. While it is address(0), EVERY swap
///                                       reverts NotRouter. A deployment that skips this
///                                       looks healthy and cannot trade.
///
/// Ordering is not free-form. PoolFactory.initialize deploys the Pool implementation that
/// every pair's pool is cloned from, so it must run before any pair is listed; and
/// PositionManager must know the factory and router before it can mint against a pool.
/// This mirrors the order test/swap/PoolBaseSetup.sol and Router.t.sol establish.
contract DeploySwapSystem is Script {
    // Set to the MatchingEngine already deployed on the target chain.
    address constant MATCHING_ENGINE = address(0);

    string constant POSITION_URI = "ipfs://iter-position/{id}.json";

    function run() external {
        require(MATCHING_ENGINE != address(0), "set MATCHING_ENGINE to the deployed engine first");

        uint256 deployerKey = vm.envUint("RISE_TESTNET_DEPLOYER_KEY");
        vm.startBroadcast(deployerKey);

        MatchingEngine engine = MatchingEngine(payable(MATCHING_ENGINE));

        // 1. Factory first -- initialize() deploys the Pool implementation clones point at.
        PoolFactory poolFactory = new PoolFactory();
        poolFactory.initialize(address(engine));

        // 2. Router binds to the factory at construction and never changes.
        SwapRouter router = new SwapRouter(address(poolFactory));

        // 3. Position manager, then the mutual introductions.
        PositionManager positionManager = new PositionManager();
        positionManager.initialize(POSITION_URI);
        positionManager.setPoolFactory(address(poolFactory));
        positionManager.setRouter(address(router));
        poolFactory.setPositionManager(address(positionManager));

        // 4. The engine-side wiring. Both are required; the second is what makes swaps
        //    executable at all.
        engine.setPoolFactory(address(poolFactory));
        engine.setSwapRouter(address(router));

        vm.stopBroadcast();

        console.log("POOL_FACTORY_ADDRESS=%s", address(poolFactory));
        console.log("POSITION_MANAGER_ADDRESS=%s", address(positionManager));
        console.log("SWAP_ROUTER_ADDRESS=%s", address(router));
        console.log("POOL_IMPL=%s", poolFactory.impl());
    }
}

/// Read-only preflight. Confirms an already-deployed system is wired correctly before any
/// liquidity or user funds arrive -- in particular that swapRouter is set, which is the one
/// failure that is invisible until someone tries to trade.
contract VerifySwapWiring is Script {
    address constant MATCHING_ENGINE = address(0);
    address constant POOL_FACTORY = address(0);
    address constant POSITION_MANAGER = address(0);
    address constant SWAP_ROUTER = address(0);

    function run() external view {
        MatchingEngine engine = MatchingEngine(payable(MATCHING_ENGINE));
        PoolFactory factory = PoolFactory(POOL_FACTORY);
        PositionManager pm = PositionManager(POSITION_MANAGER);

        address wiredFactory = engine.poolFactory();
        address wiredRouter = engine.swapRouter();

        console.log("engine.poolFactory      = %s", wiredFactory);
        console.log("engine.swapRouter       = %s", wiredRouter);
        console.log("factory.impl            = %s", factory.impl());
        console.log("factory.positionManager = %s", factory.positionManager());
        console.log("pm.poolFactory          = %s", address(pm.poolFactory()));
        console.log("pm.router               = %s", pm.router());

        require(wiredFactory == POOL_FACTORY, "engine.poolFactory not wired");
        require(wiredRouter == SWAP_ROUTER, "engine.swapRouter not wired -- ALL SWAPS WOULD REVERT");
        require(factory.impl() != address(0), "pool implementation missing");
        require(factory.positionManager() == POSITION_MANAGER, "factory.positionManager not wired");
        require(address(pm.poolFactory()) == POOL_FACTORY, "pm.poolFactory not wired");
        require(pm.router() == SWAP_ROUTER, "pm.router not wired");

        console.log("");
        console.log("all six links wired correctly");
    }
}
