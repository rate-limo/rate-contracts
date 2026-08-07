// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MockBTC} from "../../../src/mock/MockBTC.sol";
import {MockToken} from "../../../src/mock/MockToken.sol";
import {MatchingEngine} from "../../../src/exchange/MatchingEngine.sol";
import {OrderbookFactory} from "../../../src/exchange/orderbooks/OrderbookFactory.sol";
import {Orderbook} from "../../../src/exchange/orderbooks/Orderbook.sol";
import {Multicall3} from "../../Multicall3.sol";
import {TokenDispenser} from "../../../src/exchange/airdrops/TokenDispenser.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {Iter} from "../../../src/iter/ccip/ITER.sol";

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

contract DeployStandard is Deployer {
    Iter public iter;

    function run() external {
        _setDeployer();
        iter = new Iter();
        vm.stopBroadcast();
    }
}

contract MintStandard is Deployer {
    address iter_address = 0xa111a06BDEbb8b1dAA79000F4B386A36E0AccE56;
    Iter public iter;
    address minter = 0xF8FB4672170607C95663f4Cc674dDb1386b7CfE0;

    function run() external {
        _setDeployer();
        iter = Iter(iter_address);
        iter.mint(minter, 1000_000_000 * 10 ** 18);
    }
}

contract GrantMinterRole is Deployer {
    address iter_address = 0x7a2e3a7A1bf8FaCCAd68115DC509DB5a5af4e7e4;
    Iter public iter;
    address minter = address(0);

    function run() external {
        _setDeployer();
        iter = Iter(iter_address);
        iter.grantRole(iter.MINTER_ROLE(), minter);
    }
}
