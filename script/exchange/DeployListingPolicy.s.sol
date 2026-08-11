// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MatchingEngine} from "../../src/exchange/MatchingEngine.sol";
import {MarketListingRegistry} from "../../src/exchange/MarketListingRegistry.sol";
import {PairFeeManager} from "../../src/exchange/PairFeeManager.sol";

/// @notice Deploys and wires the modular listing and five-class fee policy.
/// Required environment variables:
/// MATCHING_ENGINE, LISTING_BOND_TOKEN, LISTING_TREASURY, DEPLOYER_PRIVATE_KEY.
/// Bond amounts use the bond token's native decimals.
contract DeployListingPolicy is Script {
    function run() external returns (MarketListingRegistry registry, PairFeeManager feeManager) {
        address engineAddress = vm.envAddress("MATCHING_ENGINE");
        address bondToken = vm.envAddress("LISTING_BOND_TOKEN");
        address treasury = vm.envAddress("LISTING_TREASURY");
        uint256 privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint64 reviewPeriod = uint64(vm.envOr("LISTING_REVIEW_PERIOD", uint256(30 days)));
        uint32 poolFeeShare = uint32(vm.envOr("POOL_FEE_SHARE", uint256(60_000_000)));
        uint96[3] memory bonds = [
            uint96(vm.envOr("ESTABLISHED_LISTING_BOND", uint256(500e6))),
            uint96(vm.envOr("STANDARD_LISTING_BOND", uint256(1_000e6))),
            uint96(vm.envOr("HIGH_RISK_LISTING_BOND", uint256(2_000e6)))
        ];

        vm.startBroadcast(privateKey);
        feeManager = new PairFeeManager(engineAddress);
        MatchingEngine(payable(engineAddress)).setFeeManager(address(feeManager));
        MatchingEngine(payable(engineAddress)).setPoolFeeShare(poolFeeShare);
        registry = new MarketListingRegistry(
            engineAddress, bondToken, treasury, reviewPeriod, bonds
        );
        vm.stopBroadcast();

        console.log("PairFeeManager:", address(feeManager));
        console.log("MarketListingRegistry:", address(registry));
    }
}
