// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MatchingEngine} from "../src/exchange/MatchingEngine.sol";
import {StopOrderEngine} from "../src/exchange/StopOrderEngine.sol";
import {OrderbookFactory} from "../src/exchange/orderbooks/OrderbookFactory.sol";
import {BandPoolFactory} from "../src/swap/BandPoolFactory.sol";
import {BandPositionManager} from "../src/swap/BandPositionManager.sol";
import {BandPool} from "../src/swap/BandPool.sol";
import {PositionDescriptor} from "../src/swap/PositionDescriptor.sol";
import {BandSwapRouter} from "../src/swap/BandSwapRouter.sol";
import {WETH9} from "../src/mock/WETH9.sol";

/// The full exchange + swap stack for any EVM testnet whose gas coin is wrapped by a plain
/// WETH9 (Monad Testnet, Robinhood Chain Testnet). Identical in sequence and wiring to
/// RiseTestnetFull.s.sol, which this was copied from; only the wrapped-native address is
/// a parameter instead of a constant, so a new chain does not need a new script.
///
///   WRAPPED_NATIVE=0x...   reuse an existing wrapper (must be what the engine's WETH() is to be)
///   unset                  deploy a fresh WETH9, right for a testnet's first bring-up
///
/// Driven by scripts/redeploy-testnet.sh, which also deploys the launch side and syncs the
/// registry; run it rather than this alone.
///
/// Ordering constraints, none of them free-form (see RiseTestnetFull.s.sol for the long form):
///   * OrderbookFactory.initialize before MatchingEngine.initialize.
///   * BandPoolFactory.initialize (which deploys the pool implementation) before any listing.
///   * MatchingEngine.setSwapRouter must happen, or every swap reverts NotRouter.
contract DeployTestnetFull is Script {
    /// Receives protocol fees. address(0) uses the deployer.
    address constant FEE_TO = address(0);

    /// Maker and taker fee, DENOM-scaled (1e8). MatchingEngine.initialize does NOT set
    /// these -- feeOf falls through to defaultMakerFee/defaultTakerFee, which start at
    /// zero, so a deployment that skips this runs entirely fee-free. 100000 = 0.1%, the
    /// value every swap fixture is written against.
    uint32 constant MAKER_FEE = 0;
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
    ///   DEPLOYER_KEY=0x... forge script ...                (last resort)
    ///
    /// Only the last form needs the env var, and it is only consulted if the first three
    /// were not used -- vm.startBroadcast() with no argument lets forge supply whichever
    /// signer the flags selected.
    function run() external {
        address deployer;
        uint256 envKey = vm.envOr("DEPLOYER_KEY", uint256(0));
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

        address weth = vm.envOr("WRAPPED_NATIVE", address(0));
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

        // Stop orders are intentionally a separate engine. It must be deployed before
        // pairs are listed: MatchingEngine.addPair creates the corresponding stop book
        // only when this address is already wired.
        StopOrderEngine stopOrderEngine = new StopOrderEngine(address(engine));
        engine.setStopOrderEngine(address(stopOrderEngine));

        // ---- swap system ----
        Swap memory sw = _deploySwap(address(engine), deployer);

        // ---- the wiring that makes it tradeable ----
        engine.setPoolFactory(address(sw.poolFactory));
        engine.setSwapRouter(address(sw.router));

        vm.stopBroadcast();

        // Fail loudly rather than leaving a half-wired chain behind.
        require(engine.poolFactory() == address(sw.poolFactory), "poolFactory not wired");
        require(engine.swapRouter() == address(sw.router), "swapRouter not wired");
        require(engine.getStopOrderEngine() == address(stopOrderEngine), "stopOrderEngine not wired");
        require(stopOrderEngine.matchingEngine() == address(engine), "stop engine points at wrong engine");
        require(sw.poolFactory.impl() == address(sw.poolImpl), "pool implementation missing");
        require(sw.positionManager.descriptor() == address(sw.descriptor), "descriptor not wired");
        require(sw.poolFactory.positionManager() == address(sw.positionManager), "positionManager not wired");
        // The manager holds no router of its own: it reads the engine's, which is the
        // same slot the pool's onlyRouter gate reads. One source, wired once.
        require(engine.swapRouter() == address(sw.router), "swapRouter not wired");

        console.log("");
        console.log("=== deployed ===");
        console.log("MatchingLib          %s", matchingLib);
        console.log("WETH                 %s", weth);
        console.log("OrderbookFactory     %s", address(orderbookFactory));
        console.log("MatchingEngine       %s", address(engine));
        console.log("StopOrderEngine      %s", address(stopOrderEngine));
        console.log("BandPoolFactory          %s", address(sw.poolFactory));
        console.log("PoolImplementation   %s", sw.poolFactory.impl());
        console.log("BandPositionManager      %s", address(sw.positionManager));
        console.log("PositionDescriptor   %s", address(sw.descriptor));
        console.log("BandSwapRouter           %s", address(sw.router));
        console.log("");
        console.log("=== indexer env ===");
        console.log("CHAINID=%s", block.chainid);
        console.log("MATCHING_ENGINE_ADDRESS=%s", address(engine));
        console.log("STOP_ORDER_ENGINE_ADDRESS=%s", address(stopOrderEngine));
        console.log("POOL_FACTORY_ADDRESS=%s", address(sw.poolFactory));
        console.log("POSITION_MANAGER_ADDRESS=%s", address(sw.positionManager));
        console.log("SWAP_ROUTER_ADDRESS=%s", address(sw.router));
    }

    struct Swap {
        BandPositionManager positionManager;
        BandSwapRouter router;
        BandPool poolImpl;
        BandPoolFactory poolFactory;
        PositionDescriptor descriptor;
    }

    /// The swap system, in its own frame: `run` alone is past the legacy stack limit.
    ///
    /// The factory takes the manager and the pool implementation at initialize -- a band
    /// pool is created with its manager already named, so no pool exists that nobody can
    /// deposit into. The implementation is deployed here rather than inside the factory so
    /// the pool's size never counts against the factory's. Each pool's creator is whoever
    /// listed its pair (MatchingEngine.addPair passes its caller); `deployer` is only the
    /// fallback for a caller that passes none.
    function _deploySwap(address engine, address deployer) internal returns (Swap memory sw) {
        sw.positionManager = new BandPositionManager();
        sw.positionManager.initialize(POSITION_URI);
        sw.router = new BandSwapRouter();
        sw.poolImpl = new BandPool();
        sw.poolFactory = new BandPoolFactory();
        sw.poolFactory.initialize(engine, address(sw.positionManager), address(sw.poolImpl), deployer);
        sw.positionManager.setPoolFactory(address(sw.poolFactory));
        // The on-chain card: one token, its whole ladder. Swappable, so not part of the
        // token's own deployment -- but without it every token renders the static base URI.
        sw.descriptor = new PositionDescriptor();
        sw.positionManager.setDescriptor(address(sw.descriptor));
    }
}
