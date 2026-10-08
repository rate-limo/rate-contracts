// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {AssetGenerator} from "../../src/asset/AssetGenerator.sol";
import {LadderBuyer} from "../../src/asset/LadderBuyer.sol";
import {WrappedNative} from "../../src/mock/WrappedNative.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";

interface IEngineFeeWiring {
    function setFeeManager(address feeManager) external returns (bool);
    function setIncentive(address incentive) external returns (bool);
    function incentive() external view returns (address);
    function feeManager() external view returns (address);
}

/// Enough of a previous AssetGenerator to recognise one.
interface IPreviousGenerator {
    function matchingEngine() external view returns (address);
}

/// Just the two the wrapper-quote check reads; `IMatchingEngine` declares neither.
interface IEngineNative {
    function WETH() external view returns (address);
    function nativeScale() external view returns (uint256);
}

/// Deploys AssetGenerator and performs the configuration without which it is inert.
///
/// Unlike the per-chain scripts under script/exchange, this one takes its addresses from
/// the environment rather than file-level constants. The generator is deployed onto an
/// EXISTING engine on whichever chain, and the follow-up sync step
/// (`packages/deployments/scripts/sync-deployment.mjs`) has to run per chain anyway —
/// one file that reads its target from env is less to keep in step than one file per chain.
///
/// Three settings are not optional and fail in ways that look healthy:
///
///   * setQuoteOption -- with no ENABLED quote, every launch() reverts QuoteNotEnabled.
///                       The contract deploys, reads fine, and cannot be used.
///   * setFeeTo       -- a non-zero launchFee with no feeTo reverts FeeToNotSet, so the
///                       fee and its recipient must be set together or not at all.
///   * MARKET_MAKER_ROLE on the ENGINE -- addPair charges a listing deposit unless the
///                       caller holds this role or is a registered terminal. Without it
///                       every launch reverts InvalidTerminal from inside addPair, which
///                       reads as a generator bug rather than a missing grant.
/// The engine wiring is venue-wide and order-sensitive, so the script guards it:
///
///   * `setFallbackIncentive(previous incentive)` BEFORE `setIncentive(generator)`, or
///     every pair the new generator does not know loses whatever the previous hook
///     answered (fees, terminal names, slippage caps) for as long as the gap lasts.
///     When the deployer is the generator's admin both happen here, in that order.
///     When it is not, the deployer cannot call setFallbackIncentive, so the script
///     does NOT rewire the engine and prints the three calls for the admin to make.
///   * A non-zero `feeManager` that is not an AssetGenerator (e.g. PairFeeManager) is
///     displaced by `setFeeManager(generator)` and its preset writes start reverting.
///     That needs ALLOW_REPLACE_FEE_MANAGER=true. Replacing a previous GENERATOR needs
///     ALLOW_REPLACE_GENERATOR=true (see `_refuseToOrphanAGenerator`).
///
/// It also deploys LadderBuyer, the role-less helper the app sends Buy/Sell through
/// (one taker order per ladder step). It holds no state and needs no wiring.
///
/// Gas-coin quotes. A launch quoted in the chain's gas coin is quoted in a WrappedNative
/// (a plain 1:1 ERC-20), never in the engine's own WETH: on an unwrapping chain that one
/// gets no band pool and settles as native coin (see WrappedNative). Env:
///   NATIVE_WRAPPER=<addr>          reuse an existing WrappedNative, or
///   DEPLOY_NATIVE_WRAPPER=true     deploy one (NATIVE_WRAPPER_NAME / NATIVE_WRAPPER_SYMBOL,
///                                  default "Wrapped Ether" / "wETH" -- not "WETH": several
///                                  WETH-symbol tokens already confuse RISE, contracts/CLAUDE.md)
///   neither                        no wrapper (Arc: the gas coin IS USDC; the native paths
///                                  of LadderBuyer then revert NoWrappedNative)
///   NATIVE_STARTING_MARKET_CAP / NATIVE_MIN_DEV_BUY / NATIVE_GRADUATION_MARKET_CAP (wei)
///                                  enable the wrapper as a launch quote. Size them in ETH at
///                                  today's price, AND mind the engine's 1e8 price floor: a
///                                  starting price under 100 units reverts ListingPriceTooLow,
///                                  so at 2.5 ETH a coin's supply must stay under ~2.5M.
/// Sync it with `--contract WrappedNative=wrappedNative`. The wrapper must also be in
/// packages/token-list for the chain, or its markets price at 0 and vanish from the app.
///
/// Run (the launch library is linked out and must be deployed first):
///   forge script script/launch/AssetGeneratorDeploy.s.sol:DeployAssetLaunchLib \
///     --rpc-url $RPC --broadcast
///   forge script script/launch/AssetGeneratorDeploy.s.sol:DeployAssetGenerator \
///     --rpc-url $RPC --broadcast \
///     --libraries src/asset/libraries/AssetLaunchLib.sol:AssetLaunchLib:$ASSET_LAUNCH_LIB
///   node packages/deployments/scripts/sync-deployment.mjs \
///     --script AssetGeneratorDeploy --chain $CHAIN_ID \
///     --contract AssetGenerator=assetGenerator --contract LadderBuyer=ladderBuyer
///
/// The second command is what writes the address, the start block and the regenerated ABI
/// into packages/deployments and packages/abis. A deploy that skips it leaves the indexer
/// with no ASSET_GENERATOR_ADDRESS, and launches are never indexed.
contract DeployAssetGenerator is Script {
    /// keccak256("MARKET_MAKER_ROLE") -- private constant on MatchingEngine, so it is
    /// recomputed here rather than read.
    bytes32 internal constant MARKET_MAKER_ROLE = keccak256("MARKET_MAKER_ROLE");

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address engine = vm.envAddress("MATCHING_ENGINE");
        address quote = vm.envAddress("LAUNCH_QUOTE");
        address admin = vm.envOr("ASSET_GENERATOR_ADMIN", vm.addr(deployerKey));
        address feeTo = vm.envOr("LAUNCH_FEE_TO", admin);
        uint256 launchFee = vm.envOr("LAUNCH_FEE_WEI", uint256(0));
        // In the QUOTE's base units: every coin opens at this market cap, and its starting
        // price is this over its supply. $5,000 and $5 for a 6-decimal USDC.
        uint256 startingMarketCap = vm.envOr("LAUNCH_STARTING_MARKET_CAP", uint256(5_000e6));
        uint256 minDevBuy = vm.envOr("LAUNCH_MIN_DEV_BUY", uint256(5e6));
        // The ladder's last step: a coin graduates once its supply has sold up to here.
        uint256 graduationMarketCap = vm.envOr("LAUNCH_GRADUATION_MARKET_CAP", uint256(25_000e6));
        // The engine's current hooks, read BEFORE anything is rewired.
        address previousIncentive = IEngineFeeWiring(engine).incentive();
        address previousFeeManager = IEngineFeeWiring(engine).feeManager();
        _refuseToOrphanAGenerator(engine, previousIncentive);
        _refuseToOrphanAGenerator(engine, previousFeeManager);
        _refuseToDisplaceAFeeManager(engine, previousFeeManager);
        bool deployerIsAdmin = admin == vm.addr(deployerKey);
        // Per quote, on the 1e8 FEE_DENOM scale: launched coins trade at 1.00%.
        uint32 startingTakerFee = uint32(vm.envOr("LAUNCH_STARTING_TAKER_FEE", uint256(1_000_000)));

        vm.startBroadcast(deployerKey);

        AssetGenerator generator = new AssetGenerator(admin, engine);

        // Config. Ordering is free here -- these are independent setters -- but all of
        // them must run before the first launch, and the deployer holds ADMIN_ROLE only
        // if it is also `admin`.
        if (deployerIsAdmin) {
            generator.setFeeTo(feeTo);
            generator.setLaunchFee(launchFee);
            // LADDER_DEFERRED=true: two-transaction launches, for a chain whose per-tx gas
            // cap cannot hold a whole launch (Tempo). See AssetLaunchLib.placeDeferredLadder.
            if (vm.envOr("LADDER_DEFERRED", false)) generator.setLadderDeferred(true);
            // At least one enabled quote, or launch() is unusable.
            // Pairs this generator did not launch keep being answered by whatever
            // answered them before; without this every one of them falls to the default.
            if (previousIncentive != address(0)) generator.setFallbackIncentive(previousIncentive);
            generator.setQuoteOption(
                quote,
                true,
                startingMarketCap,
                minDevBuy,
                graduationMarketCap,
                ExchangeOrderbook.MatchingMode.PriceTimePriority,
                startingTakerFee
            );
        } else {
            console.log("!! admin is not the deployer -- run the setters from the admin key:");
            console.log("   setFeeTo / setLaunchFee / setQuoteOption / setFallbackIncentive(previous incentive)");
        }

        // The listing and spread grant: launches list pairs and widen the ladder's limit
        // spread. Reverts unless the deployer holds DEFAULT_ADMIN_ROLE on the
        // engine; that is a real precondition, not something to swallow.
        IAccessControl(engine).grantRole(MARKET_MAKER_ROLE, address(generator));
        // A coin's 1% and a listed pair's fee only take effect once the generator both
        // writes the engine's pair fee (feeManager) and answers its lookups (incentive):
        // the engine charges the LOWER of the two. Only when the fallback above is
        // already in place -- otherwise the admin wires it, in order, below.
        bool wired = deployerIsAdmin || previousIncentive == address(0);
        if (wired) {
            IEngineFeeWiring(engine).setFeeManager(address(generator));
            IEngineFeeWiring(engine).setIncentive(address(generator));
        }

        _deployBuyer(engine, generator, deployerIsAdmin, startingTakerFee);

        vm.stopBroadcast();

        if (!wired) {
            console.log("!! engine NOT rewired: the previous incentive needs a fallback first. From the admin key:");
            console.log("   1. generator.setFallbackIncentive(%s)", previousIncentive);
            console.log("   2. engine.setFeeManager(%s)", address(generator));
            console.log("   3. engine.setIncentive(%s)", address(generator));
        }

        console.log("ASSET_GENERATOR_ADDRESS=%s", address(generator));
        console.log("admin=%s", admin);
        console.log("previous incentive=%s  previous feeManager=%s", previousIncentive, previousFeeManager);
        console.log("quote enabled=%s  startingTakerFee=%s", quote, startingTakerFee);
        console.log("next: node packages/deployments/scripts/sync-deployment.mjs \\");
        console.log("        --script AssetGeneratorDeploy --chain <id> --contract AssetGenerator=assetGenerator \\");
        console.log("        --contract LadderBuyer=ladderBuyer --contract WrappedNative=wrappedNative");
    }

    /// The gas-coin wrapper (if any), its quote option, and LadderBuyer bound to it. Its
    /// own frame: `run()` has no stack slot left for the wrapper.
    function _deployBuyer(address engine, AssetGenerator generator, bool deployerIsAdmin, uint32 takerFee) internal {
        address wrapper = _nativeWrapper(engine);
        if (wrapper != address(0) && deployerIsAdmin) _enableNativeQuote(generator, wrapper, takerFee);
        LadderBuyer ladderBuyer = new LadderBuyer(engine, wrapper);
        console.log("LADDER_BUYER_ADDRESS=%s", address(ladderBuyer));
        console.log("WRAPPED_NATIVE_ADDRESS=%s", wrapper);
    }

    /// The gas-coin wrapper launches can be quoted in: reused, deployed, or none.
    function _nativeWrapper(address engine) internal returns (address wrapper) {
        wrapper = vm.envOr("NATIVE_WRAPPER", address(0));
        if (wrapper == address(0) && vm.envOr("DEPLOY_NATIVE_WRAPPER", false)) {
            wrapper = address(
                new WrappedNative(
                    vm.envOr("NATIVE_WRAPPER_NAME", string("Wrapped Ether")),
                    vm.envOr("NATIVE_WRAPPER_SYMBOL", string("wETH"))
                )
            );
        }
        if (wrapper != address(0)) _checkWrapper(wrapper);
        // The engine's own WETH on an unwrapping chain is exactly what this must not be.
        IEngineNative e = IEngineNative(engine);
        require(
            wrapper == address(0) || e.nativeScale() != 0 || wrapper != e.WETH(),
            "NATIVE_WRAPPER is the engine's WETH: it gets no band pool and settles as native coin"
        );
    }

    /// A wrapper is trusted with every gas-coin launch's money, so prove it is one before
    /// binding it: it has code, and 1 wei deposited comes back as 1 wei withdrawn.
    function _checkWrapper(address wrapper) internal {
        require(wrapper.code.length > 0, "NATIVE_WRAPPER has no code");
        // Inside the broadcast the caller is the deployer; the wrapper's own native balance
        // is the gas-independent side of the round trip.
        address deployer = msg.sender;
        WrappedNative w = WrappedNative(payable(wrapper));
        uint256 tokens = w.balanceOf(deployer);
        uint256 held = wrapper.balance;
        w.deposit{value: 1}();
        require(w.balanceOf(deployer) == tokens + 1 && wrapper.balance == held + 1, "NATIVE_WRAPPER deposit");
        w.withdraw(1);
        require(w.balanceOf(deployer) == tokens && wrapper.balance == held, "NATIVE_WRAPPER withdraw");
    }

    /// Enables the wrapper as a launch quote when its sizes are given.
    function _enableNativeQuote(AssetGenerator generator, address wrapper, uint32 takerFee) internal {
        uint256 start = vm.envOr("NATIVE_STARTING_MARKET_CAP", uint256(0));
        if (start == 0) return;
        generator.setQuoteOption(
            wrapper,
            true,
            start,
            vm.envUint("NATIVE_MIN_DEV_BUY"),
            vm.envUint("NATIVE_GRADUATION_MARKET_CAP"),
            ExchangeOrderbook.MatchingMode.PriceTimePriority,
            takerFee
        );
    }

    /**
     * Replacing the engine's incentive or feeManager when it is an AssetGenerator takes
     * from that generator's coins the engine-side half of their policy: their fees fall
     * back through `fallbackIncentive`, and their creators can no longer write the
     * engine's pair fee. That has to be a decision, not a side effect, so it needs
     * ALLOW_REPLACE_GENERATOR=true. Recognised by asking for the engine it lists on.
     */
    function _refuseToOrphanAGenerator(address engine, address hook) internal view {
        if (hook == address(0) || hook.code.length == 0) return;
        try IPreviousGenerator(hook).matchingEngine() returns (address e) {
            if (e == engine && !vm.envOr("ALLOW_REPLACE_GENERATOR", false)) {
                revert(
                    "the engine's incentive/feeManager is an AssetGenerator whose coins would lose their engine policy; set ALLOW_REPLACE_GENERATOR=true to proceed"
                );
            }
        } catch {}
    }

    /**
     * A non-zero feeManager that is NOT a generator on this engine (e.g. PairFeeManager)
     * is displaced by `setFeeManager(generator)`, and every preset write it makes from
     * then on reverts. Generators are handled by `_refuseToOrphanAGenerator`.
     */
    function _refuseToDisplaceAFeeManager(address engine, address feeManager) internal view {
        if (feeManager == address(0) || vm.envOr("ALLOW_REPLACE_FEE_MANAGER", false)) return;
        if (feeManager.code.length > 0) {
            try IPreviousGenerator(feeManager).matchingEngine() returns (address e) {
                if (e == engine) return;
            } catch {}
        }
        revert("the engine's feeManager is not an AssetGenerator and would be displaced; set ALLOW_REPLACE_FEE_MANAGER=true to proceed");
    }
}

/// Deploys the external launch library used by AssetGenerator. Keep this as a
/// separate transaction: Solidity libraries are linked by address at deploy
/// time, and deploying the generator without --libraries leaves unresolved
/// link references.
contract DeployAssetLaunchLib is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        vm.startBroadcast(deployerKey);
        address libraryAddress = deployCode("AssetLaunchLib.sol:AssetLaunchLib");
        vm.stopBroadcast();
        console.log("ASSET_LAUNCH_LIB=%s", libraryAddress);
    }
}

/// Read-only preflight, mirroring VerifySwapWiring. Confirms the four settings above are
/// actually in place before anyone tries to launch, since three of them fail invisibly.
contract VerifyAssetGeneratorWiring is Script {
    bytes32 internal constant MARKET_MAKER_ROLE = keccak256("MARKET_MAKER_ROLE");

    function run() external view {
        AssetGenerator generator = AssetGenerator(vm.envAddress("ASSET_GENERATOR"));
        address engine = vm.envAddress("MATCHING_ENGINE");

        address[] memory quotes = generator.enabledQuoteTokens();
        bool listingAllowed = IAccessControl(engine).hasRole(MARKET_MAKER_ROLE, address(generator));

        console.log("matchingEngine   = %s", generator.matchingEngine());
        console.log("feeTo            = %s", generator.feeTo());
        console.log("launchFee        = %s", generator.launchFee());
        console.log("maxCreatorFee    = %s", generator.maxCreatorTakerFee());
        console.log("fallbackIncentive= %s", generator.fallbackIncentive());
        console.log("enabled quotes   = %s", quotes.length);
        console.log("MARKET_MAKER_ROLE= %s", listingAllowed);

        if (quotes.length == 0) console.log("FAIL: no enabled quote -- every launch() reverts QuoteNotEnabled");

        /*
         * A COIN LAUNCHED AGAINST A REAL WRAPPER GETS NO BAND POOL, EVER.
         *
         * `MatchingEngine.addPair` skips pool creation for any pair touching
         * `WETH()` -- Orderbook settlement unwraps, which the pool's balance-delta
         * accounting cannot see. So a generator whose ONLY enabled quote is the
         * wrapper launches coins that can never hold pool liquidity: the book
         * works, every deposit surface reports "No band pool is listed", and
         * nothing about the deployment looks wrong.
         *
         * `nativeScale` is what separates the two cases and is why this is a
         * check rather than a ban. Zero means WETH() is a genuine wrapper (RISE),
         * and this fires. Nonzero means WETH() is the native coin's own ERC-20
         * (Arc, where it is USDC), settlement never unwraps, and `addPair`
         * creates the pool -- so quoting against it there is correct.
         *
         * Caught on RISE on 2026-09-27, after a redeploy enabled WETH alone and
         * the previous generation's TUSD had to be re-enabled by hand.
         */
        uint256 scale = IEngineNative(engine).nativeScale();
        address wrapped = IEngineNative(engine).WETH();
        if (scale == 0) {
            bool nonWrapperQuote = false;
            for (uint256 i = 0; i < quotes.length; i++) {
                if (quotes[i] != wrapped) nonWrapperQuote = true;
            }
            if (!nonWrapperQuote && quotes.length > 0) {
                console.log("FAIL: the only enabled quote is WETH (%s) and nativeScale is 0 --", wrapped);
                console.log("      addPair opens NO band pool for a WETH leg, so every coin launched");
                console.log("      here can trade on the book and never hold pool liquidity.");
                console.log("      Enable a non-wrapper quote with setQuoteOption before launching.");
            }
        }
        if (!listingAllowed) console.log("FAIL: generator cannot list -- addPair will revert InvalidTerminal");
        if (generator.feeTo() == address(0) && generator.launchFee() > 0) {
            console.log("FAIL: launchFee set with no feeTo -- every launch() reverts FeeToNotSet");
        }
    }
}
