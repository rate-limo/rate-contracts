pragma solidity >=0.8;

import {MockOrderbook} from "../../../src/exchange/mocks/MockOrderbook.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {IOrderbookFactory} from "../../../src/exchange/interfaces/IOrderbookFactory.sol";
import {WETH9} from "../../../src/mock/WETH9.sol";
import {MockBaseSetup} from "../MockOrderbookBaseSetup.sol";
import {console} from "forge-std/console.sol";
import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";

contract DormantTest is MockBaseSetup {
    // if dormant order exists after circulating from the order count, the dormant order should be removed and new order should be placed
    function testDormantOrderOnBidSide() public {
        token1.approve(address(matchingEngine), 100000000000000000);
        token2.approve(address(matchingEngine), 100000000000000000);
        token1.mint(address(this), 1000000000000000000000000000000);
        token2.mint(address(this), 1000000000000000000000000000000);
        matchingEngine.addPair(address(token1), address(token2), 100000000, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        address pair = matchingEngine.getPair(address(token1), address(token2));
        MockOrderbook mockBook = MockOrderbook(payable(pair));
        mockBook.setOrderCount(true, 1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 100000000,
                amount: 100,
                isMaker: true,
                n: 1,
                recipient: address(trader1)
            })
        );
        mockBook.setOrderCount(true, 1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 100000000,
                amount: 1000,
                isMaker: true,
                n: 1,
                recipient: address(trader1)
            })
        );
    }

    function testDormantOrderDoesNotHarmOrderbook() public {
        token1.approve(address(matchingEngine), 100000000000000000);
        token2.approve(address(matchingEngine), 100000000000000000);
        token1.mint(address(this), 1000000000000000000000000000000);
        token2.mint(address(this), 1000000000000000000000000000000);
        matchingEngine.addPair(address(token1), address(token2), 100000000, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        address pair = matchingEngine.getPair(address(token1), address(token2));
        MockOrderbook mockBook = MockOrderbook(payable(pair));
        mockBook.setOrderCount(true, 1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 100000000,
                amount: 100,
                isMaker: true,
                n: 1,
                recipient: address(trader1)
            })
        );
        mockBook.setOrderCount(true, 1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 100000000,
                amount: 1000,
                isMaker: true,
                n: 1,
                recipient: address(trader1)
            })
        );
    }
}
