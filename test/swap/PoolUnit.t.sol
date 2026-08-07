// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8;

import {Test} from "forge-std/Test.sol";
import {Pool} from "../../src/swap/Pool.sol";
import {IPool} from "../../src/swap/interfaces/IPool.sol";
import {MockBase} from "../../src/mock/MockBase.sol";
import {MockQuote} from "../../src/mock/MockQuote.sol";

contract PoolUnitTest is Test {
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
    }

    function testAddLiquidityStoresPositionAndPullsTokens() public {
        vm.prank(lp);
        base.approve(address(pool), 100e18);
        vm.prank(lp);
        quote.approve(address(pool), 200e18);

        vm.prank(positionManager);
        uint256 positionId = pool.addLiquidity(70e8, 130e8, 500000, 100e18, 200e18, lp);

        assertEq(positionId, 1);
        IPool.Position memory p = pool.getPosition(positionId);
        assertEq(p.minPrice, 70e8);
        assertEq(p.maxPrice, 130e8);
        assertEq(p.slippageLimit, 500000);
        assertEq(p.baseAmount, 100e18);
        assertEq(p.quoteAmount, 200e18);
        assertTrue(p.active);
        assertEq(base.balanceOf(address(pool)), 100e18);
        assertEq(quote.balanceOf(address(pool)), 200e18);
    }

    function testAddLiquidityRevertsWhenNotCalledByPositionManager() public {
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(IPool.OnlyPositionManager.selector, lp, positionManager));
        pool.addLiquidity(70e8, 130e8, 500000, 0, 0, lp);
    }
}
