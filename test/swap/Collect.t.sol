// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {IPool} from "../../src/swap/interfaces/IPool.sol";

contract CollectTest is PoolBaseSetup {
    uint256 positionId;

    function setUp() public override {
        super.setUp();
        vm.prank(lp1);
        token1.approve(address(pool), 1000e18);
        vm.prank(lp1);
        token2.approve(address(pool), 1000e18);
        vm.prank(positionManager);
        positionId = pool.addLiquidity(80e8, 120e8, 1000000, 500e18, 500e18, lp1);
    }

    function testCollectWithNoAccruedFeeReturnsZero() public {
        vm.prank(positionManager);
        (uint256 baseFee, uint256 quoteFee) = pool.collect(positionId, lp1);
        assertEq(baseFee, 0);
        assertEq(quoteFee, 0);
    }

    function testCreditFeeThenCollectPaysOutAndDoesNotTouchPrincipal() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = positionId;
        uint256[] memory shares = new uint256[](1);
        shares[0] = 1;

        // creditFee is only callable by the Pool itself (see Task 2's Pool.creditFee) --
        // simulate the internal call swap() would make in Task 11.
        vm.prank(address(pool));
        pool.creditFee(ids, shares, false, 10e18); // 10 quote tokens of fee

        uint256 balBefore = token2.balanceOf(lp1);
        vm.prank(positionManager);
        (uint256 baseFee, uint256 quoteFee) = pool.collect(positionId, lp1);

        assertEq(baseFee, 0);
        assertEq(quoteFee, 10e18);
        assertEq(token2.balanceOf(lp1), balBefore + 10e18);

        IPool.Position memory p = pool.getPosition(positionId);
        assertEq(p.baseAmount, 500e18); // principal untouched
        assertEq(p.quoteAmount, 500e18); // principal untouched
        assertEq(p.feeOwedQuote, 0); // claimed
    }

    function testCreditFeeSplitsProportionallyAcrossMultiplePositions() public {
        vm.prank(lp2);
        token1.approve(address(pool), 1000e18);
        vm.prank(lp2);
        token2.approve(address(pool), 1000e18);
        vm.prank(positionManager);
        uint256 positionId2 = pool.addLiquidity(85e8, 115e8, 500000, 300e18, 300e18, lp2);

        uint256[] memory ids = new uint256[](2);
        ids[0] = positionId;
        ids[1] = positionId2;
        uint256[] memory shares = new uint256[](2);
        shares[0] = 3; // 3:1 split
        shares[1] = 1;

        vm.prank(address(pool));
        pool.creditFee(ids, shares, true, 40e18);

        assertEq(pool.getPosition(positionId).feeOwedBase, 30e18);
        assertEq(pool.getPosition(positionId2).feeOwedBase, 10e18);
    }
}
