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

/// Arc Testnet (5042002) bring-up: exchange, swap system, and every wiring call between
/// them, in one broadcast.
///
/// Structurally identical to RiseTestnetFull.s.sol and deliberately so -- the ordering
/// constraints below are properties of the contracts, not of a chain, and the sequence is
/// the one test/swap/DeploymentWiring.t.sol executes end to end and then trades through:
///
///   * OrderbookFactory.initialize must precede MatchingEngine.initialize -- the engine
///     reads factory.impl() and reverts FactoryNotInitialized if it is unset.
///   * BandPoolFactory.initialize deploys the Pool implementation every pair's pool is
///     cloned from, so it must precede any pair listing.
///   * MatchingEngine.setSwapRouter must happen at all. Pool.swap is onlyRouter and reads
///     this address off the engine; while it is address(0) every swap reverts NotRouter,
///     and nothing else about the deployment looks wrong.
///
/// ## What is NOT the same as RISE, and must not be copied from it
///
/// **Arc's native gas currency is USDC, not ether.** That is the one substantive
/// difference, and it lands on WRAPPED_NATIVE below rather than on any of the wiring.
contract DeployArcTestnet is Script {
    // ---------------------------------------------------------------- configuration

    /// The ERC-20 the engine reports from `WETH()`. On Arc this is USDC ITSELF -- the
    /// native gas coin is USDC and USDC is already an ERC-20 at this address, so there is
    /// nothing to wrap.
    ///
    /// The first bring-up deployed a WrappedNative (WUSDC) here, because MatchingEngine
    /// assumed the slot held a WETH9-shaped wrapper it could deposit()/withdraw() into.
    /// That wrapper was pure overhead: a second "USDC" in every token list, a phantom row
    /// in the balances panel, and -- worse -- MatchingEngine skips Pool creation for any
    /// pair touching WETH, which would have made the chain's primary quote asset the one
    /// asset that could never have pool liquidity.
    ///
    /// `nativeScale` (below) is what makes this address usable in the slot: it tells the
    /// engine this token needs no wrapping and how the two views' decimals relate.
    /// Verified on chain: deposit() and withdraw(uint256) do not exist here and revert
    /// exactly like a garbage selector, while balanceOf/totalSupply answer.
    address constant WRAPPED_NATIVE = 0x3600000000000000000000000000000000000000;

    /// Native wei per one WETH() token unit. Arc's native view is 18 decimals and its
    /// ERC-20 view is 6 -- one ledger at two precisions -- so 1e12. Zero would mean "this
    /// slot is a real wrapper", which on Arc reverts every native-in order.
    uint256 constant NATIVE_SCALE = 1e12;

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

    /// Spreads are NOT set here: MatchingEngine.initialize writes the production defaults
    /// (market 0.1%, limit 3%). Record what that implies for this chain in
    /// deployments.json rather than discovering it later -- a 0.1% market spread against a
    /// typical 5% LP slippage tier means the rail clamps every pool fill, so `lmp` records
    /// the rail rather than the price the swap traded at. That is
    /// config.matchedPriceReporting = false, and it is a measured property of the
    /// deployed spread, not a default to copy from RISE.

    /// Signer resolution, in order of preference. The keystore and hardware paths are
    /// first because they never put a private key in an environment variable, a shell
    /// history, or a process listing:
    ///
    ///   forge script ... --account arcDeployer       (encrypted keystore, prompts)
    ///   forge script ... --ledger                    (hardware wallet)
    ///   forge script ... --private-key $KEY          (forge reads it, script does not)
    ///   DEPLOYER_KEY=0x... forge script ...          (last resort; contracts/.env)
    ///
    /// Only the last form needs the env var, and it is only consulted if the first three
    /// were not used -- vm.startBroadcast() with no argument lets forge supply whichever
    /// signer the flags selected.
    ///
    /// `DEPLOYER_KEY`, NOT `ARC_TESTNET_DEPLOYER_KEY`. A chain-suffixed name is the exact
    /// mistake CLAUDE.md records under "One secret, one name": deploy-exchange.sh read
    /// `LINEA_TESTNET_DEPLOYER_KEY` for nine of its ten chains, so the same key was
    /// expected under one name by a shell wrapper and another by the script it invoked.
    /// RiseTestnetFull.s.sol still carries `RISE_TESTNET_DEPLOYER_KEY`; it is the dormant
    /// script, and that is not a precedent to copy.
    function run() external {
        // A wrong-chain broadcast is silent and expensive: the deploy succeeds, the
        // registry records addresses, and the indexer watches a chain nobody trades on.
        require(block.chainid == 5042002, "not Arc Testnet (5042002)");

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

        address wrappedNative = WRAPPED_NATIVE;

        OrderbookFactory orderbookFactory = new OrderbookFactory();
        MatchingEngine engine = new MatchingEngine();
        orderbookFactory.initialize(address(engine));
        engine.initialize(address(orderbookFactory), feeTo, wrappedNative);
        // MUST precede addPair: the engine consults nativeScale when deciding whether a
        // WETH-linked pair may have a Pool, and a pair listed before this is set keeps the
        // decision taken at its listing.
        engine.setNativeScale(NATIVE_SCALE);

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

        console.log("");
        console.log("=== deployed (Arc Testnet 5042002) ===");
        console.log("MatchingLib          %s", matchingLib);
        console.log("WETH() (= USDC)      %s", wrappedNative);
        console.log("OrderbookFactory     %s", address(orderbookFactory));
        console.log("MatchingEngine       %s", address(engine));
        console.log("StopOrderEngine      %s", address(stopOrderEngine));
        console.log("BandPoolFactory      %s", address(sw.poolFactory));
        console.log("PoolImplementation   %s", sw.poolFactory.impl());
        console.log("BandPositionManager  %s", address(sw.positionManager));
        console.log("PositionDescriptor   %s", address(sw.descriptor));
        console.log("BandSwapRouter       %s", address(sw.router));
        console.log("");
        console.log("=== indexer env ===");
        console.log("CHAINID=5042002");
        console.log("RPC=https://rpc.testnet.arc.network");
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
