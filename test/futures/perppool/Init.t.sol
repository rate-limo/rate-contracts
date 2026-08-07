// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PerpPoolUnitSetup} from "../PerpPoolUnitSetup.sol";
import {PerpPool} from "../../../src/futures/pools/PerpPool.sol";
import {PerpPoolFactory} from "../../../src/futures/pools/PerpPoolFactory.sol";
import {MockToken} from "../../../src/mock/MockToken.sol";

contract PerpPoolInitTest is PerpPoolUnitSetup {
    function testInitializeAcceptsConfiguredCollateralTokens() public {
        // Non-quote collateral is gated off (final-branch review I1) -- only the pool's quote
        // token may be configured as accepted collateral until Phase 2 designs alt backing.
        address pool = setUpPool(10, 8000, 1000e18);
        assertTrue(PerpPool(pool).isAcceptedCollateral(address(quoteToken)));
        assertFalse(PerpPool(pool).isAcceptedCollateral(address(altCollateral)));
        assertFalse(PerpPool(pool).isAcceptedCollateral(address(0xDEAD)));
    }

    function testInitializeRevertsOnNonQuoteCollateral() public {
        // Deploys a pool directly via the factory (rather than setUpPool, which now only ever
        // passes quote-only collateral lists) with a non-quote entry in collateralTokens_, and
        // asserts the specific NonQuoteCollateralNotSupported selector fires.
        baseToken = new MockToken("Base", "BASE", 18);
        quoteToken = new MockToken("Quote", "QUOTE", 18);
        altCollateral = new MockToken("Alt", "ALT", 18);

        factory = new PerpPoolFactory();
        factory.initialize(matchingEngine, perpEngine);

        address[] memory collaterals = new address[](2);
        collaterals[0] = address(quoteToken);
        collaterals[1] = address(altCollateral);

        vm.prank(perpEngine);
        vm.expectRevert(abi.encodeWithSelector(PerpPool.NonQuoteCollateralNotSupported.selector, address(altCollateral)));
        factory.createPerpPool(address(baseToken), address(quoteToken), collaterals, 10, 8000, 1000e18);
    }

    function testInitializeSetsRiskParams() public {
        address pool = setUpPool(10, 8000, 1000e18);
        assertEq(PerpPool(pool).maxLeverage(), 10);
        assertEq(PerpPool(pool).maxUtilizationBps(), 8000);
        assertEq(PerpPool(pool).minSpotLiquidity(), 1000e18);
    }

    function testReservesStartAtZero() public {
        address pool = setUpPool(10, 8000, 1000e18);
        assertEq(PerpPool(pool).reserveOf(address(quoteToken)), 0);
        assertEq(PerpPool(pool).reserveOf(address(altCollateral)), 0);
    }
}
