// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {PositionManager} from "../../src/swap/PositionManager.sol";
import {IPositionManager} from "../../src/swap/interfaces/IPositionManager.sol";
import {Pool} from "../../src/swap/Pool.sol";
import {MockBase} from "../../src/mock/MockBase.sol";
import {MockQuote} from "../../src/mock/MockQuote.sol";

contract PositionManagerRemoveTest is PoolBaseSetup {
    PositionManager pm;
    Pool pmPool;
    MockBase token3;
    MockQuote token4;
    uint256 tokenId;

    function setUp() public override {
        super.setUp();
        // Same reasoning as Task 12/13: needs a freshly-listed pair, not token1/token2.
        pm = new PositionManager();
        pm.initialize("ipfs://iter-positions/{id}.json");
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

    function testRemoveLiquidityThenBurnSucceeds() public {
        vm.prank(lp1);
        pm.removeLiquidity(tokenId, 500e18, 500e18, lp1);

        vm.prank(lp1);
        pm.burn(tokenId);

        // ERC1155 has no per-id owner and doesn't revert on a burned/never-minted id --
        // a burned position just reads back as a zero balance.
        assertEq(pm.balanceOf(lp1, tokenId), 0);
    }

    function testBurnRevertsIfPositionNotEmpty() public {
        vm.prank(lp1);
        vm.expectRevert(abi.encodeWithSelector(IPositionManager.PositionNotEmpty.selector, tokenId));
        pm.burn(tokenId);
    }

    function testCollectRoutesThroughToPool() public {
        vm.prank(lp1);
        (uint256 baseFee, uint256 quoteFee) = pm.collect(tokenId, lp1);
        assertEq(baseFee, 0);
        assertEq(quoteFee, 0);
    }
}
