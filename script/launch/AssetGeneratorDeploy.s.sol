// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {AssetGenerator} from "../../src/asset/AssetGenerator.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";

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
/// The fee tiers themselves need one more call this script does NOT make:
/// `MatchingEngine.setIncentive(assetGenerator)`. It is left out because it is
/// venue-wide -- it repoints fee resolution for EVERY pair, not just generated ones --
/// and because `setFallbackIncentive` must be set first or non-generated pairs lose their
/// terminal registration (the engine reads terminalName outside a try/catch during
/// listing). Do it deliberately, after this script, having read AssetGenerator.feeOf.
///
/// Run (the launch library is linked out and must be deployed first):
///   forge script script/launch/AssetGeneratorDeploy.s.sol:DeployAssetLaunchLib \
///     --rpc-url $RPC --broadcast
///   forge script script/launch/AssetGeneratorDeploy.s.sol:DeployAssetGenerator \
///     --rpc-url $RPC --broadcast \
///     --libraries src/asset/libraries/AssetLaunchLib.sol:AssetLaunchLib:$ASSET_LAUNCH_LIB
///   node packages/deployments/scripts/sync-deployment.mjs \
///     --script AssetGeneratorDeploy --chain $CHAIN_ID --contract AssetGenerator=assetGenerator
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
        // Quote-denominated, 1e8-scaled, exactly as addPair takes it.
        uint256 listingPrice = vm.envOr("LAUNCH_LISTING_PRICE", uint256(1e8));
        // Per quote, on the 1e8 FEE_DENOM scale: 100_000 is 0.10%, 1_000_000 is 1.00%.
        uint32 startingTakerFee = uint32(vm.envOr("LAUNCH_STARTING_TAKER_FEE", uint256(100_000)));

        vm.startBroadcast(deployerKey);

        AssetGenerator generator = new AssetGenerator(admin, engine);

        // Config. Ordering is free here -- these are independent setters -- but all of
        // them must run before the first launch, and the deployer holds ADMIN_ROLE only
        // if it is also `admin`.
        if (admin == vm.addr(deployerKey)) {
            generator.setFeeTo(feeTo);
            generator.setLaunchFee(launchFee);
            // At least one enabled quote, or launch() is unusable. listingPayment = 0
            // means "pay the listing cost in the new coin", which is what the launch flow
            // assumes; the generator holds the fresh supply at that moment.
            generator.setQuoteOption(
                quote,
                true,
                listingPrice,
                address(0),
                ExchangeOrderbook.MatchingMode.PriceTimePriority,
                startingTakerFee
            );
        } else {
            console.log("!! admin is not the deployer -- run the setters from the admin key:");
            console.log("   setFeeTo / setLaunchFee / setQuoteOption");
        }

        // The listing grant. Reverts unless the deployer holds DEFAULT_ADMIN_ROLE on the
        // engine; that is a real precondition, not something to swallow.
        IAccessControl(engine).grantRole(MARKET_MAKER_ROLE, address(generator));

        vm.stopBroadcast();

        console.log("ASSET_GENERATOR_ADDRESS=%s", address(generator));
        console.log("admin=%s", admin);
        console.log("quote enabled=%s  startingTakerFee=%s", quote, startingTakerFee);
        console.log("next: node packages/deployments/scripts/sync-deployment.mjs \\");
        console.log("        --script AssetGeneratorDeploy --chain <id> --contract AssetGenerator=assetGenerator");
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
        if (!listingAllowed) console.log("FAIL: generator cannot list -- addPair will revert InvalidTerminal");
        if (generator.feeTo() == address(0) && generator.launchFee() > 0) {
            console.log("FAIL: launchFee set with no feeTo -- every launch() reverts FeeToNotSet");
        }
    }
}
