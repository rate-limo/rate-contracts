// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8;

import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {IPool} from "../../src/swap/interfaces/IPool.sol";

contract SwapTest is PoolBaseSetup {
    uint256 positionId;

    function setUp() public override {
        super.setUp();
        // Position brackets the pair's listing price (100e8, set in PoolBaseSetup.setUp)
        // with a generous slippage tolerance so it's trivially in-range and willing to
        // trade at any price a full-fill test would compute. 5% sits comfortably inside
        // PoolBaseSetup's 10% admin spread (Step 0) so a full match can actually occur.
        vm.prank(lp1);
        token1.approve(address(pool), 10000e18);
        vm.prank(lp1);
        token2.approve(address(pool), 10000e18);
        vm.prank(positionManager);
        positionId = pool.addLiquidity(50e8, 150e8, 5000000, 1000e18, 1000e18, lp1);
    }

    function testFullFillQuoteToBaseSwap() public {
        vm.prank(trader1);
        token2.approve(address(pool), 100e18);

        uint256 traderBaseBefore = token1.balanceOf(trader1);
        uint256 traderQuoteBefore = token2.balanceOf(trader1);

        // Independently compute the expected output the same way the pre-fee-deduction
        // arithmetic works, so this assertion is a real cross-check rather than tautological
        // against amountOut's own definition (Pool.swap now *measures* amountOut as a
        // balance delta on trader1 -- see design.md §4.6 -- so asserting
        // token1.balanceOf(trader1) == traderBaseBefore + amountOut alone would trivially
        // always hold and catch nothing).
        uint256 boundPrice = (100e8 * (1e8 + 5000000)) / 1e8; // marketPrice * (1 + position's slippageLimit)
        uint32 takerFeeRate = matchingEngine.feeOf(address(token1), address(token2), trader1, false);
        uint256 grossOut = book.convert(boundPrice, 100e18, false); // quote->base: isBid=false
        uint256 expectedAmountOut = grossOut - (grossOut * takerFeeRate) / matchingEngine.DENOM();

        vm.prank(trader1);
        (uint256 amountOut, uint256 leftoverIn,) = pool.swap(100e18, true, trader1, false);

        assertEq(amountOut, expectedAmountOut);
        assertGt(amountOut, 0);
        assertEq(leftoverIn, 0);
        assertEq(token1.balanceOf(trader1), traderBaseBefore + amountOut);
        assertEq(token2.balanceOf(trader1), traderQuoteBefore - 100e18);
    }

    function testFullFillBaseToQuoteSwap() public {
        vm.prank(trader1);
        token1.approve(address(pool), 5e18);

        uint256 traderBaseBefore = token1.balanceOf(trader1);
        uint256 traderQuoteBefore = token2.balanceOf(trader1);

        // Same independent cross-check as the quote->base test above, mirrored for this
        // direction (see that test's comment for why this assertion is load-bearing).
        uint256 boundPrice = (100e8 * (1e8 - 5000000)) / 1e8; // marketPrice * (1 - position's slippageLimit)
        uint32 takerFeeRate = matchingEngine.feeOf(address(token1), address(token2), trader1, false);
        uint256 grossOut = book.convert(boundPrice, 5e18, true); // base->quote: isBid=true
        uint256 expectedAmountOut = grossOut - (grossOut * takerFeeRate) / matchingEngine.DENOM();

        vm.prank(trader1);
        (uint256 amountOut, uint256 leftoverIn,) = pool.swap(5e18, false, trader1, false);

        assertEq(amountOut, expectedAmountOut);
        assertGt(amountOut, 0);
        assertEq(leftoverIn, 0);
        assertEq(token1.balanceOf(trader1), traderBaseBefore - 5e18);
        assertEq(token2.balanceOf(trader1), traderQuoteBefore + amountOut);
    }

    function testSwapRevertsWhenNoPositionInRange() public {
        // Move price far outside the only position's [50e8, 150e8] range by updating lmp
        // via a matched trade at an out-of-range price first is complex to set up directly;
        // instead cover NoLiquidityInRange by removing the only position's liquidity first.
        vm.prank(positionManager);
        pool.removeLiquidity(positionId, 1000e18, 1000e18, lp1);

        vm.prank(trader1);
        token2.approve(address(pool), 100e18);
        vm.prank(trader1);
        vm.expectRevert(); // exact NoLiquidityInRange(marketPrice) selector; price value asserted loosely here
        pool.swap(100e18, true, trader1, false);
    }

    function testSwapCreditsPrincipalAndFeeToContributingPosition() public {
        matchingEngine.setPoolFeeShare(50000000); // 50% in DENOM=1e8 terms

        IPool.Position memory before = pool.getPosition(positionId);

        // Independently compute the expected principal/fee split via the same primitives
        // Pool.swap uses internally, but as a separate call path -- a loose assertGt/assertLt
        // here previously passed even when an earlier version of this task's implementation
        // double-credited poolShareOfFee (once folded into principal via
        // lpPrincipalReceived, again separately via creditFee -- see the comment at that
        // line in Step 3). An exact conservation check is what actually catches that class
        // of defect; a nonzero-only check does not.
        // There is no maker fee on the LP leg any more (see Pool._settleDirect), so
        // principal is the FULL bound-priced proceeds. A position's fee income now comes
        // solely from the taker fee's poolFeeShare, which _payOut credits on the OUTPUT
        // side -- base here, since isBaseFee == quoteToBase.
        uint256 boundPrice = (100e8 * (1e8 + 5000000)) / 1e8;
        uint256 matchedLpAmount = book.convert(boundPrice, 100e18, false); // quote->base, full fill
        uint256 expectedPrincipal = book.convert(boundPrice, matchedLpAmount, true); // base->quote
        uint32 takerFeeRate = matchingEngine.feeOf(address(token1), address(token2), trader1, false);
        uint256 takerFee = (matchedLpAmount * takerFeeRate) / matchingEngine.DENOM();
        uint256 expectedPoolShareOfFee = (takerFee * matchingEngine.poolFeeShare()) / matchingEngine.DENOM();

        // Settlement credits the pool's MEASURED proceeds (balance delta), not a
        // bound-priced reconstruction -- the engine's per-fill floored fee math can pay a
        // few wei more than the one-shot reconstruction above, and that surplus belongs to
        // the position, not stranded in the pool. Measure what the pool actually keeps:
        // across the whole swap() call its quote delta is exactly the LP leg's payout
        // (the swapper's 100e18 passes through: pulled in, then pulled out by the engine).
        uint256 poolQuoteBefore = token2.balanceOf(address(pool));

        vm.prank(trader1);
        token2.approve(address(pool), 100e18);
        vm.prank(trader1);
        pool.swap(100e18, true, trader1, false);

        uint256 actualProceeds = token2.balanceOf(address(pool)) - poolQuoteBefore;

        IPool.Position memory afterSwap = pool.getPosition(positionId);
        // Position sold base (quoteToBase=true -> LP leg limitSell's base), so baseAmount
        // must have decreased and quoteAmount (principal received back) must have increased.
        assertLt(afterSwap.baseAmount, before.baseAmount);
        // The reconstruction brackets the credit tightly from below: the engine never pays
        // less than the bound-priced amount, and per-fill rounding surplus stays small.
        assertGe(afterSwap.quoteAmount, before.quoteAmount + expectedPrincipal);
        assertApproxEqAbs(afterSwap.quoteAmount, before.quoteAmount + expectedPrincipal, 1000);
        // No maker fee means no rebate on the input side at all.
        assertEq(afterSwap.feeOwedQuote, 0, "the maker-side rebate must be gone");
        // With poolFeeShare > 0 and this being the sole contributing position, its fee
        // income is the taker fee's share, credited on the output (base) side.
        assertGt(afterSwap.feeOwedBase, 0);
        assertApproxEqAbs(afterSwap.feeOwedBase, expectedPoolShareOfFee, 1000);
        // Conservation, EXACT and against measured money: every quote token the pool took
        // in is credited to this position as principal -- nothing is split off to feeTo on
        // this leg and nothing is stranded. This is the check that catches both the
        // double-credit and the proceeds-stranding bug classes.
        assertEq(afterSwap.quoteAmount - before.quoteAmount, actualProceeds);
    }

    function testPartialFillRefundsLeftoverByDefault() public {
        // Shrink the position's available base so a large quote input can't be fully absorbed.
        vm.prank(positionManager);
        pool.removeLiquidity(positionId, 995e18, 0, lp1); // leaves 5e18 base available

        vm.prank(trader1);
        token2.approve(address(pool), 1000e18);

        uint256 traderQuoteBefore = token2.balanceOf(trader1);

        vm.prank(trader1);
        (uint256 amountOut, uint256 leftoverIn,) = pool.swap(1000e18, true, trader1, false);

        assertGt(amountOut, 0);
        assertGt(leftoverIn, 0);
        // Full input pulled in, but leftover refunded back out -- net spend is amountIn - leftoverIn.
        assertEq(token2.balanceOf(trader1), traderQuoteBefore - (1000e18 - leftoverIn));
    }

    function testOptInRestingLeftoverPlacesSwapperOwnedOrder() public {
        vm.prank(positionManager);
        pool.removeLiquidity(positionId, 995e18, 0, lp1);

        vm.prank(trader1);
        token2.approve(address(pool), 1000e18);

        vm.prank(trader1);
        (, uint256 leftoverIn,) = pool.swap(1000e18, true, trader1, true);
        // leftoverIn is read from recipient's own balance delta (design.md §4.6); a resting
        // remainder's tokens move into the exchange's escrow (owned by trader1 as a resting
        // order), never back into trader1's wallet, so there is nothing for a balance delta
        // to observe here -- leftoverIn == 0 in this mode is the correct, documented
        // consequence of that design, not a sign the swap fully matched. The resting order
        // itself (checked below) is the real, meaningful verification for this test.
        assertEq(leftoverIn, 0);

        // trader1 should now own a resting bid order for the leftover amount.
        (uint256 bidHead, ) = matchingEngine.heads(address(token1), address(token2));
        assertGt(bidHead, 0);
    }

    function testPartialFillStillSettlesMatchedPortionToPosition() public {
        vm.prank(positionManager);
        pool.removeLiquidity(positionId, 995e18, 0, lp1); // leaves 5e18 base available

        IPool.Position memory before = pool.getPosition(positionId);

        vm.prank(trader1);
        token2.approve(address(pool), 1000e18);
        vm.prank(trader1);
        pool.swap(1000e18, true, trader1, false);

        IPool.Position memory afterSwap = pool.getPosition(positionId);
        // assertLe(before.baseAmount - afterSwap.baseAmount, before.baseAmount) was here --
        // dropped as a tautology: baseAmount is a uint256 that only ever decreases (Solidity
        // 0.8 reverts on underflow rather than wrapping), so that difference is unconditionally
        // <= before.baseAmount for ANY legal decrease, including a hypothetical "matched too
        // much" bug -- which would revert on underflow before this assertion is ever reached,
        // not produce a value it could catch. Replaced with exact values, independently
        // computed the same way testSwapCreditsPrincipalAndFeeToContributingPosition does:
        // the position had exactly 5e18 base available (only this position exists, no other
        // contributors), and the swapper's 1000e18 quote budget vastly exceeds what's needed
        // to buy it (~525e18 quote worth), so the LP leg's entire 5e18 gets consumed --
        // matchedLpAmount is exactly 5e18, not merely "at most" it.
        assertEq(afterSwap.baseAmount, 0);
        uint256 boundPrice = (100e8 * (1e8 + 5000000)) / 1e8;
        // Credited in full -- no maker fee on this leg (see Pool._settleDirect).
        uint256 grossLpProceeds = book.convert(boundPrice, before.baseAmount, true); // base->quote
        assertEq(afterSwap.quoteAmount, before.quoteAmount + grossLpProceeds);
    }

    function testSwapSelectsFromCompactedActiveSetAfterRetirement() public {
        // Add a second position, then fully drain the FIRST (setUp's) so it retires and
        // activeIds swap-and-pops -- the surviving position now lives at array slot 0,
        // not the slot it was pushed to. The swap must still find and use it.
        vm.prank(positionManager);
        uint256 secondId = pool.addLiquidity(50e8, 150e8, 5000000, 500e18, 500e18, lp1);

        vm.prank(positionManager);
        pool.removeLiquidity(positionId, 1000e18, 1000e18, lp1);
        assertEq(pool.activePositionsLength(), 1);

        vm.prank(trader1);
        token2.approve(address(pool), 100e18);
        vm.prank(trader1);
        (uint256 amountOut,,) = pool.swap(100e18, true, trader1, false);

        assertGt(amountOut, 0);
        IPool.Position memory p = pool.getPosition(secondId);
        assertLt(p.baseAmount, 500e18); // the survivor is the position that supplied the swap
    }

    function testSwapRetiresFullyConsumedZeroCreditPosition() public {
        matchingEngine.setPoolFeeShare(50000000); // 50% in DENOM=1e8 terms

        // 1-wei quote-only dust position alongside setUp's 1000e18/1000e18 one. See the
        // plan's Task 3 header for the arithmetic: in the base->quote direction a full
        // match drains its 1 wei with zero received-credit and zero fee share, leaving it
        // economically dead inside the swap itself -- the case the _settleLpLeg sweep
        // (and nothing else) retires.
        vm.prank(positionManager);
        uint256 dustId = pool.addLiquidity(50e8, 150e8, 5000000, 0, 1, lp1);
        assertEq(pool.activePositionsLength(), 2);

        // Sell enough base to consume the ENTIRE assembled quote (1000e18 + 1 wei): at
        // boundPrice = 95e8 that's ~10.53e18 base; 12e18 gives comfortable headroom, and
        // the unmatched remainder refunds to trader1 (isMaker=false).
        vm.prank(trader1);
        token1.approve(address(pool), 12e18);
        vm.prank(trader1);
        pool.swap(12e18, false, trader1, false);

        IPool.Position memory dust = pool.getPosition(dustId);
        assertFalse(dust.active);
        assertEq(dust.quoteAmount, 0);
        assertEq(dust.baseAmount, 0);
        assertEq(dust.feeOwedBase, 0);
        // Both fee fields must be zero for the position to retire: a 1-wei contributor's
        // share of the taker fee floors to nothing, which is what leaves it dead.
        assertEq(dust.feeOwedQuote, 0);
        assertEq(pool.activePositionsLength(), 1);

        // Fee crediting must still land on the surviving contributor -- proves the sweep
        // runs AFTER creditFee (sweep-before-credit would credit fees to a retired id,
        // stranding them behind the PositionDoesNotExist gate).
        //
        // Fee income is now the taker fee's share only, credited by _payOut on the OUTPUT
        // side: isBaseFee == quoteToBase, which is false here (base->quote), so it lands on
        // quote. Previously this read feeOwedBase, which was the maker-fee rebate's
        // !quoteToBase convention -- and that rebate no longer exists.
        IPool.Position memory big = pool.getPosition(positionId);
        assertTrue(big.active);
        assertGt(big.feeOwedQuote, 0);
        assertEq(big.feeOwedBase, 0);
    }
}
