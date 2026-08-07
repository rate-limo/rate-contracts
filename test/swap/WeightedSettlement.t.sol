// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {IPool} from "../../src/swap/interfaces/IPool.sol";

// The weighted-settlement allocation (Pool._allocateTierFlow): within a tier,
// mature positions split flow pro-rata by contribution x age multiplier;
// immature positions have zero weight and only catch the residual, in age
// order (the old waterfall rule). Listing price is 100e8 and the pool quotes
// tier legs at TWAP x (1 + slippageLimit), so with an otherwise-empty book a
// 5% tier fills at 105e8 = 105 quote per base: `quoteIn = baseWanted x 105`
// consumes exactly `baseWanted` of tier inventory (both mocks are 18-decimal).
contract WeightedSettlementTest is PoolBaseSetup {
    uint32 constant TOL = 5000000; // 5%

    function _addBase(uint32 tol, uint256 amount) internal returns (uint256 id) {
        vm.prank(lp1);
        token1.approve(address(pool), amount);
        vm.prank(positionManager);
        id = pool.addLiquidity(50e8, 150e8, tol, amount, 0, lp1);
    }

    function _swapQuoteForBase(uint256 quoteIn) internal {
        vm.prank(trader1);
        token2.approve(address(pool), quoteIn);
        vm.prank(trader1);
        pool.swap(quoteIn, true, trader1, false);
    }

    // Goal 2: equal age, equal tolerance -- flow (and therefore fees, which
    // follow `used` through creditFee) splits by SIZE, 1:3.
    function testMatureSameTierSplitsBySize() public {
        uint256 a = _addBase(TOL, 100e18);
        uint256 b = _addBase(TOL, 300e18);
        vm.warp(block.timestamp + 600); // both mature, same age

        _swapQuoteForBase(21000e18); // 200e18 base at the 105 quote/base bound: half the tier

        IPool.Position memory pa = pool.getPosition(a);
        IPool.Position memory pb = pool.getPosition(b);
        assertApproxEqRel(100e18 - pa.baseAmount, 50e18, 0.01e18);
        assertApproxEqRel(300e18 - pb.baseAmount, 150e18, 0.01e18);
    }

    // JIT defense: a same-block whale mint at the same tolerance supplies
    // NOTHING while the mature incumbent has inventory -- size cannot buy a
    // place in the queue before maturity.
    function testJitMintTakesNothingRegardlessOfSize() public {
        uint256 a = _addBase(TOL, 100e18);
        vm.warp(block.timestamp + 600); // incumbent matures
        uint256 b = _addBase(TOL, 1000e18); // 10x whale, minted this block

        _swapQuoteForBase(5250e18); // 50e18 base -- well within the incumbent

        IPool.Position memory pa = pool.getPosition(a);
        IPool.Position memory pb = pool.getPosition(b);
        assertApproxEqRel(100e18 - pa.baseAmount, 50e18, 0.01e18);
        assertEq(pb.baseAmount, 1000e18);
    }

    // Goal 1: equal size, equal tolerance -- the older position's dollar
    // weighs more. 15 days of loyalty ramp vs freshly mature is a weight
    // ratio of ~1.25 : ~1.00, so used amounts land ~5:4.
    function testOlderPositionEarnsMorePerDollar() public {
        uint256 a = _addBase(TOL, 100e18);
        vm.warp(block.timestamp + 15 days);
        uint256 b = _addBase(TOL, 100e18);
        vm.warp(block.timestamp + 600); // b matures; a is 15d + 600s old

        _swapQuoteForBase(10500e18); // 100e18 base: half the tier

        IPool.Position memory pa = pool.getPosition(a);
        IPool.Position memory pb = pool.getPosition(b);
        uint256 usedA = 100e18 - pa.baseAmount;
        uint256 usedB = 100e18 - pb.baseAmount;
        assertGt(usedA, usedB);
        assertApproxEqRel((usedA * 1e18) / usedB, 1.25e18, 0.02e18);
    }

    // Goal 3 (structural, unchanged by the weighting): a tighter tolerance is
    // an earlier tier, so it sees the flow first no matter how much bigger
    // the wide-tolerance position is.
    function testTighterToleranceStillFillsFirst() public {
        uint256 tight = _addBase(1000000, 100e18); // 1% tolerance, small
        uint256 wide = _addBase(TOL, 300e18); // 5% tolerance, 3x bigger
        vm.warp(block.timestamp + 600); // both mature

        _swapQuoteForBase(5050e18); // 50e18 base at the TIGHT bound (101 quote/base)

        IPool.Position memory pt = pool.getPosition(tight);
        IPool.Position memory pw = pool.getPosition(wide);
        assertApproxEqRel(100e18 - pt.baseAmount, 50e18, 0.01e18);
        assertEq(pw.baseAmount, 300e18);
    }
}
