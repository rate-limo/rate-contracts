// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MockBTC} from "../../src/mock/MockBTC.sol";
import {MockToken} from "../../src/mock/MockToken.sol";
import {MatchingEngine} from "../../src/exchange/MatchingEngine.sol";
import {OrderbookFactory} from "../../src/exchange/orderbooks/OrderbookFactory.sol";
import {Orderbook} from "../../src/exchange/orderbooks/Orderbook.sol";
import {Multicall3} from "../Multicall3.sol";
import {TokenDispenser} from "../../src/exchange/airdrops/TokenDispenser.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {Iter} from "../../src/iter/ccip/ITER.sol";

contract Deployer is Script {
    function _setDeployer() internal {
        uint256 deployerPrivateKey = vm.envUint("LINEA_TESTNET_DEPLOYER_KEY");
        vm.startBroadcast(deployerPrivateKey);
    }
}

contract DeployMulticall3 is Deployer {
    function run() external {
        _setDeployer();
        new Multicall3();
        vm.stopBroadcast();
    }
}

contract DeployITER is Deployer {
    Iter public iter;

    function run() external {
        _setDeployer();
        iter = new Iter();
        vm.stopBroadcast();
    }
}

contract GrantMinterRole is Deployer {
    address iter_address = 0xAd117e349e05c7B718B9AfbFde88EA60376bCE14;
    Iter public iter;
    address minter = address(0);

    function run() external {
        _setDeployer();
        iter = Iter(iter_address);
        iter.grantRole(iter.MINTER_ROLE(), minter);
    }
}
