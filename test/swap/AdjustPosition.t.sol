// contracts/test/swap/AdjustPosition.t.sol
pragma solidity >=0.8;

import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {PositionManager} from "../../src/swap/PositionManager.sol";
import {IPool} from "../../src/swap/interfaces/IPool.sol";
import {Pool} from "../../src/swap/Pool.sol";
import {MockBase} from "../../src/mock/MockBase.sol";
import {MockQuote} from "../../src/mock/MockQuote.sol";

contract AdjustPositionTest is PoolBaseSetup {
    PositionManager pm;
    Pool pmPool;
    MockBase token3;
    MockQuote token4;
    uint256 tokenId;

    function setUp() public override {
        super.setUp();
        // Same reasoning as Task 12's PositionManagerAddLiquidityTest: PoolBaseSetup's
        // token1/token2 pair was already listed with the 0xBEEF placeholder positionManager,
        // so exercising the real PositionManager needs a freshly-listed pair.
        pm = new PositionManager();
        pm.initialize("ipfs://standard-swap-positions/{id}.json");
        pm.setPoolFactory(address(poolFactory));
        poolFactory.setPositionManager(address(pm));

        token3 = new MockBase("Base2", "BASE2");
        token4 = new MockQuote("Quote2", "QUOTE2");
        token3.mint(lp1, 10000e18);
        token4.mint(lp1, 10000e18);

        matchingEngine.addPair(address(token3), address(token4), 100e8, 1, address(token3), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        pmPool = Pool(poolFactory.getPool(address(token3), address(token4)));

        vm.prank(lp1);
        token3.approve(address(pmPool), 1000e18);
        vm.prank(lp1);
        token4.approve(address(pmPool), 1000e18);
        vm.prank(lp1);
        tokenId = pm.addLiquidity(address(pmPool), 80e8, 120e8, 1000000, 500e18, 500e18);
    }

    function testAdjustPositionChangesRangeKeepsTokenId() public {
        (, uint256 oldPositionId) = pm.tokenPosition(tokenId);

        vm.prank(lp1);
        token3.approve(address(pm), 200e18);
        vm.prank(lp1);
        token4.approve(address(pm), 200e18);

        vm.prank(lp1);
        pm.adjustPosition(tokenId, 60e8, 140e8, 2000000, 700e18, 700e18);

        assertEq(pm.balanceOf(lp1, tokenId), 1); // same position id survives
        (, uint256 newPositionId) = pm.tokenPosition(tokenId);

        IPool.Position memory oldP = pmPool.getPosition(oldPositionId);
        assertEq(oldP.baseAmount, 0);
        assertEq(oldP.quoteAmount, 0);

        IPool.Position memory newP = pmPool.getPosition(newPositionId);
        assertEq(newP.minPrice, 60e8);
        assertEq(newP.maxPrice, 140e8);
        assertEq(newP.baseAmount, 700e18);
        assertEq(newP.quoteAmount, 700e18);
    }

    function testAdjustPositionRevertsForNonOwner() public {
        vm.prank(trader1);
        vm.expectRevert();
        pm.adjustPosition(tokenId, 60e8, 140e8, 2000000, 700e18, 700e18);
    }

    function testAdjustPositionShrinkRefundsExcessToOwner() public {
        // The old position holds 500e18/500e18 (setUp). Shrinking to 200e18/200e18 must
        // refund the 300e18/300e18 excess to lp1, not strand it inside PositionManager --
        // an earlier draft of adjustPosition only handled growing a position (pulling
        // MORE from the owner when newAmount > old), with no symmetric refund step for the
        // opposite case, silently trapping the excess in the contract forever.
        uint256 lp1BaseBefore = token3.balanceOf(lp1);
        uint256 lp1QuoteBefore = token4.balanceOf(lp1);

        vm.prank(lp1);
        pm.adjustPosition(tokenId, 80e8, 120e8, 1000000, 200e18, 200e18);

        assertEq(token3.balanceOf(lp1), lp1BaseBefore + 300e18);
        assertEq(token4.balanceOf(lp1), lp1QuoteBefore + 300e18);

        (, uint256 newPositionId) = pm.tokenPosition(tokenId);
        IPool.Position memory newP = pmPool.getPosition(newPositionId);
        assertEq(newP.baseAmount, 200e18);
        assertEq(newP.quoteAmount, 200e18);
    }

    function testAdjustPositionRetiresAbandonedPosition() public {
        // Invariant test (already passes once Task 1 lands -- adjustPosition's own
        // collect + full-drain removeLiquidity trigger retirement with no PM change):
        // the abandoned old id must retire, keeping the live count flat per adjust
        // instead of leaking one dead position per call.
        (, uint256 oldPositionId) = pm.tokenPosition(tokenId);
        assertEq(pmPool.activePositionsLength(), 1);

        vm.prank(lp1);
        token3.approve(address(pm), 200e18);
        vm.prank(lp1);
        token4.approve(address(pm), 200e18);
        vm.prank(lp1);
        pm.adjustPosition(tokenId, 60e8, 140e8, 2000000, 700e18, 700e18);

        assertFalse(pmPool.getPosition(oldPositionId).active);
        assertEq(pmPool.activePositionsLength(), 1); // old retired, new added -- flat
    }

    function testAdjustPositionWorksAfterFullDrain() public {
        // Fully drain via the PM -- with Task 1, the position retires (no fees pending;
        // no swaps have happened in this test).
        vm.prank(lp1);
        pm.removeLiquidity(tokenId, 500e18, 500e18, lp1);
        (, uint256 oldPositionId) = pm.tokenPosition(tokenId);
        assertFalse(pmPool.getPosition(oldPositionId).active);
        assertEq(pmPool.activePositionsLength(), 0);

        // Unguarded adjustPosition calls Pool.collect unconditionally, which reverts
        // PositionDoesNotExist on the retired id -- permanently bricking this token for
        // adjustment. The guard skips settlement of a retired position and just creates
        // the new one, pulling the full new amounts from the owner.
        vm.prank(lp1);
        token3.approve(address(pm), 100e18);
        vm.prank(lp1);
        token4.approve(address(pm), 100e18);
        vm.prank(lp1);
        pm.adjustPosition(tokenId, 60e8, 140e8, 2000000, 100e18, 100e18);

        (, uint256 newPositionId) = pm.tokenPosition(tokenId);
        IPool.Position memory p = pmPool.getPosition(newPositionId);
        assertTrue(p.active);
        assertEq(p.baseAmount, 100e18);
        assertEq(p.quoteAmount, 100e18);
        assertEq(pmPool.activePositionsLength(), 1);
    }

    function testSwapGasIsBoundedByLivePositionsNotHistory() public {
        // The actual I2 symptom: every adjustPosition used to leak one permanently-active
        // dead position that every future swap paid to scan (~20 passes x ~3 SLOADs each).
        // With retirement + the activeIds index, swap gas after 50 adjust cycles must
        // match swap gas after 1 -- bounded by LIVE positions, not history.
        //
        // The token3/token4 pair was listed inside THIS fixture's setUp, after
        // PoolBaseSetup's one-time warp -- give it its own TWAP history or pmPool.swap
        // reverts InsufficientHistory (same lesson as the swap plan's Task 16, point 1).
        vm.warp(block.timestamp + 600);

        token3.mint(trader1, 10000e18);
        token4.mint(trader1, 10000e18);
        vm.startPrank(trader1);
        token3.approve(address(pmPool), type(uint256).max);
        token4.approve(address(pmPool), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(lp1);
        token3.approve(address(pm), type(uint256).max);
        token4.approve(address(pm), type(uint256).max);
        vm.stopPrank();

        _adjustCycle();
        // Throwaway swap so both measurements below run against already-warm engine/
        // orderbook/oracle storage -- otherwise measurement 1 pays EIP-2929 cold-access
        // costs measurement 2 doesn't, and the comparison measures warmth, not the scan.
        _swapOnce();

        uint256 gasAfterOneCycle = _measureSwapGas();

        for (uint256 i = 0; i < 49; i++) {
            _adjustCycle();
        }
        // Same throwaway-swap treatment measurement 1 got: the last cycle minted a fresh
        // position whose storage the measured swap would otherwise touch cold. The old
        // engine-routed swap was expensive enough (~700k) to hide this asymmetry inside
        // the 5% band; direct settlement is ~10x cheaper, so the band now measures the
        // scan only if both sides are equally warm.
        _swapOnce();

        uint256 gasAfterFiftyCycles = _measureSwapGas();

        // 5% relative tolerance: on the pre-fix code the 49 extra dead positions cost the
        // scan roughly 49 x 20 passes x ~3 warm SLOADs (~300k gas), far beyond 5% of a
        // swap; on the fixed code the live set is identical in both measurements.
        assertApproxEqRel(gasAfterFiftyCycles, gasAfterOneCycle, 0.05e18);
    }

    function _adjustCycle() internal {
        // Same range/amounts every cycle: each adjust re-normalizes the position to
        // 500e18/500e18, pulling any shortfall from lp1 and refunding any excess, so
        // every measured swap runs against an identically-shaped live position.
        vm.prank(lp1);
        pm.adjustPosition(tokenId, 80e8, 120e8, 1000000, 500e18, 500e18);
    }

    function _swapOnce() internal {
        vm.prank(trader1);
        pmPool.swap(10e18, true, trader1, false);
    }

    function _measureSwapGas() internal returns (uint256) {
        vm.prank(trader1);
        uint256 before = gasleft();
        pmPool.swap(10e18, true, trader1, false);
        return before - gasleft();
    }
}
