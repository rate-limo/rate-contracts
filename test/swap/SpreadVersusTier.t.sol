// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {SwapRouter} from "../../src/swap/SwapRouter.sol";
import {ISwapRouter} from "../../src/swap/interfaces/ISwapRouter.sol";
import {IOrderbook} from "../../src/exchange/interfaces/IOrderbook.sol";
contract SpreadVersusTierTest is PoolBaseSetup {
    SwapRouter router; ISwapRouter.RemainderConfig empty;
    function setUp() public override {
        super.setUp();
        router = new SwapRouter(address(poolFactory));
        matchingEngine.setSwapRouter(address(router));
        vm.prank(lp1); token1.approve(address(pool), 10000e18);
        vm.prank(lp1); token2.approve(address(pool), 10000e18);
        vm.prank(positionManager);
        pool.addLiquidity(50e8, 150e8, 5000000, 1000e18, 1000e18, lp1);
    }
    function _p(address a,address b) private pure returns(address[] memory p){p=new address[](2);p[0]=a;p[1]=b;}
    function _lmp() private view returns(uint256){return IOrderbook(pool.orderbook()).lmp();}

    /// The premise of matched-price reporting is that `lmp` holds the price the swap
    /// actually traded at. That holds only while the pair's market spread is WIDER than the
    /// LP's slippage tier -- which the test fixture arranges (10% vs 5%) and the production
    /// defaults do not (dfltMkt* = 0.1% vs a 5% tier).
    ///
    /// At the production spread the rail clamps every pool fill, so lmp records 100.10 --
    /// a price nobody traded at -- while the swapper really paid 105.00. The feature
    /// degrades from "report the matched price" to "creep toward the pool's quote at the
    /// spread per block", which is the flow-independent ratchet the rail was meant to bound.
    ///
    /// Pinned as the current behaviour, not endorsed as correct: the spread and the tier
    /// slippage have to be reconciled at the config level, or the rail has to stop being
    /// the thing that decides the recorded price.
    function testRailOverridesTheMatchedPriceAtProductionSpread() public {
        matchingEngine.setSpread(address(token1), address(token2), 100000, 100000, true); // 0.1%
        vm.startPrank(trader1);
        token2.approve(address(router), 100e18);
        uint256 out = router.swap(
            ISwapRouter.SwapInput({
                path: _p(address(token2),address(token1)),
                amountIn: 100e18,
                minAmountOut: 0,
                recipient: trader1,
                remainderMode: ISwapRouter.RemainderMode.Refund,
                remainderConfig: empty
            })
        );
        vm.stopPrank();

        uint256 impliedFill = (100e18 * 1e8) / out;   // what the swapper actually paid
        assertApproxEqRel(impliedFill, 105e8, 0.002e18, "the swapper really paid the 5% tier bound");
        assertEq(_lmp(), 10010000000, "but lmp records 100.10 -- the rail, not the fill");
        assertTrue(_lmp() != 105e8, "so matched-price reporting does NOT hold in this config");
    }
}
