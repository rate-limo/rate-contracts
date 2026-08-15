import {PointFarmSetup} from "../PointFarmSetup.sol";
import {PrizePool} from "../PointFarmSetup.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";

contract PrizePoolTest is PointFarmSetup {
    function prizePoolSetup() internal {
        super.setUp();
        // make an event and multiplier
        vm.startPrank(trader1);
        pointFarm.createEvent(1000, 100000);
        pointFarm.setMultiplier(address(feeToken), address(stablecoin), false, 30000);
        pointFarm.setMultiplier(address(feeToken), address(stablecoin), true, 30000);
        vm.warp(10000);
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
        matchingEngine.limitSell(
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
        assert(pointBalance > 0);
        vm.stopPrank();
    }
}
