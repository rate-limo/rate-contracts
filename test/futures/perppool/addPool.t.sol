// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PerpEngineBaseSetup} from "../PerpEngineBaseSetup.sol";
import {PerpEngine} from "../../../src/futures/PerpEngine.sol";

contract AddPoolTest is PerpEngineBaseSetup {
    function testAddPoolWithAllowlistedStablecoinAndExistingSpotMarket() public {
        perpEngineSetUp();
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(stablecoin);

        address pool = perpEngine.addPool(address(token1), address(stablecoin), collaterals, 10, 8000, 0);
        assertTrue(pool != address(0));
    }

    function testAddPoolRevertsForNonStablecoinQuote() public {
        perpEngineSetUp();
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(token2);

        vm.expectRevert(abi.encodeWithSelector(PerpEngine.QuoteNotStablecoin.selector, address(token2)));
        perpEngine.addPool(address(token1), address(token2), collaterals, 10, 8000, 0);
    }
}
