// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PerpPoolFactory} from "../../src/futures/pools/PerpPoolFactory.sol";
import {IPerpPool} from "../../src/futures/interfaces/IPerpPool.sol";
import {MockToken} from "../../src/mock/MockToken.sol";

// Unit-test setup for exercising PerpPool directly, before PerpEngine exists (Task 7).
// `perpEngine` here is a test-controlled address standing in for the real PerpEngine contract --
// PerpPool's onlyPerpEngine modifier only cares that calls come from this exact address.
contract PerpPoolUnitSetup is Test {
    PerpPoolFactory factory;
    address perpEngine = address(0xE9611E);
    address matchingEngine = address(0xAA55);

    MockToken baseToken;
    MockToken quoteToken;
    MockToken altCollateral;

    address trader1 = address(0x1001);
    address trader2 = address(0x1002);

    function setUpPool(uint32 maxLeverage, uint32 maxUtilizationBps, uint256 minSpotLiquidity)
        internal
        returns (address pool)
    {
        baseToken = new MockToken("Base", "BASE", 18);
        quoteToken = new MockToken("Quote", "QUOTE", 18);
        altCollateral = new MockToken("Alt", "ALT", 18);

        factory = new PerpPoolFactory();
        factory.initialize(matchingEngine, perpEngine);

        // Only quote collateral is enabled (final-branch review I1 -- non-quote collateral is
        // gated off in PerpPool.initialize until Phase 2 designs the alt backing model).
        // altCollateral is still deployed above for the dedicated
        // testInitializeRevertsOnNonQuoteCollateral case in Init.t.sol.
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(quoteToken);

        vm.prank(perpEngine);
        pool = factory.createPerpPool(
            address(baseToken), address(quoteToken), collaterals, maxLeverage, maxUtilizationBps, minSpotLiquidity
        );
    }
}
