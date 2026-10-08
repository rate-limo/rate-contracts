// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Disperse} from "../../src/rewards/Disperse.sol";

/// Deploys {Disperse}. There is nothing to configure afterward -- no owner, no admin, no
/// wiring to an engine or a factory -- so this script is the whole deployment.
///
/// Unlike `AssetGeneratorDeploy` or the two `*TestnetFull` scripts, this contract touches
/// no chain-specific state at all: it never reads `WETH()`, `nativeScale()`, or anything
/// else that differs between a chain whose native coin is ether and one (Arc) whose
/// native coin is already an ERC-20. So the "no forge SCRIPT can touch Arc's native USDC"
/// limitation documented in `contracts/CLAUDE.md` does not apply here -- `Disperse` never
/// calls `USDC.totalSupply()` or anything like it, only whatever ERC-20 the caller passes
/// to `disperseToken` at call time, which happens outside this script entirely. A normal
/// `forge script ... --broadcast` deploy works unmodified on every chain this repo
/// targets, Arc included.
///
/// Run (never with --broadcast from this task):
///   forge script script/rewards/DisperseDeploy.s.sol --rpc-url $RPC --broadcast
///   node packages/deployments/scripts/sync-deployment.mjs \
///     --script DisperseDeploy --chain $CHAIN_ID --contract Disperse=disperse
contract DisperseDeploy is Script {
    function run() external returns (address disperse) {
        uint256 envKey = vm.envOr("DEPLOYER_KEY", uint256(0));
        if (envKey != 0) {
            vm.startBroadcast(envKey);
        } else {
            vm.startBroadcast();
        }

        Disperse d = new Disperse();
        disperse = address(d);

        vm.stopBroadcast();

        console.log("");
        console.log("=== deployed ===");
        console.log("Disperse   %s", disperse);
    }
}
