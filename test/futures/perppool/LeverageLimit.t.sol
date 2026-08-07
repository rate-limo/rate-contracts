// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PerpEngineBaseSetup} from "../PerpEngineBaseSetup.sol";
import {PerpPool} from "../../../src/futures/pools/PerpPool.sol";

contract LeverageLimitTest is PerpEngineBaseSetup {
    function testPoolEnforcesItsConfiguredMaxLeverage() public {
        perpEngineSetUp();
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(stablecoin);
        address pool = perpEngine.addPool(address(token1), address(stablecoin), collaterals, 10, 8000, 0);

        assertEq(PerpPool(pool).maxLeverage(), 10);

        // Deviation A: seed the pool's reserve so the revert this test asserts is unambiguously
        // the leverage check, not the OI cap. openPosition checks leverage BEFORE the cap
        // (PerpPool.openPosition, leverage check precedes the cap check), so this isn't strictly
        // required for the revert to fire -- but seeding keeps the test honest about proving the
        // leverage limit under realistic conditions rather than an artificially empty pool.
        stablecoin.mint(address(this), 10000e18);
        stablecoin.approve(pool, 10000e18);
        perpEngine.seedPool(pool, address(stablecoin), 10000e18);

        vm.prank(trader1);
        stablecoin.approve(pool, 1000e18);

        vm.prank(trader1);
        vm.expectRevert(abi.encodeWithSelector(PerpPool.LeverageLimitExceeded.selector, 11, 10));
        perpEngine.long(pool, address(stablecoin), 100e18, 11); // exceeds pool max of 10
    }
}
