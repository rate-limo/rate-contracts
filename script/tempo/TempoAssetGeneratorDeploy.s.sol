// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TempoAssetGenerator} from "../../src/tempo/TempoAssetGenerator.sol";
import {LadderBuyer} from "../../src/asset/LadderBuyer.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";

interface IEngineFeeWiring {
    function setFeeManager(address feeManager) external returns (bool);
    function setIncentive(address incentive) external returns (bool);
    function incentive() external view returns (address);
    function feeManager() external view returns (address);
}

interface IPreviousGenerator {
    function matchingEngine() external view returns (address);
}

/// Deploys TempoAssetGenerator -- Tempo's copy of AssetGenerator -- and configures it.
/// script/launch/AssetGeneratorDeploy.s.sol does the same for every other chain; this one
/// differs where Tempo does:
///
///   * the generator links TempoAssetLaunchLib, which takes the launch fee in the QUOTE
///     token. LAUNCH_FEE is therefore in quote units (PathUSD: 6 decimals), not wei;
///   * launches are always two transactions (ladderDeferred): launch() alone measured
///     ~30M gas against Tempo's 30M per-transaction cap;
///   * there is no gas-coin wrapper -- Tempo has no native coin and refuses any
///     transaction carrying value -- so LadderBuyer is bound to none and its native paths
///     revert NoWrappedNative.
///
/// Run with Foundry >= 1.8.5 and --skip-simulation (scripts/redeploy-testnet.sh --chain
/// tempo does both), then sync it as the chain's assetGenerator:
///   node packages/deployments/scripts/sync-deployment.mjs --script TempoAssetGeneratorDeploy \
///     --chain 42431 --contract TempoAssetGenerator=assetGenerator --contract LadderBuyer=ladderBuyer
contract DeployTempoAssetGenerator is Script {
    /// keccak256("MARKET_MAKER_ROLE") -- private constant on MatchingEngine.
    bytes32 internal constant MARKET_MAKER_ROLE = keccak256("MARKET_MAKER_ROLE");
    uint256 internal constant TEMPO_CHAIN_ID = 42431;

    struct Config {
        address engine;
        address quote;
        address admin;
        address feeTo;
        uint256 launchFee;
        uint256 startingMarketCap;
        uint256 minDevBuy;
        uint256 graduationMarketCap;
        uint32 startingTakerFee;
    }

    function run() external {
        require(block.chainid == TEMPO_CHAIN_ID, "DeployTempoAssetGenerator is for Tempo (42431) only");
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        Config memory c = _config(vm.addr(deployerKey));

        address previousIncentive = IEngineFeeWiring(c.engine).incentive();
        address previousFeeManager = IEngineFeeWiring(c.engine).feeManager();
        _refuseToOrphanAGenerator(c.engine, previousIncentive);
        _refuseToOrphanAGenerator(c.engine, previousFeeManager);
        _refuseToDisplaceAFeeManager(c.engine, previousFeeManager);
        bool deployerIsAdmin = c.admin == vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        TempoAssetGenerator generator = new TempoAssetGenerator(c.admin, c.engine);
        if (deployerIsAdmin) {
            _configure(generator, c, previousIncentive);
        } else {
            console.log("!! admin is not the deployer -- run from the admin key:");
            console.log("   setFeeTo / setLaunchFee / setLadderDeferred(true) / setQuoteOption / setFallbackIncentive");
        }

        IAccessControl(c.engine).grantRole(MARKET_MAKER_ROLE, address(generator));
        bool wired = deployerIsAdmin || previousIncentive == address(0);
        if (wired) {
            IEngineFeeWiring(c.engine).setFeeManager(address(generator));
            IEngineFeeWiring(c.engine).setIncentive(address(generator));
        }
        LadderBuyer ladderBuyer = new LadderBuyer(c.engine, address(0));

        vm.stopBroadcast();

        if (!wired) {
            console.log("!! engine NOT rewired: the previous incentive needs a fallback first. From the admin key:");
            console.log("   1. generator.setFallbackIncentive(%s)", previousIncentive);
            console.log("   2. engine.setFeeManager(%s)", address(generator));
            console.log("   3. engine.setIncentive(%s)", address(generator));
        }
        console.log("ASSET_GENERATOR_ADDRESS=%s", address(generator));
        console.log("LADDER_BUYER_ADDRESS=%s", address(ladderBuyer));
        console.log("launch fee=%s (quote units)  quote=%s", c.launchFee, c.quote);
    }

    function _config(address deployer) internal view returns (Config memory c) {
        c.engine = vm.envAddress("MATCHING_ENGINE");
        c.quote = vm.envAddress("LAUNCH_QUOTE");
        c.admin = vm.envOr("ASSET_GENERATOR_ADMIN", deployer);
        c.feeTo = vm.envOr("LAUNCH_FEE_TO", c.admin);
        // In LAUNCH_QUOTE's base units: 1e6 is one PathUSD.
        c.launchFee = vm.envOr("LAUNCH_FEE", uint256(0));
        c.startingMarketCap = vm.envOr("LAUNCH_STARTING_MARKET_CAP", uint256(5_000e6));
        c.minDevBuy = vm.envOr("LAUNCH_MIN_DEV_BUY", uint256(5e6));
        c.graduationMarketCap = vm.envOr("LAUNCH_GRADUATION_MARKET_CAP", uint256(25_000e6));
        c.startingTakerFee = uint32(vm.envOr("LAUNCH_STARTING_TAKER_FEE", uint256(1_000_000)));
    }

    function _configure(TempoAssetGenerator generator, Config memory c, address previousIncentive) internal {
        generator.setFeeTo(c.feeTo);
        generator.setLaunchFee(c.launchFee);
        generator.setLadderDeferred(true);
        if (previousIncentive != address(0)) generator.setFallbackIncentive(previousIncentive);
        generator.setQuoteOption(
            c.quote,
            true,
            c.startingMarketCap,
            c.minDevBuy,
            c.graduationMarketCap,
            ExchangeOrderbook.MatchingMode.PriceTimePriority,
            c.startingTakerFee
        );
    }

    /// See AssetGeneratorDeploy.s.sol: replacing a live generator's engine hooks needs
    /// ALLOW_REPLACE_GENERATOR=true.
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

    /// See AssetGeneratorDeploy.s.sol: a non-generator feeManager needs ALLOW_REPLACE_FEE_MANAGER=true.
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
