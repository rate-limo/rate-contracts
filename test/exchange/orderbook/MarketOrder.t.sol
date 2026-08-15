pragma solidity >=0.8;

import {MockToken} from "../../../src/mock/MockToken.sol";
import {MockBase} from "../../../src/mock/MockBase.sol";
import {MockQuote} from "../../../src/mock/MockQuote.sol";
import {MockUSDC} from "../../../src/mock/MockUSDC.sol";
import {MockBTC} from "../../../src/mock/MockBTC.sol";
import {ErrToken} from "../../../src/mock/MockTokenOver18Decimals.sol";
import {Utils} from "../../utils/Utils.sol";
import {MatchingEngine} from "../../../src/exchange/MatchingEngine.sol";
import {OrderbookFactory} from "../../../src/exchange/orderbooks/OrderbookFactory.sol";
import {IOrderbook} from "../../../src/exchange/interfaces/IOrderbook.sol";
import {Orderbook} from "../../../src/exchange/orderbooks/Orderbook.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {IOrderbookFactory} from "../../../src/exchange/interfaces/IOrderbookFactory.sol";
import {WETH9} from "../../../src/mock/WETH9.sol";
import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {console} from "forge-std/console.sol";
import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";

contract MarketOrderTest is BaseSetup {
    function testMarketBuyETH() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(weth), 1e8, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        console.log("weth balance");
        console.log(trader1.balance / 1e18);
        vm.prank(trader1);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(weth),
                price: 1e8,
                amount: 1e18,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );
        (uint256 bidHead, uint256 askHead) = matchingEngine.heads(address(token1), address(weth));
        console.log(bidHead, askHead);
        vm.prank(trader1);
        matchingEngine.createOrder{value: 1e18}(
            IMatchingEngine.CreateOrderInput({
                base: address(token1),
                quote: matchingEngine.WETH(),
                isBid: true,
                isLimit: false,
                orderId: 0,
                price: 0,
                amount: 1e18,
                n: 5,
                recipient: trader1,
                isMaker: true,
                slippageLimit: 2000000,
                deadline: 0
            })
        );
        vm.prank(trader1);
        token1.approve(address(matchingEngine), 10e18);
        vm.prank(trader1);
        matchingEngine.marketSell(
            IMatchingEngine.MarketOrderInput({
                base: address(token1),
                quote: address(weth),
                amount: 1e18,
                isMaker: true,
                n: 5,
                recipient: trader1,
                slippageLimit: 2000000
            })
        );
        console.log("weth balance");
        console.log(trader1.balance / 1e18);
    }

    function testMarketSellETH() public {
        super.setUp();
        matchingEngine.addPair(address(weth), address(token1), 1e8, 0, address(weth), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        console.log("weth balance");
        console.log(trader1.balance / 1e18);
        vm.prank(trader1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(weth),
                quote: address(token1),
                price: 1e8,
                amount: 1e18,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );
        vm.prank(trader1);
        matchingEngine.createOrder{value: 1e18}(
            IMatchingEngine.CreateOrderInput({
                base: matchingEngine.WETH(),
                quote: address(token1),
                isBid: false,
                isLimit: false,
                orderId: 0,
                price: 0,
                amount: 1e18,
                n: 5,
                recipient: trader1,
                isMaker: true,
                slippageLimit: 2000000,
                deadline: 0
            })
        );
        vm.prank(trader1);
        token1.approve(address(matchingEngine), 10e18);
        vm.prank(trader1);
        matchingEngine.marketBuy(
            IMatchingEngine.MarketOrderInput({
                base: address(weth),
                quote: address(token1),
                amount: 1e18,
                isMaker: true,
                n: 5,
                recipient: trader1,
                slippageLimit: 2000000
            })
        );
        console.log("weth balance");
        console.log(trader1.balance / 1e18);
    }

    function testCancelJammingOrderbook() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(token2), 1000e8, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        vm.prank(booker);

        book = Orderbook(payable(orderbookFactory.getPair(address(token1), address(token2))));

        vm.prank(trader1);
        token1.approve(address(matchingEngine), 1000000000000000000e18);

        // deposit 10000e18(9990e18 after fee) for buying token1 for 1000 token2 * amount
        vm.prank(trader1);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 1000e8,
                amount: 1000e18,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );

        vm.prank(trader1);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 1100e8,
                amount: 1000e18,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );

        vm.prank(trader1);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 1200e8,
                amount: 1000e18,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );

        vm.prank(trader1);
        matchingEngine.cancelOrder(address(token1), address(token2), false, 1);
        vm.prank(trader1);
        matchingEngine.cancelOrder(address(token1), address(token2), false, 2);
        ExchangeOrderbook.Order memory order = matchingEngine.getOrder(address(token1), address(token2), false, 3);
        console.log("Order id 3: ", order.owner, order.depositAmount);

        vm.prank(trader1);
        matchingEngine.marketBuy(
            IMatchingEngine.MarketOrderInput({
                base: address(token1),
                quote: address(token2), //1400e8,
                amount: 3400000e18,
                isMaker: true,
                n: 5,
                recipient: trader1,
                slippageLimit: 2000000
            })
        );

        console.log("Mkt Price: ", matchingEngine.mktPrice(address(token1), address(token2)));

        console.log("minRequired quote", matchingEngine.convert(address(token1), address(token2), 1, true));

        console.log("minRequired base", matchingEngine.convert(address(token1), address(token2), 1, false));
    }

    function _detMarketBuyMakePrice(address orderbook, uint256 bidHead, uint256 askHead, uint32 spread)
        internal
        view
        returns (uint256 price)
    {
        uint256 up;
        uint256 lmp = IOrderbook(orderbook).lmp();
        if (askHead == 0 && bidHead == 0) {
            // lmp must exist unless there has been no order in orderbook
            if (lmp != 0) {
                up = (lmp * (1e8 + spread)) / 1e8;
                return up;
            }
        } else if (askHead == 0 && bidHead != 0) {
            if (lmp != 0) {
                uint256 temp = (bidHead >= lmp ? bidHead : lmp);
                up = (temp * (1e8 + spread)) / 1e8;
                return up;
            }
            up = (bidHead * (1e8 + spread)) / 1e8;
            return up;
        } else if (askHead != 0 && bidHead == 0) {
            if (lmp != 0) {
                up = (lmp * (1e8 + spread)) / 1e8;
                return askHead >= up ? up : askHead;
            }
            return askHead;
        } else {
            if (lmp != 0) {
                uint256 temp = (bidHead >= lmp ? bidHead : lmp);
                up = (temp * (1e8 + spread)) / 1e8;
                return askHead >= up ? up : askHead;
            }
            return askHead;
        }
    }

    function _detMarketSellMakePrice(address orderbook, uint256 bidHead, uint256 askHead, uint32 spread)
        internal
        view
        returns (uint256 price)
    {
        uint256 down;
        uint256 lmp = IOrderbook(orderbook).lmp();
        if (askHead == 0 && bidHead == 0) {
            // lmp must exist unless there has been no order in orderbook
            if (lmp != 0) {
                down = (lmp * (1e8 - spread)) / 1e8;
                return down == 0 ? 1 : down;
            }
        } else if (askHead == 0 && bidHead != 0) {
            if (lmp != 0) {
                down = (lmp * (1e8 - spread)) / 1e8;
                down = down <= bidHead ? bidHead : down;
                return down == 0 ? 1 : down;
            }
            return bidHead;
        } else if (askHead != 0 && bidHead == 0) {
            if (lmp != 0) {
                uint256 temp = lmp <= askHead ? lmp : askHead;
                down = (temp * (1e8 - spread)) / 1e8;
                return down == 0 ? 1 : down;
            }
            down = (askHead * (1e8 - spread)) / 1e8;
            return down == 0 ? 1 : down;
        } else {
            if (lmp != 0) {
                uint256 temp = lmp <= askHead ? lmp : askHead;
                down = (temp * (1e8 - spread)) / 1e8;
                down = down <= bidHead ? bidHead : down;
                return down == 0 ? 1 : down;
            }
            return bidHead;
        }
    }

    function _setupVolatilityTest()
        internal
        returns (MockBase base, MockQuote quote, Orderbook book, uint256 mp, uint256 up, uint256 down)
    {
        super.setUp();
        base = new MockBase("Base Token", "BASE");
        quote = new MockQuote("Quote Token", "QUOTE");
        base.mint(trader1, type(uint256).max);
        quote.mint(trader1, type(uint256).max);
        // make a price in matching engine where 1 base = 1 quote with buy and sell order
        matchingEngine.addPair(address(base), address(quote), 1e8, 0, address(base), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        vm.startPrank(trader1);
        base.approve(address(matchingEngine), type(uint256).max);
        quote.approve(address(matchingEngine), type(uint256).max);
        // make last matched price
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e8,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e8,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        mp = matchingEngine.mktPrice(address(base), address(quote));
        up = (mp * (1e8 + 2000000)) / 1e8;
        down = (mp * (1e8 - 2000000)) / 1e8;
        return (base, quote, book, mp, up, down);
    }

    // On market buy, if askHead is higher than lmp + ranged price, order is made with lmp + ranged price.
    function testMarketBuyVolatilityUp1() public {
        (
            MockBase base,
            MockQuote quote,
            Orderbook book,
            uint256 _mp, // silence warning
            uint256 up,
            uint256 _down // silence warning
        ) = _setupVolatilityTest();
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e11,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        // get pair and price info
        book = Orderbook(payable(matchingEngine.getPair(address(base), address(quote))));
        (uint256 bidHead, uint256 askHead) = book.heads();
        // check askHead is higher than up
        assert(askHead > up);
        uint256 result = _detMarketBuyMakePrice(address(book), bidHead, askHead, 2000000);
        console.log("result: ", result);
        // check computed result
        assert(result == up);
        IMatchingEngine.OrderResult memory orderResult =
            matchingEngine.marketBuy(
                IMatchingEngine.MarketOrderInput({
                    base: address(base),
                    quote: address(quote),
                    amount: 1e8,
                    isMaker: true,
                    n: 5,
                    recipient: trader1,
                    slippageLimit: 2000000
                })
            );
        // check make price is equal to computed result
        console.log("make price: ", orderResult.makePrice);
        assert(orderResult.makePrice == result);
    }

    // On market buy, if bidHead is lower than lmp + ranged price, order is lmp + ranged price
    function testMarketBuyVolatilityUp2() public {
        (
            MockBase base,
            MockQuote quote,
            Orderbook book,
            uint256 _mp, /* silence warning */
            uint256 up,
            uint256 _down /* silence warning */
        ) = _setupVolatilityTest();
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e6,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        // get pair and price info
        // get pair and price info
        book = Orderbook(payable(matchingEngine.getPair(address(base), address(quote))));
        (uint256 bidHead, uint256 askHead) = book.heads();
        // check bidHead is lower than up
        assert(bidHead < up);
        uint256 result = _detMarketBuyMakePrice(address(book), bidHead, askHead, 2000000);
        console.log("result: ", result);
        // check computed result
        assert(result == up);
        IMatchingEngine.OrderResult memory orderResult =
            matchingEngine.marketBuy(
                IMatchingEngine.MarketOrderInput({
                    base: address(base),
                    quote: address(quote),
                    amount: 1e8,
                    isMaker: true,
                    n: 5,
                    recipient: trader1,
                    slippageLimit: 2000000
                })
            );
        // check make price is equal to computed result
        console.log("make price: ", orderResult.makePrice);
        assert(orderResult.makePrice == result);
    }

    // On market buy, if askHead is lower than lmp + ranged price, order is made with askHead
    function testMarketBuyVolatilityUp3() public {
        (MockBase base, MockQuote quote, Orderbook book, uint256 _mp, uint256 up, uint256 _down) =
            _setupVolatilityTest();
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e8 + 1,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        // get pair and price info
        // get pair and price info
        book = Orderbook(payable(matchingEngine.getPair(address(base), address(quote))));
        (uint256 bidHead, uint256 askHead) = book.heads();
        // check bidHead is lower than up
        assert(askHead < up);
        uint256 result = _detMarketBuyMakePrice(address(book), bidHead, askHead, 2000000);
        console.log("result: ", result);
        // check computed result
        assert(result == askHead);
        IMatchingEngine.OrderResult memory orderResult =
            matchingEngine.marketBuy(
                IMatchingEngine.MarketOrderInput({
                    base: address(base),
                    quote: address(quote),
                    amount: 1e8,
                    isMaker: true,
                    n: 5,
                    recipient: trader1,
                    slippageLimit: 2000000
                })
            );
        // check make price is equal to computed result
        console.log("make price: ", orderResult.makePrice);
        assert(orderResult.makePrice == result);
    }

    // On market buy, bidHead and askHead exists. if lmp + ranged price is higher than bidHead, and lmp + ranged price is lower than askHead, order is made in askHead.
    function testMarketBuyVolatilityUp4() public {
        (MockBase base, MockQuote quote, Orderbook book, uint256 _mp, uint256 up, uint256 _down) =
            _setupVolatilityTest();
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e6,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e8 + 1,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        // get pair and price info
        // get pair and price info
        book = Orderbook(payable(matchingEngine.getPair(address(base), address(quote))));
        (uint256 bidHead, uint256 askHead) = book.heads();
        // check bidHead is lower than up
        assert(askHead < up);
        uint256 result = _detMarketBuyMakePrice(address(book), bidHead, askHead, 2000000);
        console.log("result: ", result);
        // check computed result
        assert(result == askHead);
        IMatchingEngine.OrderResult memory orderResult =
            matchingEngine.marketBuy(
                IMatchingEngine.MarketOrderInput({
                    base: address(base),
                    quote: address(quote),
                    amount: 1e8,
                    isMaker: true,
                    n: 5,
                    recipient: trader1,
                    slippageLimit: 2000000
                })
            );
        // check make price is equal to computed result
        console.log("make price: ", orderResult.makePrice);
        assert(orderResult.makePrice == result);
    }

    function testMarketBuyVolatilityOnSlippageLimit() public {
        (
            MockBase base,
            MockQuote quote,
            Orderbook book,
            uint256 _mp, /* silence warning */
            uint256 up,
            uint256 _down /* silence warning */
        ) = _setupVolatilityTest();
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e6,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        // get pair and price info
        // get pair and price info
        book = Orderbook(payable(matchingEngine.getPair(address(base), address(quote))));
        (uint256 bidHead, uint256 askHead) = book.heads();
        // check bidHead is lower than up
        assert(bidHead < up);
        uint256 result = _detMarketBuyMakePrice(address(book), bidHead, askHead, 500000);
        console.log("result: ", result);
        // check computed result
        assert(result == 100500000);
        IMatchingEngine.OrderResult memory orderResult =
            matchingEngine.marketBuy(
                IMatchingEngine.MarketOrderInput({
                    base: address(base),
                    quote: address(quote),
                    amount: 1e8,
                    isMaker: true,
                    n: 5,
                    recipient: trader1,
                    slippageLimit: 500000
                })
            );
        // check make price is equal to computed result
        console.log("make price: ", orderResult.makePrice);
        assert(orderResult.makePrice == result);
    }

    function testMarketBuyVolatilityOnSlippageLimit2() public {
        (
            MockBase base,
            MockQuote quote,
            Orderbook book,
            uint256 _mp, /* silence warning */
            uint256 up,
            uint256 _down /* silence warning */
        ) = _setupVolatilityTest();
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e6,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        // get pair and price info
        // get pair and price info
        book = Orderbook(payable(matchingEngine.getPair(address(base), address(quote))));
        (uint256 bidHead, uint256 askHead) = book.heads();
        // check bidHead is lower than up
        assert(bidHead < up);
        uint256 result = _detMarketBuyMakePrice(address(book), bidHead, askHead, 2000000);
        console.log("result: ", result);
        // check computed result
        assert(result == up);
        IMatchingEngine.OrderResult memory orderResult =
            matchingEngine.marketBuy(
                IMatchingEngine.MarketOrderInput({
                    base: address(base),
                    quote: address(quote),
                    amount: 1e8,
                    isMaker: true,
                    n: 5,
                    recipient: trader1,
                    slippageLimit: 3000000
                })
            );
        // check make price is equal to computed result
        console.log("make price: ", orderResult.makePrice);
        assert(orderResult.makePrice == result);
    }

    // On market buy, if askHead is lower than lmp + ranged price, order is made with askHead
    function testMarketBuyVolatilityDown() public {
        (MockBase base, MockQuote quote, Orderbook book, uint256 mp, uint256 up, uint256 _down) = _setupVolatilityTest();
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: (mp * (1e8 + 100)) / 1e8,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        // get pair and price info
        book = Orderbook(payable(matchingEngine.getPair(address(base), address(quote))));
        (uint256 bidHead, uint256 askHead) = book.heads();
        // check askHead is lower than up
        assert(askHead < up);
        uint256 result = _detMarketBuyMakePrice(address(book), bidHead, askHead, 2000000);
        console.log("result: ", result);
        // check computed result
        assert(result == askHead);
        IMatchingEngine.OrderResult memory orderResult =
            matchingEngine.marketBuy(
                IMatchingEngine.MarketOrderInput({
                    base: address(base),
                    quote: address(quote),
                    amount: 1e8,
                    isMaker: true,
                    n: 5,
                    recipient: trader1,
                    slippageLimit: 2000000
                })
            );
        // check make price is equal to computed result
        console.log("make price: ", orderResult.makePrice);
        assert(orderResult.makePrice == result);
    }

    // On market sell, if bidHead is lower than lmp - ranged price, order is made with lmp - ranged price.
    function testMarketSellVolatilityDown1() public {
        (MockBase base, MockQuote quote, Orderbook book, uint256 _mp, uint256 _up, uint256 down) =
            _setupVolatilityTest();
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e6,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        // get pair and price info
        book = Orderbook(payable(matchingEngine.getPair(address(base), address(quote))));
        (uint256 bidHead, uint256 askHead) = book.heads();
        // check bidHead is lower than down
        assert(bidHead < down);
        uint256 result = _detMarketSellMakePrice(address(book), bidHead, askHead, 2000000);
        console.log("result: ", result);
        // check computed result
        assert(result == down);
        IMatchingEngine.OrderResult memory orderResult =
            matchingEngine.marketSell(
                IMatchingEngine.MarketOrderInput({
                    base: address(base),
                    quote: address(quote),
                    amount: 1e8,
                    isMaker: true,
                    n: 5,
                    recipient: trader1,
                    slippageLimit: 2000000
                })
            );
        // check make price is equal to computed result
        console.log("make price: ", orderResult.makePrice);
        assert(orderResult.makePrice == result);
    }

    // On market sell, if bidHead is lower than lmp - ranged price, order is lmp - ranged price
    function testMarketSellVolatilityDown2() public {
        (MockBase base, MockQuote quote, Orderbook book, uint256 _mp, uint256 _up, uint256 down) =
            _setupVolatilityTest();
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e6,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        // get pair and price info
        book = Orderbook(payable(matchingEngine.getPair(address(base), address(quote))));
        (uint256 bidHead, uint256 askHead) = book.heads();
        // check bidHead is lower than up
        assert(bidHead < down);
        uint256 result = _detMarketSellMakePrice(address(book), bidHead, askHead, 2000000);
        console.log("result: ", result);
        // check computed result
        assert(result == down);
        IMatchingEngine.OrderResult memory orderResult =
            matchingEngine.marketSell(
                IMatchingEngine.MarketOrderInput({
                    base: address(base),
                    quote: address(quote),
                    amount: 1e8,
                    isMaker: true,
                    n: 5,
                    recipient: trader1,
                    slippageLimit: 2000000
                })
            );
        // check make price is equal to computed result
        console.log("make price: ", orderResult.makePrice);
        assert(orderResult.makePrice == result);
    }

    // On market sell, if bidHead is higher than lmp - ranged price, order is made with bidHead
    function testMarketSellVolatilityDown3() public {
        (MockBase base, MockQuote quote, Orderbook book, uint256 mp, uint256 _up, uint256 down) = _setupVolatilityTest();
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: (mp * (1e8 - 100)) / 1e8,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        // get pair and price info
        book = Orderbook(payable(matchingEngine.getPair(address(base), address(quote))));
        (uint256 bidHead, uint256 askHead) = book.heads();
        // check bidHead is higher than down
        assert(bidHead > down);
        uint256 result = _detMarketSellMakePrice(address(book), bidHead, askHead, 2000000);
        console.log("result: ", result);
        // check computed result
        assert(result == bidHead);
        IMatchingEngine.OrderResult memory orderResult = matchingEngine // silence warning
            .marketSell(
                IMatchingEngine.MarketOrderInput({
                    base: address(base),
                    quote: address(quote),
                    amount: 1e8,
                    isMaker: true,
                    n: 5,
                    recipient: trader1,
                    slippageLimit: 2000000
                })
            );
        // check make price is equal to computed result
        console.log("make price: ", orderResult.makePrice);
        assert(orderResult.makePrice == result);
    }

    function testMarketSellVolatilityDownOnSlippageLimit() public {
        (MockBase base, MockQuote quote, Orderbook book, uint256 _mp, uint256 _up, uint256 down) =
            _setupVolatilityTest();
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e6,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        // get pair and price info
        book = Orderbook(payable(matchingEngine.getPair(address(base), address(quote))));
        (uint256 bidHead, uint256 askHead) = book.heads();
        // check bidHead is lower than down
        assert(bidHead < down);
        uint256 result = _detMarketSellMakePrice(address(book), bidHead, askHead, 500000);
        console.log("result: ", result);
        // check computed result with user input with 50bps down
        assert(result == 99500000);
        IMatchingEngine.OrderResult memory orderResult =
            matchingEngine.marketSell(
                IMatchingEngine.MarketOrderInput({
                    base: address(base),
                    quote: address(quote),
                    amount: 1e8,
                    isMaker: true,
                    n: 5,
                    recipient: trader1,
                    slippageLimit: 500000
                })
            );
        // check make price is equal to computed result
        console.log("make price: ", orderResult.makePrice);
        assert(orderResult.makePrice == result);
    }

    function testMarketSellVolatilityDownOnSlippageLimit2() public {
        (MockBase base, MockQuote quote, Orderbook book, uint256 _mp, uint256 _up, uint256 down) =
            _setupVolatilityTest();
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e6,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        // get pair and price info
        book = Orderbook(payable(matchingEngine.getPair(address(base), address(quote))));
        (uint256 bidHead, uint256 askHead) = book.heads();
        // check bidHead is lower than down
        assert(bidHead < down);
        uint256 result = _detMarketSellMakePrice(address(book), bidHead, askHead, 2000000);
        console.log("result: ", result);
        // check computed result with user input with 50bps down
        assert(result == down);
        IMatchingEngine.OrderResult memory orderResult =
            matchingEngine.marketSell(
                IMatchingEngine.MarketOrderInput({
                    base: address(base),
                    quote: address(quote),
                    amount: 1e8,
                    isMaker: true,
                    n: 5,
                    recipient: trader1,
                    slippageLimit: 3000000
                })
            );
        // check make price is equal to computed result
        console.log("make price: ", orderResult.makePrice);
        assert(orderResult.makePrice == result);
    }

    // Check if market sell leading to zero price is fixed
    function testMarketSellSettingPriceToZero() public {
        (MockBase base, MockQuote quote, Orderbook book, uint256 _mp, uint256 _up, uint256 _down) =
            _setupVolatilityTest();

        // get pair and price info
        book = Orderbook(payable(matchingEngine.getPair(address(base), address(quote))));
        (uint256 _bidHead, uint256 _askHead) = book.heads();
        uint256 beforeB = quote.balanceOf(address(trader1));
        IMatchingEngine.OrderResult memory orderResult = matchingEngine // silence warning
            .marketSell(
                IMatchingEngine.MarketOrderInput({
                    base: address(base),
                    quote: address(quote),
                    amount: 1e8,
                    isMaker: false,
                    n: 5,
                    recipient: trader1,
                    slippageLimit: 2000000
                })
            );
        uint256 afterB = quote.balanceOf(address(trader1));
        // check make price is equal to computed result
        console.log("make price: ", orderResult.makePrice);
        console.log("market price: ", book.mktPrice());
        console.log("balance before: ", beforeB);
        console.log("balance after: ", afterB);
    }

    // Check if market buy leading to price change is fixed
    function testMarketBuySettingPriceToUp() public {
        (
            MockBase base,
            MockQuote quote,
            Orderbook book,
            uint256 _mp, // silence warning
            uint256 _up, // silence warning
            uint256 _down // silence warning
        ) = _setupVolatilityTest();
        console.log("market buy price test begins: ", _mp);
        // get pair and price info
        Orderbook bookBefore = Orderbook(payable(matchingEngine.getPair(address(base), address(quote))));
        (uint256 _bidHead, uint256 _askHead) = bookBefore.heads(); // silence warning
        uint256 beforeB = quote.balanceOf(address(trader1));
        IMatchingEngine.OrderResult memory orderResult = matchingEngine // silence warning
            .marketBuy(
                IMatchingEngine.MarketOrderInput({
                    base: address(base),
                    quote: address(quote),
                    amount: 1e8,
                    isMaker: false,
                    n: 5,
                    recipient: trader1,
                    slippageLimit: 2000000
                })
            );
        Orderbook bookAfter = Orderbook(payable(matchingEngine.getPair(address(base), address(quote))));
        uint256 afterB = quote.balanceOf(address(trader1));
        // check make price is equal to computed result
        console.log("make price: ", orderResult.makePrice);
        console.log("placed amount: ", orderResult.placed);
        console.log("order id: ", orderResult.id);
        console.log("market price before trade: ", bookBefore.mktPrice());
        console.log("balance before: ", beforeB);
        console.log("balance after: ", afterB);
    }

    function testMarketSellVolatilityDown4() public {
        (
            MockBase base,
            MockQuote quote,
            Orderbook book,
            uint256 _mp, /* silence warning */
            uint256 _up, /* silence warning */
            uint256 down
        ) = _setupVolatilityTest();
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e8 - 1,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e10,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        // get pair and price info
        book = Orderbook(payable(matchingEngine.getPair(address(base), address(quote))));
        (uint256 bidHead, uint256 askHead) = book.heads();
        // check bidHead is higher than up
        assert(bidHead >= down);
        uint256 result = _detMarketSellMakePrice(address(book), bidHead, askHead, 2000000);
        console.log("result: ", result);
        // check computed result
        assert(result == bidHead);
        IMatchingEngine.OrderResult memory orderResult = matchingEngine.marketSell(
            IMatchingEngine.MarketOrderInput({
                // silence warning
                base: address(base),
                quote: address(quote),
                amount: 1e8,
                isMaker: true,
                n: 5,
                recipient: trader1,
                slippageLimit: 2000000
            })
        );
        // check make price is equal to computed result
        console.log("make price: ", orderResult.makePrice);
        assert(orderResult.makePrice == result);
    }

    function testMarketBuyAndSell() public {
        super.setUp();
        MockBase base = new MockBase("Base Token", "BASE");
        MockUSDC quote = new MockUSDC("Quote Token", "QUOTE");
        base.mint(trader1, type(uint256).max);
        quote.mint(trader1, type(uint256).max);
        // make a price in matching engine where 1 base = 1 quote with buy and sell order
        matchingEngine.addPair(address(base), address(quote), 341320000000, 0, address(base), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        vm.startPrank(trader1);
        base.approve(address(matchingEngine), type(uint256).max);
        quote.approve(address(matchingEngine), type(uint256).max);
        matchingEngine.marketBuy(
            IMatchingEngine.MarketOrderInput({
                base: address(base),
                quote: address(quote),
                amount: 100000,
                isMaker: true,
                n: 5,
                recipient: trader1,
                slippageLimit: 2000000
            })
        );

        matchingEngine.marketSell(
            IMatchingEngine.MarketOrderInput({
                base: address(base),
                quote: address(quote),
                amount: 1e14,
                isMaker: true,
                n: 5,
                recipient: trader1,
                slippageLimit: 2000000
            })
        );
    }

    function testMarketBuyAndSell2() public {
        super.setUp();
        MockBTC btc = new MockBTC("BTC", "BTC");
        MockQuote quote = new MockQuote("Quote Token", "QUOTE");
        btc.mint(trader1, type(uint256).max);
        quote.mint(trader1, type(uint256).max);
        // make a price in matching engine where 1 base = 1 quote with buy and sell order
        matchingEngine.addPair(address(btc), address(quote), 3598000000, 0, address(btc), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        vm.startPrank(trader1);
        btc.approve(address(matchingEngine), type(uint256).max);
        quote.approve(address(matchingEngine), type(uint256).max);
        matchingEngine.marketBuy(
            IMatchingEngine.MarketOrderInput({
                base: address(btc),
                quote: address(quote),
                amount: 9e18,
                isMaker: true,
                n: 5,
                recipient: trader1,
                slippageLimit: 2000000
            })
        );

        matchingEngine.marketSell(
            IMatchingEngine.MarketOrderInput({
                base: address(btc),
                quote: address(quote),
                amount: 1e14,
                isMaker: true,
                n: 5,
                recipient: trader1,
                slippageLimit: 2000000
            })
        );
    }
}
