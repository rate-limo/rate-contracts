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
import {IOrderbook} from "../../../src/exchange/interfaces/IOrderbook.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {IOrderbookFactory} from "../../../src/exchange/interfaces/IOrderbookFactory.sol";
import {WETH9} from "../../../src/mock/WETH9.sol";
import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {console} from "forge-std/console.sol";
import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";

contract LimitOrderTest is BaseSetup {
    function testDeadlineIsStoredAndPermissionlessExpiryRefunds() public {
        super.setUp();
        matchingEngine.addPair(
            address(token1), address(token2), 1e8, 0, address(token1),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        uint256 balanceBefore = token2.balanceOf(trader1);
        uint64 deadline = uint64(block.timestamp + 1 hours);
        vm.prank(trader1);
        IMatchingEngine.OrderResult memory result = matchingEngine.createOrder(
            IMatchingEngine.CreateOrderInput({
                base: address(token1),
                quote: address(token2),
                isBid: true,
                isLimit: true,
                orderId: 0,
                price: 1e8,
                amount: 100e18,
                n: 2,
                recipient: trader1,
                isMaker: true,
                slippageLimit: 0,
                deadline: deadline
            })
        );
        ExchangeOrderbook.Order memory order = matchingEngine.getOrder(
            address(token1), address(token2), true, result.id
        );
        assertEq(order.deadline, deadline);

        vm.warp(uint256(deadline) + 1);
        vm.prank(trader2);
        matchingEngine.expireOrder(address(token1), address(token2), true, result.id);
        assertEq(token2.balanceOf(trader1), balanceBefore, "expired deposit refunded");
        assertEq(
            matchingEngine.getOrder(address(token1), address(token2), true, result.id).owner,
            address(0),
            "expired order removed"
        );
    }

    function testDeadlineEntrypointsRejectExpiredTransactions() public {
        super.setUp();
        matchingEngine.addPair(
            address(token1), address(token2), 1e8, 0, address(token1),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        vm.warp(100);
        vm.startPrank(trader1);
        vm.expectRevert(abi.encodeWithSelector(MatchingEngine.DeadlineExpired.selector, uint64(99), uint256(100)));
        matchingEngine.createOrder(
            IMatchingEngine.CreateOrderInput({
                base: address(token1),
                quote: address(token2),
                isBid: false,
                isLimit: true,
                orderId: 0,
                price: 1e8,
                amount: 1e18,
                n: 2,
                recipient: trader1,
                isMaker: true,
                slippageLimit: 0,
                deadline: 99
            })
        );
        vm.expectRevert(abi.encodeWithSelector(MatchingEngine.DeadlineExpired.selector, uint64(99), uint256(100)));
        matchingEngine.createOrder(
            IMatchingEngine.CreateOrderInput({
                base: address(token1),
                quote: address(token2),
                isBid: true,
                isLimit: false,
                orderId: 0,
                price: 0,
                amount: 100e18,
                n: 2,
                recipient: trader1,
                isMaker: false,
                slippageLimit: 1_000_000,
                deadline: 99
            })
        );
        vm.stopPrank();
    }

    function testMatchingSkipsExpiredHeadAndContinues() public {
        super.setUp();
        matchingEngine.addPair(
            address(token1), address(token2), 1e8, 0, address(token1),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        uint64 deadline = uint64(block.timestamp + 1 hours);
        uint256 makerBaseBefore = token1.balanceOf(trader1);
        vm.startPrank(trader1);
        IMatchingEngine.OrderResult memory expired = matchingEngine.createOrder(
            IMatchingEngine.CreateOrderInput({
                base: address(token1),
                quote: address(token2),
                isBid: false,
                isLimit: true,
                orderId: 0,
                price: 1e8,
                amount: 1e18,
                n: 2,
                recipient: trader1,
                isMaker: true,
                slippageLimit: 0,
                deadline: deadline
            })
        );
        IMatchingEngine.OrderResult memory live = matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 1e8,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        vm.stopPrank();

        vm.warp(uint256(deadline) + 1);
        uint256 takerBaseBefore = token1.balanceOf(trader2);
        vm.prank(trader2);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 1e8,
                amount: 100e18,
                isMaker: false,
                n: 2,
                recipient: trader2
            })
        );

        assertEq(token1.balanceOf(trader2) - takerBaseBefore, 0.999e18, "live order filled");
        assertEq(token1.balanceOf(trader1), makerBaseBefore - 1e18, "expired deposit refunded");
        assertEq(matchingEngine.getOrder(address(token1), address(token2), false, expired.id).owner, address(0));
        assertEq(matchingEngine.getOrder(address(token1), address(token2), false, live.id).owner, address(0));
    }

    function testLimitTradeWithDiffDecimals() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(btc), 1e8, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        console.log("Base/Quote Pair: ", matchingEngine.getPair(address(token1), address(btc)));
        vm.prank(trader1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(btc),
                price: 1e8,
                amount: 1e8,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        vm.prank(trader2);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(btc),
                price: 1e8,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader2
            })
        );
    }

    function testLimitTrade() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(token2), 1e8, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        console.log("Base/Quote Pair: ", matchingEngine.getPair(address(token1), address(token2)));
        vm.prank(trader1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 1e8,
                amount: 100e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        vm.prank(trader2);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 1e8,
                amount: 100e18,
                isMaker: true,
                n: 2,
                recipient: trader2
            })
        );
    }

    function testLimitBuyETH() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(weth), 1e8, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        console.log("weth balance");
        console.log(trader1.balance / 1e18);
        vm.prank(trader1);
        matchingEngine.createOrder{value: 1e18}(
            IMatchingEngine.CreateOrderInput({
                base: address(token1),
                quote: matchingEngine.WETH(),
                isBid: true,
                isLimit: true,
                orderId: 0,
                price: 1e8,
                amount: 1e18,
                n: 5,
                recipient: trader1,
                isMaker: true,
                slippageLimit: 0,
                deadline: 0
            })
        );
        vm.prank(trader1);
        token1.approve(address(matchingEngine), 10e18);
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
        console.log("weth balance");
        console.log(trader1.balance / 1e18);
    }

    function testLimitSellETH() public {
        super.setUp();
        matchingEngine.addPair(address(weth), address(token1), 1e8, 0, address(weth), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        matchingEngine.addPair(address(token1), address(weth), 1e8, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        console.log("weth balance");
        console.log(trader1.balance / 1e18);
        vm.prank(trader1);
        matchingEngine.createOrder{value: 1e18}(
            IMatchingEngine.CreateOrderInput({
                base: matchingEngine.WETH(),
                quote: address(token1),
                isBid: false,
                isLimit: true,
                orderId: 0,
                price: 1e8,
                amount: 1e18,
                n: 5,
                recipient: trader1,
                isMaker: true,
                slippageLimit: 0,
                deadline: 0
            })
        );
        vm.prank(trader1);
        matchingEngine.createOrder{value: 1e18}(
            IMatchingEngine.CreateOrderInput({
                base: address(token1),
                quote: matchingEngine.WETH(),
                isBid: true,
                isLimit: true,
                orderId: 0,
                price: 1e8,
                amount: 1e18,
                n: 5,
                recipient: trader1,
                isMaker: true,
                slippageLimit: 0,
                deadline: 0
            })
        );
        vm.prank(trader1);
        token1.approve(address(matchingEngine), 10e18);
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
        console.log("weth balance");
        console.log(trader1.balance / 1e18);
    }

    function testLimitBuyETHMakingNewBidHead() public {
        super.setUp();
        matchingEngine.addPair(address(weth), address(token1), 1e8, 0, address(weth), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        console.log("weth balance");
        console.log(trader1.balance / 1e18);
        vm.startPrank(trader1);

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
        console.log("weth balance");
        console.log(trader1.balance / 1e18);
        uint256 mktPrice = matchingEngine.mktPrice(address(weth), address(token1));
        console.log(mktPrice);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(weth),
                quote: address(token1),
                price: 294900000001,
                amount: 1e18,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );
    }

    // limit order is possible on out of spread range, but it is not matched
    function testLimitOrderOutOfSpreadRange() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(token2), 1e8, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        vm.prank(trader1);
        // mktprice is setup with lmp
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 1e8,
                amount: 1e18,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );
    }

    function _setupVolatilityTest()
        internal
        returns (
            MockBase base,
            MockQuote quote,
            Orderbook book,
            uint256 bidHead,
            uint256 askHead,
            uint256 up,
            uint256 down
        )
    {
        super.setUp();
        base = new MockBase("Base Token", "BASE");
        quote = new MockQuote("Quote Token", "QUOTE");
        base.mint(trader1, type(uint256).max);
        quote.mint(trader1, type(uint256).max);
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
        // get pair and price info
        book = Orderbook(payable(matchingEngine.getPair(address(base), address(quote))));
        (uint256 bidHead, uint256 askHead) = book.heads();
        uint256 lmp = IOrderbook(matchingEngine.getPair(address(base), address(quote))).lmp();
        up = (lmp * (1e8 + 2000000)) / 1e8;
        down = (lmp * (1e8 - 2000000)) / 1e8;
        return (base, quote, book, bidHead, askHead, up, down);
    }

    function _detLimitBuyMakePrice(address orderbook, uint256 lp, uint256 bidHead, uint256 askHead, uint32 spread)
        internal
        view
        returns (uint256 price, uint256 lmp)
    {
        uint256 up;
        lmp = IOrderbook(orderbook).lmp();
        if (askHead == 0 && bidHead == 0) {
            if (lmp != 0) {
                up = (lmp * (1e8 + spread)) / 1e8;
                return (lp >= up ? up : lp, lmp);
            }
            return (lp, lmp);
        } else if (askHead == 0 && bidHead != 0) {
            up = (bidHead * (1e8 + spread)) / 1e8;
            return (lp >= up ? up : lp, lmp);
        } else if (askHead != 0 && bidHead == 0) {
            if (lmp != 0) {
                up = (lmp * (1e8 + spread)) / 1e8;
                up = lp >= up ? up : lp;
                return (up >= askHead ? askHead : up, lmp);
            }
            up = (askHead * (1e8 + spread)) / 1e8;
            up = lp >= up ? up : lp;
            return (up >= askHead ? askHead : up, lmp);
        } else {
            // First, set upper limit on make price for market suspenstion
            up = lp >= lmp ? lp : lmp;
            // upper limit on make price must not go above ask price
            return (up >= askHead ? askHead : up, lmp);
        }
    }

    function _detLimitSellMakePrice(address orderbook, uint256 lp, uint256 bidHead, uint256 askHead, uint32 spread)
        internal
        view
        returns (uint256 price, uint256 lmp)
    {
        uint256 down;
        lmp = IOrderbook(orderbook).lmp();
        if (askHead == 0 && bidHead == 0) {
            if (lmp != 0) {
                down = (lmp * (1e8 - spread)) / 1e8;
                return (lp <= down ? down : lp, lmp);
            }
            return (lp, lmp);
        } else if (askHead == 0 && bidHead != 0) {
            if (lmp != 0) {
                down = (lmp * (1e8 - spread)) / 1e8;
                return (lp <= down ? down : lp, lmp);
            }
            down = (bidHead * (1e8 - spread)) / 1e8;
            return (lp <= down ? down : lp, lmp);
        } else if (askHead != 0 && bidHead == 0) {
            down = (askHead * (1e8 - spread)) / 1e8;
            down = lp <= down ? down : lp;
            return (down <= bidHead ? bidHead : down, lmp);
        } else {
            // First, set lower limit on down price for market suspenstion
            down = lp <= lmp ? lp : lmp;
            // lower limit price on sell cannot be lower than bid head price
            return (down <= bidHead ? bidHead : down, lmp);
        }
    }

    // on limit sell, if limit price is higher than market price + ranged price, order is made with limit price.
    function testLimitSellVolatilityOutOfRange() public {
        (MockBase base, MockQuote quote, Orderbook book, uint256 bidHead, uint256 askHead, uint256 up, uint256 down) =
            _setupVolatilityTest();
        // check limit price is higher than up
        uint256 limitPrice = (1e11 * (1e8 + 1000)) / 1e8;
        console.log(limitPrice, up);
        assert(limitPrice > up);
        (uint256 result, uint256 lmp) = _detLimitSellMakePrice(address(book), limitPrice, bidHead, askHead, 2000000);
        console.log("result: ", result);
        assert(result == limitPrice);
        MatchingEngine.OrderResult memory orderResult =
            matchingEngine.limitSell(
                IMatchingEngine.LimitOrderInput({
                    base: address(base),
                    quote: address(quote),
                    price: limitPrice,
                    amount: 1e18,
                    isMaker: true,
                    n: 5,
                    recipient: trader1
                })
            );
        assert(orderResult.makePrice == result);
    }

    // on limit sell, if limit price is lower than market price - ranged price, order is made with market price - ranged price.
    function testLimitSellVolatilityDown() public {
        (MockBase base, MockQuote quote, Orderbook book, uint256 bidHead, uint256 askHead, uint256 up, uint256 down) =
            _setupVolatilityTest();
        // check limit price is higher than up
        uint256 limitPrice = (1e8 * (1e8 - 10000000)) / 1e8;
        console.log(limitPrice, down);
        assert(limitPrice < down);
        (uint256 result, uint256 lmp) = _detLimitSellMakePrice(address(book), limitPrice, bidHead, askHead, 2000000);
        console.log("result: ", result);
        assert(result == down);
        uint256 mp = IOrderbook(address(book)).lmp();
        MatchingEngine.OrderResult memory orderResult =
            matchingEngine.limitSell(
                IMatchingEngine.LimitOrderInput({
                    base: address(base),
                    quote: address(quote),
                    price: limitPrice,
                    amount: 1e18,
                    isMaker: true,
                    n: 5,
                    recipient: trader1
                })
            );
        assert(orderResult.makePrice == result);
        assert(orderResult.makePrice < mp);
    }

    // on limit buy, if limit price is higher than market price + ranged price, order is made with market price + ranged price.
    function testLimitBuyVolatilityUp() public {
        (MockBase base, MockQuote quote, Orderbook book, uint256 bidHead, uint256 askHead, uint256 up, uint256 down) =
            _setupVolatilityTest();
        // check limit price is higher than up
        uint256 limitPrice = (1e11 * (1e8 + 10000000)) / 1e8;
        console.log(limitPrice, up);
        assert(limitPrice > up);
        (uint256 result, uint256 lmp) = _detLimitBuyMakePrice(address(book), limitPrice, bidHead, askHead, 2000000);
        console.log("result: ", result);
        uint256 mp = IOrderbook(address(book)).lmp();
        assert(result == up);
        MatchingEngine.OrderResult memory orderResult =
            matchingEngine.limitBuy(
                IMatchingEngine.LimitOrderInput({
                    base: address(base),
                    quote: address(quote),
                    price: limitPrice,
                    amount: 1e18,
                    isMaker: true,
                    n: 5,
                    recipient: trader1
                })
            );
        assert(orderResult.makePrice == result);
        assert(orderResult.makePrice > mp);
    }

    // on limit buy, if limit price is lower than market price - ranged price, order is made with limit price.
    function testLimitBuyVolatilityLimitPrice() public {
        (MockBase base, MockQuote quote, Orderbook book, uint256 bidHead, uint256 askHead, uint256 up, uint256 down) =
            _setupVolatilityTest();
        // check limit price is higher than up
        uint256 limitPrice = (1e8 * (1e8 - 10000000)) / 1e8;
        console.log(limitPrice, down);
        assert(limitPrice < down);
        (uint256 result, uint256 lmp) = _detLimitBuyMakePrice(address(book), limitPrice, bidHead, askHead, 2000000);
        console.log("result: ", result);
        assert(result == limitPrice);
        MatchingEngine.OrderResult memory orderResult =
            matchingEngine.limitBuy(
                IMatchingEngine.LimitOrderInput({
                    base: address(base),
                    quote: address(quote),
                    price: limitPrice,
                    amount: 1e18,
                    isMaker: true,
                    n: 5,
                    recipient: trader1
                })
            );
        assert(orderResult.makePrice == result);
    }

    // on limit sell, if limit price is lower than market price - ranged price, order is made with limit price.
    function testLimitSellVolatilityLimitPrice() public {
        (MockBase base, MockQuote quote, Orderbook book, uint256 bidHead, uint256 askHead, uint256 up, uint256 down) =
            _setupVolatilityTest();
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e8,
                amount: 1e18,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );
    }

    function testLimitBuyNoSuspensionWhenBidAskHeadExists() public {
        (MockBase base, MockQuote quote, Orderbook book, uint256 bidHead, uint256 askHead, uint256 up, uint256 down) =
            _setupVolatilityTest();

        // set up a limit buy/sell order
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e7,
                amount: 1e18,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e11,
                amount: 1e18,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );
        // set up a limit buy order to match the limit sell
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e10,
                amount: 1e18,
                isMaker: true,
                n: 8,
                recipient: trader1
            })
        );

        assert(matchingEngine.mktPrice(address(base), address(quote)) == 102e6);
    }

    function testLimitBuySuspensionWhenBidAskHeadExistsAfterClearingHead() public {
        (MockBase base, MockQuote quote, Orderbook book, uint256 bidHead, uint256 askHead, uint256 up, uint256 down) =
            _setupVolatilityTest();

        // set up a limit buy/sell order
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e7,
                amount: 1e18,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e11,
                amount: 1e18,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );

        // set up a limit buy order to match the limit sell
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e12,
                amount: 1e24,
                isMaker: true,
                n: 8,
                recipient: trader1
            })
        );

        assert(matchingEngine.mktPrice(address(base), address(quote)) == 102e6);
    }

    function testLimitSellNoSuspensionWhenBidAskHeadExists() public {
        (MockBase base, MockQuote quote, Orderbook book, uint256 bidHead, uint256 askHead, uint256 up, uint256 down) =
            _setupVolatilityTest();

        // set up a limit sell order
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e6,
                amount: 1e18,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e11,
                amount: 1e18,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );

        // set up a limit buy order to match the limit sell
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e7,
                amount: 1e20,
                isMaker: true,
                n: 8,
                recipient: trader1
            })
        );

        assert(matchingEngine.mktPrice(address(base), address(quote)) == 98e6);
    }

    function testLimitSellSuspensionWhenBidAskHeadExistsAfterClearingHead() public {
        (MockBase base, MockQuote quote, Orderbook book, uint256 bidHead, uint256 askHead, uint256 up, uint256 down) =
            _setupVolatilityTest();

        // set up a limit buy/sell order
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e6,
                amount: 1e18,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e11,
                amount: 1e18,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );

        // set up a limit buy order to match the limit sell
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e5,
                amount: 1e24,
                isMaker: true,
                n: 8,
                recipient: trader1
            })
        );

        assert(matchingEngine.mktPrice(address(base), address(quote)) == 98e6);
    }

    function testLimitBuyAllowsBelowLMP() public {
        (MockBase base, MockQuote quote, Orderbook book, uint256 bidHead, uint256 askHead, uint256 up, uint256 down) =
            _setupVolatilityTest();

        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e8 - 1,
                amount: 1e18,
                isMaker: true,
                n: 5,
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
                n: 5,
                recipient: trader1
            })
        );

        MatchingEngine.OrderResult memory result =
            matchingEngine.limitBuy(
                IMatchingEngine.LimitOrderInput({
                    base: address(base),
                    quote: address(quote),
                    price: 1e5,
                    amount: 1e18,
                    isMaker: true,
                    n: 5,
                    recipient: trader1
                })
            );

        assert(result.makePrice == 1e5);
    }

    function testLimitSellAllowsAboveLMP() public {
        (MockBase base, MockQuote quote, Orderbook book, uint256 bidHead, uint256 askHead, uint256 up, uint256 down) =
            _setupVolatilityTest();

        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base),
                quote: address(quote),
                price: 1e8 - 1,
                amount: 1e18,
                isMaker: true,
                n: 5,
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
                n: 5,
                recipient: trader1
            })
        );

        MatchingEngine.OrderResult memory result =
            matchingEngine.limitSell(
                IMatchingEngine.LimitOrderInput({
                    base: address(base),
                    quote: address(quote),
                    price: 1e11,
                    amount: 1e18,
                    isMaker: true,
                    n: 5,
                    recipient: trader1
                })
            );

        assert(result.makePrice == 1e11);
    }
}
