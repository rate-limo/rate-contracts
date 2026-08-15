// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {StopOrderEngine} from "../../src/exchange/StopOrderEngine.sol";

/**
 * @notice Deploys a StopOrderEngine bound to a given MatchingEngine.
 *
 * @dev Exists because `StopOrderEngine.matchingEngine` is `immutable`: a
 * MatchingEngine redeploy cannot rewire the existing stop engine, it needs a new
 * one. Without this the engine's `setStopOrderEngine` points at a stop engine
 * whose own `matchingEngine` is the PREVIOUS generation, and every `addPair`
 * that tries to open a stop book reverts `InvalidAccess` — which surfaces as a
 * seed script that cannot create markets, not as anything naming the stop engine.
 *
 * A script rather than `forge create` because this contract links two libraries
 * and `create` refuses dynamic linking; `script` resolves them the same way the
 * exchange deploy does.
 *
 * Reads MATCHING_ENGINE and RISE_TESTNET_DEPLOYER_KEY, matching the other
 * scripts in this directory.
 */
contract DeployStopOrderEngine is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("RISE_TESTNET_DEPLOYER_KEY");
        address engine = vm.envAddress("MATCHING_ENGINE");

        vm.startBroadcast(deployerKey);
        StopOrderEngine stopOrderEngine = new StopOrderEngine(engine);
        vm.stopBroadcast();

        console.log("StopOrderEngine:", address(stopOrderEngine));
        console.log("boundTo:", engine);
    }
}
