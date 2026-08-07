// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {BaseSetup} from "../exchange/OrderbookBaseSetup.sol";
import {Orderbook} from "../../src/exchange/orderbooks/Orderbook.sol";
import {PoolFactory} from "../../src/swap/PoolFactory.sol";
import {Pool} from "../../src/swap/Pool.sol";

contract PoolCreationTest is BaseSetup {
    PoolFactory poolFactory;
    address positionManager = address(0xBEEF);

    function _deployPoolFactory() internal {
        poolFactory = new PoolFactory();
        poolFactory.initialize(address(matchingEngine));
        poolFactory.setPositionManager(positionManager);
        matchingEngine.setPoolFactory(address(poolFactory));
    }

    function testAddPairCreatesBothOrderbookAndPool() public {
        super.setUp();
        _deployPoolFactory();

        matchingEngine.addPair(address(token1), address(token2), 1e8, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);

        address orderbookAddr = matchingEngine.getPair(address(token1), address(token2));
        assertTrue(orderbookAddr != address(0));

        address poolAddr = poolFactory.getPool(address(token1), address(token2));
        assertTrue(poolAddr != address(0));

        assertEq(Orderbook(payable(orderbookAddr)).getPool(), poolAddr);
        assertEq(Pool(poolAddr).positionManager(), positionManager);
        assertEq(Pool(poolAddr).orderbook(), orderbookAddr);
    }

    function testCreatePoolOnlyCallableByEngine() public {
        super.setUp();
        _deployPoolFactory();

        vm.expectRevert();
        poolFactory.createPool(address(token1), address(token2), address(0x1234));
    }
}
