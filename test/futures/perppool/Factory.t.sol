// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PerpPoolUnitSetup} from "../PerpPoolUnitSetup.sol";
import {PerpPool} from "../../../src/futures/pools/PerpPool.sol";

contract PerpPoolFactoryTest is PerpPoolUnitSetup {
    function testCreatePerpPoolIsKeyedOnBaseQuoteOnly() public {
        address pool = setUpPool(10, 8000, 1000e18);
        assertEq(factory.getPool(address(baseToken), address(quoteToken)), pool);
    }

    function testCreatePerpPoolOnlyCallableByPerpEngine() public {
        setUpPool(10, 8000, 1000e18); // deploys factory + one pool as a side effect

        address[] memory collaterals = new address[](1);
        collaterals[0] = address(quoteToken);

        vm.expectRevert();
        factory.createPerpPool(address(baseToken), address(0x9999), collaterals, 10, 8000, 1000e18);
    }

    function testCreatePerpPoolRevertsOnDuplicateBaseQuote() public {
        setUpPool(10, 8000, 1000e18);

        address[] memory collaterals = new address[](1);
        collaterals[0] = address(quoteToken);

        vm.prank(perpEngine);
        vm.expectRevert();
        factory.createPerpPool(address(baseToken), address(quoteToken), collaterals, 10, 8000, 1000e18);
    }
}
