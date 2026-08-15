pragma solidity >=0.8;

import {MockToken} from "../../../src/mock/MockToken.sol";
import {MockBase} from "../../../src/mock/MockBase.sol";
import {MockQuote} from "../../../src/mock/MockQuote.sol";
import {MockBTC} from "../../../src/mock/MockBTC.sol";
import {ErrToken} from "../../../src/mock/MockTokenOver18Decimals.sol";
import {Utils} from "../../utils/Utils.sol";
import {MatchingEngine} from "../../../src/exchange/MatchingEngine.sol";
import {OrderbookFactory} from "../../../src/exchange/orderbooks/OrderbookFactory.sol";
import {Orderbook} from "../../../src/exchange/orderbooks/Orderbook.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {IOrderbookFactory} from "../../../src/exchange/interfaces/IOrderbookFactory.sol";
import {WETH9} from "../../../src/mock/WETH9.sol";
import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {console} from "forge-std/console.sol";
import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";

contract GetterTest is BaseSetup {
    function testGetPrices() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(token2), 100000000, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        vm.prank(booker);
        book = Orderbook(payable(orderbookFactory.getPair(address(token1), address(token2))));
        vm.prank(trader1);
        // placeBid or placeAsk two of them is using the _insertId function it will revert
        // because the program will enter the "if (amount > self.orders[head].depositAmount)."
        // statement, and eventually, it will cause an infinite loop.
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 500000000,
                amount: 10,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );

        vm.prank(trader1);
        //vm.expectRevert("OutOfGas");
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 100000000,
                amount: 10,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );

        vm.prank(trader1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 90000000,
                amount: 10,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );

        vm.prank(trader1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 500000000,
                amount: 10,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );
    }

    function testGetPriceInsertion() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(token2), 100000000000, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        vm.prank(booker);
        book = Orderbook(payable(orderbookFactory.getPair(address(token1), address(token2))));
        vm.prank(trader1);
        // placeBid or placeAsk two of them is using the _insertId function it will revert
        // because the program will enter the "if (amount > self.orders[head].depositAmount)."
        // statement, and eventually, it will cause an infinite loop.
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 100000000000,
                amount: 10,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        vm.prank(trader1);
        //vm.expectRevert("OutOfGas");
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 100200000000,
                amount: 10,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        vm.prank(trader1);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 100100000000,
                amount: 10,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );
        vm.prank(trader1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 99800000000,
                amount: 998,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );
        vm.prank(trader1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 99900000000,
                amount: 999,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );
        vm.prank(trader1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 99700000000,
                amount: 997,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );
    }

    function testGetOrders() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(token2), 100000000, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        vm.prank(booker);

        book = Orderbook(payable(orderbookFactory.getPair(address(token1), address(token2))));
        vm.prank(trader1);
        // placeBid or placeAsk two of them is using the _insertId function it will revert
        // because the program will enter the "if (amount > self.orders[head].depositAmount)."
        // statement, and eventually, it will cause an infinite loop.
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 500000000,
                amount: 10,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        vm.prank(trader1);
        //vm.expectRevert("OutOfGas");
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 100000000,
                amount: 10,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        vm.prank(trader1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 500000000,
                amount: 10,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );
    }

    function testGetAskHead() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(token2), 100000000, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        vm.prank(trader1);
        // placeBid or placeAsk two of them is using the _insertId function it will revert
        // because the program will enter the "if (amount > self.orders[head].depositAmount)."
        // statement, and eventually, it will cause an infinite loop.
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 500000000,
                amount: 10,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        vm.prank(trader1);
        //vm.expectRevert("OutOfGas");
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 100000000,
                amount: 10,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        console.log("Ask Head:");
        book = Orderbook(payable(orderbookFactory.getPair(address(token1), address(token2))));
        console.log(book.askHead());
    }

    function testGetOrderInsertion() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(token2), 100000000, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        vm.prank(trader1);
        // placeBid or placeAsk two of them is using the _insertId function it will revert
        // because the program will enter the "if (amount > self.orders[head].depositAmount)."
        // statement, and eventually, it will cause an infinite loop.
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 100000000,
                amount: 10,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        vm.prank(trader1);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 100000000,
                amount: 10,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        vm.prank(trader1);
        //vm.expectRevert("OutOfGas");
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 100000000,
                amount: 5,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        vm.prank(trader1);
        //vm.expectRevert("OutOfGas");
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 100000000,
                amount: 8,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        book = Orderbook(payable(orderbookFactory.getPair(address(token1), address(token2))));
    }
}
