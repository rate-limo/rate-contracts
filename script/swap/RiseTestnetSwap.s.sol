// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MatchingEngine} from "../../src/exchange/MatchingEngine.sol";
import {BandPoolFactory} from "../../src/swap/BandPoolFactory.sol";
import {BandPositionManager} from "../../src/swap/BandPositionManager.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {PositionDescriptor} from "../../src/swap/PositionDescriptor.sol";
import {BandSwapRouter} from "../../src/swap/BandSwapRouter.sol";

/// Deploys the swap system and performs the wiring the exchange scripts never did.
///
/// The existing per-chain scripts under script/exchange stop at MatchingEngine +
/// OrderbookFactory. Nothing anywhere deploys BandPoolFactory / BandPositionManager / BandSwapRouter,
/// and nothing calls the three admin setters that bind them together. Two of those setters
/// are not optional:
///
///   * MatchingEngine.setPoolFactory  -- without it addPair creates no pool for the pair.
///   * MatchingEngine.setSwapRouter   -- Pool.swap is onlyRouter and reads this address off
///                                       the engine. While it is address(0), EVERY swap
///                                       reverts NotRouter. A deployment that skips this
///                                       looks healthy and cannot trade.
///
/// Ordering is not free-form. The factory must be initialized with the BandPool implementation
/// every pair's pool is cloned from before any pair is listed; and
/// BandPositionManager must know the factory and router before it can mint against a pool.
/// This mirrors the order test/swap/PoolBaseSetup.sol and Router.t.sol establish.
contract DeploySwapSystem is Script {
    // Set to the MatchingEngine already deployed on the target chain.
    /// Read from the environment rather than edited into the source before each
    /// run. A constant meant the file had to be modified to deploy, which is a
    /// diff nobody wants to commit and an edit easy to forget — and forgetting it
    /// failed with a require, after compilation, rather than at the call site.
    function matchingEngineAddress() internal view returns (address) {
        return vm.envAddress("MATCHING_ENGINE");
    }

    string constant POSITION_URI = "ipfs://iter-position/{id}.json";

    function run() external {

        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        vm.startBroadcast(deployerKey);

        MatchingEngine engine = MatchingEngine(payable(matchingEngineAddress()));

        // 1. Manager and router first: the factory takes the manager at initialize, so a
        //    band pool is never created without one.
        BandPositionManager positionManager = new BandPositionManager();
        positionManager.initialize(POSITION_URI);
        BandSwapRouter router = new BandSwapRouter();

        // 2. The BandPool implementation clones point at, then the factory, which names the
        //    default maturity and band fractions a new pair is born with.
        BandPool poolImpl = new BandPool();
        BandPoolFactory poolFactory = new BandPoolFactory();
        poolFactory.initialize(address(engine), address(positionManager), address(poolImpl), vm.addr(deployerKey));
        positionManager.setPoolFactory(address(poolFactory));

        // 4. The engine-side wiring. Both are required; the second is what makes swaps
        //    executable at all.
        engine.setPoolFactory(address(poolFactory));
        engine.setSwapRouter(address(router));

        // 5. The on-chain metadata renderer. Stateless and swappable by design, so it is
        //    deployed last and can be replaced later without touching the token that
        //    holds people's positions. Left unset the manager serves POSITION_URI, which
        //    points at nothing.
        PositionDescriptor descriptor = new PositionDescriptor();
        positionManager.setDescriptor(address(descriptor));

        vm.stopBroadcast();

        console.log("POOL_FACTORY_ADDRESS=%s", address(poolFactory));
        console.log("POSITION_MANAGER_ADDRESS=%s", address(positionManager));
        console.log("SWAP_ROUTER_ADDRESS=%s", address(router));
        console.log("POSITION_DESCRIPTOR_ADDRESS=%s", address(descriptor));
        console.log("POOL_IMPL=%s", poolFactory.impl());
    }
}

/// Read-only preflight. Confirms an already-deployed system is wired correctly before any
/// liquidity or user funds arrive -- in particular that swapRouter is set, which is the one
/// failure that is invisible until someone tries to trade.
contract VerifySwapWiring is Script {
    /// Read from the environment rather than edited into the source before each
    /// run. A constant meant the file had to be modified to deploy, which is a
    /// diff nobody wants to commit and an edit easy to forget — and forgetting it
    /// failed with a require, after compilation, rather than at the call site.
    function matchingEngineAddress() internal view returns (address) {
        return vm.envAddress("MATCHING_ENGINE");
    }
    address constant POOL_FACTORY = address(0);
    address constant POSITION_MANAGER = address(0);
    address constant SWAP_ROUTER = address(0);

    function run() external view {
        MatchingEngine engine = MatchingEngine(payable(matchingEngineAddress()));
        BandPoolFactory factory = BandPoolFactory(POOL_FACTORY);
        BandPositionManager pm = BandPositionManager(POSITION_MANAGER);

        address wiredFactory = engine.poolFactory();
        address wiredRouter = engine.swapRouter();

        console.log("engine.poolFactory      = %s", wiredFactory);
        console.log("engine.swapRouter       = %s", wiredRouter);
        console.log("factory.impl            = %s", factory.impl());
        console.log("factory.positionManager = %s", factory.positionManager());
        console.log("pm.poolFactory          = %s", address(pm.poolFactory()));
        console.log("pm.descriptor           = %s", pm.descriptor());

        require(wiredFactory == POOL_FACTORY, "engine.poolFactory not wired");
        require(wiredRouter == SWAP_ROUTER, "engine.swapRouter not wired -- ALL SWAPS WOULD REVERT");
        require(factory.impl() != address(0), "pool implementation missing");
        require(factory.positionManager() == POSITION_MANAGER, "factory.positionManager not wired");
        // No pm.router check: the manager reads the engine's router, which is the same
        // slot the pool's onlyRouter gate reads, and is asserted above.
        require(address(pm.poolFactory()) == POOL_FACTORY, "pm.poolFactory not wired");

        // Deliberately logged, not required: with no descriptor the token still works
        // and serves POSITION_URI. It is a cosmetic gap, not a broken deployment, and a
        // hard require here would block a preflight over artwork.
        if (pm.descriptor() == address(0)) {
            console.log("WARNING: pm.descriptor unset -- tokens render the static base URI");
        }

        console.log("");
        console.log("all five links wired correctly");
    }
}
