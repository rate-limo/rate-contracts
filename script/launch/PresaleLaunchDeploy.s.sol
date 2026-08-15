// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PresaleLaunch} from "../../src/asset/PresaleLaunch.sol";

/// @notice Deploys the auction presale coordinator against an existing venue.
///
/// Required environment: DEPLOYER_KEY, MATCHING_ENGINE, POSITION_MANAGER and
/// SETTLEMENT_TOKEN.
/// ASSET_GENERATOR is optional, but must be supplied before graduation if the
/// launch should apply the generator's pair policy. When supplied, this script
/// grants the coordinator PAIR_CONFIG_ROLE on AssetGenerator.
contract DeployPresaleLaunch is Script {
    bytes32 internal constant PAIR_CONFIG_ROLE = keccak256("PAIR_CONFIG_ROLE");
    bytes32 internal constant MARKET_MAKER_ROLE = keccak256("MARKET_MAKER_ROLE");

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address admin = vm.envOr("PRESALE_LAUNCH_ADMIN", vm.addr(deployerKey));
        address engine = vm.envAddress("MATCHING_ENGINE");
        address positionManager = vm.envAddress("POSITION_MANAGER");
        address settlementToken = vm.envAddress("SETTLEMENT_TOKEN");
        address generator = vm.envOr("ASSET_GENERATOR", address(0));

        vm.startBroadcast(deployerKey);
        PresaleLaunch launch = new PresaleLaunch(
            admin,
            engine,
            positionManager,
            generator,
            settlementToken
        );

        if (generator != address(0)) {
            IAccessControl(generator).grantRole(PAIR_CONFIG_ROLE, address(launch));
        }
        // Graduation lists the successful auction coin through MatchingEngine.
        // Without this role addPair charges a listing deposit the presale contract
        // neither owns nor approves, so every graduation fails after a healthy sale.
        IAccessControl(engine).grantRole(MARKET_MAKER_ROLE, address(launch));
        vm.stopBroadcast();

        console.log("PRESALE_LAUNCH_ADDRESS=%s", address(launch));
        console.log("admin=%s", admin);
        console.log("settlementToken=%s", settlementToken);
        console.log("assetGenerator=%s", generator);
        console.log("next: sync the address and ABI into packages/deployments and packages/abis");
    }
}
