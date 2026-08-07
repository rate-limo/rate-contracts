// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MatchingEngine} from "../src/exchange/MatchingEngine.sol";
import {OrderbookFactory} from "../src/exchange/orderbooks/OrderbookFactory.sol";
import {PoolFactory} from "../src/swap/PoolFactory.sol";
import {PositionManager} from "../src/swap/PositionManager.sol";
import {SwapRouter} from "../src/swap/SwapRouter.sol";
import {WETH9} from "../src/mock/WETH9.sol";

/// The whole stack in one broadcast: exchange, swap system, and every wiring call between
/// them. Previously this was two scripts that did not know about each other --
/// script/exchange/RiseTestnet.s.sol stopped at MatchingEngine, and nothing deployed the
/// swap side at all -- so a full bring-up meant hand-copying addresses between runs. Doing
/// it in one transaction removes that step and, more importantly, removes the chance of
/// stopping halfway with a chain that lists pairs and cannot trade.
///
/// Ordering constraints, none of them free-form:
///   * OrderbookFactory.initialize must precede MatchingEngine.initialize -- the engine
///     reads factory.impl() and reverts FactoryNotInitialized if it is unset.
///   * PoolFactory.initialize deploys the Pool implementation every pair's pool is cloned
///     from, so it must precede any pair listing.
///   * MatchingEngine.setSwapRouter must happen at all. Pool.swap is onlyRouter and reads
///     this address off the engine; while it is address(0) every swap reverts NotRouter,
///     and nothing else about the deployment looks wrong.
///
/// The sequence here is the one test/swap/DeploymentWiring.t.sol executes end to end and
/// then trades through.
contract DeployAll is Script {
    // ---------------------------------------------------------------- configuration

    /// Canonical WETH for the target chain. Left at address(0) a fresh WETH9 is deployed,
    /// which is right for a testnet and wrong for anywhere real -- the previous script
    /// carried a hardcoded 0x008fCD... from another chain entirely, which would have
    /// silently bound the engine to a non-contract on Rise.
    address constant WETH = address(0);

    /// Receives protocol fees. address(0) uses the deployer.
    address constant FEE_TO = address(0);

    /// Maker and taker fee, DENOM-scaled (1e8). MatchingEngine.initialize does NOT set
    /// these -- feeOf falls through to defaultMakerFee/defaultTakerFee, which start at
    /// zero, so a deployment that skips this runs entirely fee-free. 100000 = 0.1%, the
    /// value every swap fixture is written against.
    uint32 constant MAKER_FEE = 100000;
    uint32 constant TAKER_FEE = 100000;

    /// Share of the maker fee rebated to the pool positions that supplied the liquidity,
    /// DENOM-scaled. Also zero by default, which sends the entire maker fee to feeTo and
    /// leaves LPs earning only the spread. 50000000 = 50%, matching test/swap/Swap.t.sol.
    uint32 constant POOL_FEE_SHARE = 50000000;

    string constant POSITION_URI = "ipfs://iter-position/{id}.json";

    /// Spreads are NOT set here: MatchingEngine.initialize already writes the production
    /// defaults (market 0.1%, limit 3%). Note what that means for this deployment -- a 0.1%
    /// market spread against a typical 5% LP slippage tier means the rail clamps every pool
    /// fill, so lmp records the rail rather than the price the swap traded at. That is the
    /// chosen configuration, pinned by
    /// test/swap/DeploymentWiring.t.sol:testProductionSpreadMeansTheRailNotTheFillIsRecorded.

    /// Signer resolution, in order of preference. The keystore and hardware paths are
    /// first because they never put a private key in an environment variable, a shell
    /// history, or a process listing:
    ///
    ///   forge script ... --account riseDeployer      (encrypted keystore, prompts)
    ///   forge script ... --ledger                    (hardware wallet)
    ///   forge script ... --private-key $KEY          (forge reads it, script does not)
    ///   RISE_TESTNET_DEPLOYER_KEY=0x... forge script ...   (last resort)
    ///
    /// Only the last form needs the env var, and it is only consulted if the first three
    /// were not used -- vm.startBroadcast() with no argument lets forge supply whichever
    /// signer the flags selected.
    function run() external {
        address deployer;
        uint256 envKey = vm.envOr("RISE_TESTNET_DEPLOYER_KEY", uint256(0));
        if (envKey != 0) {
            deployer = vm.addr(envKey);
            vm.startBroadcast(envKey);
        } else {
            vm.startBroadcast();
            deployer = msg.sender;
        }
        address feeTo = FEE_TO == address(0) ? deployer : FEE_TO;

        // ---- exchange ----
        address matchingLib = deployCode("MatchingLib.sol:MatchingLib");

        address weth = WETH;
        if (weth == address(0)) {
            weth = address(new WETH9());
        }

        OrderbookFactory orderbookFactory = new OrderbookFactory();
        MatchingEngine engine = new MatchingEngine();
        orderbookFactory.initialize(address(engine));
        engine.initialize(address(orderbookFactory), feeTo, weth);

        engine.setDefaultFee(true, MAKER_FEE);
        engine.setDefaultFee(false, TAKER_FEE);
        engine.setPoolFeeShare(POOL_FEE_SHARE);

        // ---- swap system ----
        PoolFactory poolFactory = new PoolFactory();
        poolFactory.initialize(address(engine));

        SwapRouter router = new SwapRouter(address(poolFactory));

        PositionManager positionManager = new PositionManager();
        positionManager.initialize(POSITION_URI);
        positionManager.setPoolFactory(address(poolFactory));
        positionManager.setRouter(address(router));
        poolFactory.setPositionManager(address(positionManager));

        // ---- the wiring that makes it tradeable ----
        engine.setPoolFactory(address(poolFactory));
        engine.setSwapRouter(address(router));

        vm.stopBroadcast();

        // Fail loudly rather than leaving a half-wired chain behind.
        require(engine.poolFactory() == address(poolFactory), "poolFactory not wired");
        require(engine.swapRouter() == address(router), "swapRouter not wired");
        require(poolFactory.impl() != address(0), "pool implementation missing");
        require(poolFactory.positionManager() == address(positionManager), "positionManager not wired");
        require(positionManager.router() == address(router), "pm.router not wired");

        console.log("");
        console.log("=== deployed ===");
        console.log("MatchingLib          %s", matchingLib);
        console.log("WETH                 %s", weth);
        console.log("OrderbookFactory     %s", address(orderbookFactory));
        console.log("MatchingEngine       %s", address(engine));
        console.log("PoolFactory          %s", address(poolFactory));
        console.log("PoolImplementation   %s", poolFactory.impl());
        console.log("PositionManager      %s", address(positionManager));
        console.log("SwapRouter           %s", address(router));
        console.log("");
        console.log("=== indexer env ===");
        console.log("CHAINID=11155931");
        console.log("RPC=https://testnet.riselabs.xyz/");
        console.log("MATCHING_ENGINE_ADDRESS=%s", address(engine));
        console.log("POOL_FACTORY_ADDRESS=%s", address(poolFactory));
        console.log("POSITION_MANAGER_ADDRESS=%s", address(positionManager));
        console.log("SWAP_ROUTER_ADDRESS=%s", address(router));
    }
}
