import {PointFarmSetup} from "../PointFarmSetup.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";

contract MintTest is PointFarmSetup {
    function mintSetUp() internal {
        super.setUp();

        // make an event
        vm.startPrank(trader1);
        pointFarm.createEvent(1000, 100000);
        vm.stopPrank();
    }

    // Trading without event will not mint points
    function testTradingWithoutEventWillNotMint() public {
        vm.startPrank(trader1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(feeToken),
                quote: address(stablecoin),
                price: 1000e8,
                amount: 100e18,
                isMaker: true,
                n: 2,
                recipient: address(trader1)
            })
        );
        uint256 pointBalance = point.balanceOf(trader1);
        assert(pointBalance == 0);
    }

    // Trading with event but without multiplier pair will not mint point to the user
    function testTradingWithEventWithoutMultiplierWillNotMint() public {
        mintSetUp();
        vm.startPrank(trader1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(feeToken),
                quote: address(stablecoin),
                price: 1000e8,
                amount: 100e18,
                isMaker: true,
                n: 2,
                recipient: address(trader1)
            })
        );
        uint256 pointBalance = point.balanceOf(trader1);
        assert(pointBalance == 0);
    }

    function testMarketBuyAndSellWithPoints() public {
        mintSetUp();
        vm.warp(10000);
        vm.startPrank(trader1);
        base.approve(address(matchingEngine), type(uint256).max);
        usdc.approve(address(matchingEngine), type(uint256).max);

        IMatchingEngine.OrderResult memory orderResult =
            matchingEngine.marketBuy(
                IMatchingEngine.MarketOrderInput({
                    base: address(base),
                    quote: address(usdc),
                    amount: 100000,
                    isMaker: true,
                    n: 5,
                    recipient: trader1,
                    slippageLimit: 200
                })
            );

        matchingEngine.cancelOrder(address(base), address(usdc), true, orderResult.id);

        matchingEngine.marketSell(
            IMatchingEngine.MarketOrderInput({
                base: address(base),
                quote: address(usdc),
                amount: 1e14,
                isMaker: true,
                n: 5,
                recipient: trader1,
                slippageLimit: 200
            })
        );
    }
}
