pragma solidity >=0.8;

import {MockToken} from "../../../src/mock/MockToken.sol";
import {MockBase} from "../../../src/mock/MockBase.sol";
import {MockQuote} from "../../../src/mock/MockQuote.sol";
import {MockBTC} from "../../../src/mock/MockBTC.sol";
import {ErrToken} from "../../../src/mock/MockTokenOver18Decimals.sol";
import {Utils} from "../../utils/Utils.sol";
import {MatchingEngine} from "../../../src/exchange/MatchingEngine.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";
import {OrderbookFactory} from "../../../src/exchange/orderbooks/OrderbookFactory.sol";
import {Orderbook} from "../../../src/exchange/orderbooks/Orderbook.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {IOrderbookFactory} from "../../../src/exchange/interfaces/IOrderbookFactory.sol";
import {WETH9} from "../../../src/mock/WETH9.sol";
import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {console} from "forge-std/console.sol";
import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";

contract InitialTradeTest is BaseSetup {
    // edge cases on cancelling orders
    function testInitialSell() public {
        super.setUp();
        matchingEngine.addPair(address(weth), address(token2), 500000000, 0, address(weth), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        vm.prank(trader1);
        // placeBid or placeAsk two of them is using the _insertId function it will revert
        // because the program will enter the "if (amount > self.orders[head].depositAmount)."
        // statement, and eventually, it will cause an infinite loop.
        matchingEngine.createOrder{value: 1e4}(
            IMatchingEngine.CreateOrderInput({
                base: matchingEngine.WETH(),
                quote: address(token2),
                isBid: false,
                isLimit: true,
                orderId: 0,
                price: 500000000,
                amount: 1e4,
                n: 2,
                recipient: trader1,
                isMaker: true,
                slippageLimit: 0,
                deadline: 0
            })
        );
    }
}
