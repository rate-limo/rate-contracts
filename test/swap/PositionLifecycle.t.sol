// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8;

import {Test} from "forge-std/Test.sol";
import {Pool} from "../../src/swap/Pool.sol";
import {IPool} from "../../src/swap/interfaces/IPool.sol";
import {MockBase} from "../../src/mock/MockBase.sol";
import {MockQuote} from "../../src/mock/MockQuote.sol";

contract PositionLifecycleTest is Test {
    Pool pool;
    MockBase base;
    MockQuote quote;
    address positionManager = address(0xBEEF);
    address engine = address(0xE1);
    address orderbook = address(0xB0);
    address lp = address(0xA1);

    function setUp() public {
        base = new MockBase("Base", "BASE");
        quote = new MockQuote("Quote", "QUOTE");
        pool = new Pool();
        pool.initialize(1, address(base), address(quote), orderbook, engine, positionManager);
        base.mint(lp, 1000e18);
        quote.mint(lp, 1000e18);
        vm.prank(lp);
        base.approve(address(pool), type(uint256).max);
        vm.prank(lp);
        quote.approve(address(pool), type(uint256).max);
    }

    function _add(uint256 baseAmt, uint256 quoteAmt) internal returns (uint256 id) {
        vm.prank(positionManager);
        id = pool.addLiquidity(70e8, 130e8, 500000, baseAmt, quoteAmt, lp);
    }

    function testAddLiquidityTracksActiveIds() public {
        _add(10e18, 10e18);
        _add(10e18, 10e18);
        _add(10e18, 10e18);
        assertEq(pool.activePositionsLength(), 3);
    }

    function testFullDrainRetiresPosition() public {
        uint256 id1 = _add(10e18, 10e18);
        uint256 id2 = _add(10e18, 10e18);

        vm.expectEmit(true, false, false, false);
        emit IPool.PositionDeactivated(id1);
        vm.prank(positionManager);
        pool.removeLiquidity(id1, 10e18, 10e18, lp);

        assertFalse(pool.getPosition(id1).active);
        assertTrue(pool.getPosition(id2).active);
        assertEq(pool.activePositionsLength(), 1);
    }

    function testPartialDrainKeepsActive() public {
        uint256 id = _add(10e18, 10e18);
        vm.prank(positionManager);
        pool.removeLiquidity(id, 10e18, 0, lp);
        assertTrue(pool.getPosition(id).active);
        assertEq(pool.activePositionsLength(), 1);
    }

    function testDrainWithPendingFeesStaysActiveUntilCollect() public {
        uint256 id = _add(10e18, 10e18);

        // Simulate swap-settlement fee crediting: creditFee is self-only-callable
        // (Pool.swap calls this.creditFee(...)), so impersonate the pool itself. The pool
        // must also actually hold the owed quote for collect's transfer below.
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint256[] memory shares = new uint256[](1);
        shares[0] = 1;
        vm.prank(address(pool));
        pool.creditFee(ids, shares, false, 1e18);
        quote.mint(address(pool), 1e18);

        vm.prank(positionManager);
        pool.removeLiquidity(id, 10e18, 10e18, lp);
        assertTrue(pool.getPosition(id).active); // fees pending -> NOT retired
        assertEq(pool.activePositionsLength(), 1);

        vm.expectEmit(true, false, false, false);
        emit IPool.PositionDeactivated(id);
        vm.prank(positionManager);
        pool.collect(id, lp);
        assertFalse(pool.getPosition(id).active); // fees settled -> retired
        assertEq(pool.activePositionsLength(), 0);
    }

    function testRetiredPositionRevertsOnRemoveAndCollect() public {
        uint256 id = _add(10e18, 0);
        vm.prank(positionManager);
        pool.removeLiquidity(id, 10e18, 0, lp);
        assertFalse(pool.getPosition(id).active);

        vm.prank(positionManager);
        vm.expectRevert(abi.encodeWithSelector(IPool.PositionDoesNotExist.selector, id));
        pool.removeLiquidity(id, 0, 0, lp);

        vm.prank(positionManager);
        vm.expectRevert(abi.encodeWithSelector(IPool.PositionDoesNotExist.selector, id));
        pool.collect(id, lp);
    }

    function testSwapAndPopBookkeepingAcrossRetirements() public {
        uint256 id1 = _add(10e18, 10e18);
        uint256 id2 = _add(10e18, 10e18);
        uint256 id3 = _add(10e18, 10e18);

        // Retire the FIRST id: swap-and-pop moves id3 into slot 0.
        vm.prank(positionManager);
        pool.removeLiquidity(id1, 10e18, 10e18, lp);
        assertEq(pool.activePositionsLength(), 2);

        // Retire the MOVED id (id3): exercises the idxInActive[lastId] = idx rewrite --
        // if that bookkeeping is wrong, this pop removes the wrong element or reverts.
        vm.prank(positionManager);
        pool.removeLiquidity(id3, 10e18, 10e18, lp);
        assertEq(pool.activePositionsLength(), 1);
        assertTrue(pool.getPosition(id2).active);

        // Retire the ONLY remaining element, then verify the index still works for adds.
        vm.prank(positionManager);
        pool.removeLiquidity(id2, 10e18, 10e18, lp);
        assertEq(pool.activePositionsLength(), 0);

        uint256 id4 = _add(5e18, 5e18);
        assertTrue(pool.getPosition(id4).active);
        assertEq(pool.activePositionsLength(), 1);
    }
}
