// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {StopLimitOrderbook} from "../../../src/exchange/orderbooks/StopLimitOrderbook.sol";
import {StopLimitOrderbookFactory} from "../../../src/exchange/orderbooks/StopLimitOrderbookFactory.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";
import {Vm} from "forge-std/Vm.sol";
import {StopOrderEngine} from "../../../src/exchange/StopOrderEngine.sol";

contract StopLimitOrderTest is BaseSetup {
    uint256 private constant INITIAL_PRICE = 100e8;
    StopLimitOrderbookFactory private stopFactory;
    StopOrderEngine private stopEngine;

    function setUp() public override {
        super.setUp();
        stopEngine = new StopOrderEngine(address(matchingEngine));
        stopFactory = StopLimitOrderbookFactory(stopEngine.factory());
        matchingEngine.setStopOrderEngine(address(stopEngine));
        matchingEngine.addPair(
            address(token1), address(token2), INITIAL_PRICE, 0, address(token1),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        vm.prank(trader1);
        token1.approve(address(stopEngine), type(uint256).max);
        vm.prank(trader1);
        token2.approve(address(stopEngine), type(uint256).max);
    }

    function testPairStopBookIsDeterministicClone() public view {
        address pair = matchingEngine.getPair(address(token1), address(token2));
        address stopBook = stopEngine.stopOrderbooks(pair);
        assertTrue(stopFactory.isClone(stopBook));
        assertEq(stopFactory.predict(pair), stopBook);
        assertEq(StopLimitOrderbook(stopBook).orderbook(), pair);
    }

    function testRemainderMatchesCrossedStopLimitOrder() public {
        // Dormant sell stop: once LMP falls to 90, sell one BASE with a limit of 80.
        vm.prank(trader1);
        uint32 stopId = stopEngine.placeStopLimit(
            address(token1), address(token2), false, 90e8, 80e8, 1e18, trader1
        );

        // Permit and place a regular ask at 80. Its placement moves LMP below the stop,
        // but the stop remains isolated until a taker first consumes the regular book.
        matchingEngine.setSpread(address(token1), address(token2), 20_000_000, 20_000_000, false);
        vm.prank(trader1);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 80e8,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );

        uint256 baseBefore = token1.balanceOf(trader2);
        vm.prank(trader2);
        // n=2 is shared across both venues: one regular-book match followed by
        // one stop-book match.
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 80e8,
                amount: 160e18,
                isMaker: false,
                n: 2,
                recipient: trader2
            })
        );

        assertEq(token1.balanceOf(trader2) - baseBefore, 1.998e18, "regular and stop asks both filled after fees");
        StopLimitOrderbook.StopOrder memory stopped = stopEngine.getOrder(
            address(token1), address(token2), false, stopId
        );
        assertEq(stopped.owner, address(0), "activated stop removed from dormant book");
    }

    function testExhaustedRegularMatchBudgetDoesNotActivateStop() public {
        vm.prank(trader1);
        uint32 stopId = stopEngine.placeStopLimit(
            address(token1), address(token2), false, 90e8, 80e8, 1e18, trader1
        );

        matchingEngine.setSpread(address(token1), address(token2), 20_000_000, 20_000_000, false);
        vm.prank(trader1);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 80e8,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );

        vm.prank(trader2);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 80e8,
                amount: 160e18,
                isMaker: false,
                n: 1,
                recipient: trader2
            })
        );

        StopLimitOrderbook.StopOrder memory stopped = stopEngine.getOrder(
            address(token1), address(token2), false, stopId
        );
        assertEq(stopped.owner, trader1, "stop remains dormant when regular match consumes n");
        assertEq(stopped.depositAmount, 1e18);
    }

    function testUncrossedStopDoesNotMatch() public {
        vm.prank(trader1);
        uint32 stopId = stopEngine.placeStopLimit(
            address(token1), address(token2), false, 90e8, 80e8, 1e18, trader1
        );

        vm.prank(trader2);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 100e8,
                amount: 100e18,
                isMaker: false,
                n: 2,
                recipient: trader2
            })
        );

        StopLimitOrderbook.StopOrder memory stopped = stopEngine.getOrder(
            address(token1), address(token2), false, stopId
        );
        assertEq(stopped.owner, trader1);
        assertEq(stopped.depositAmount, 1e18);
    }

    function testCrossedBuyStopDoesNotActivateWhenTakerHasNoRemainder() public {
        vm.prank(trader1);
        uint32 stopId = stopEngine.placeStopLimit(
            address(token1), address(token2), true, 110e8, 120e8, 120e18, trader1
        );

        matchingEngine.setSpread(address(token1), address(token2), 20_000_000, 20_000_000, false);
        vm.prank(trader1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 120e8,
                amount: 120e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );

        // This consumes the ordinary bid exactly. No matching budget or taker
        // remainder remains, so the crossed stop must stay dormant.
        vm.prank(trader2);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 120e8,
                amount: 1e18,
                isMaker: false,
                n: 3,
                recipient: trader2
            })
        );

        StopLimitOrderbook.StopOrder memory stopped = stopEngine.getOrder(
            address(token1), address(token2), true, stopId
        );
        assertEq(stopped.owner, trader1);
    }

    function testOwnerCanCancelDormantStop() public {
        uint256 beforeBalance = token1.balanceOf(trader1);
        vm.prank(trader1);
        uint32 stopId = stopEngine.placeStopLimit(
            address(token1), address(token2), false, 90e8, 80e8, 1e18, trader1
        );
        vm.prank(trader1);
        uint256 refunded = stopEngine.cancel(
            address(token1), address(token2), false, stopId
        );
        assertEq(refunded, 1e18);
        assertEq(token1.balanceOf(trader1), beforeBalance);
    }

    function testAnyoneCanExpireDormantStopAndOwnerIsRefunded() public {
        uint256 beforeBalance = token1.balanceOf(trader1);
        uint64 deadline = uint64(block.timestamp + 1 hours);
        vm.prank(trader1);
        uint32 stopId = stopEngine.placeStopLimit(
            address(token1), address(token2), false, 90e8, 80e8, 1e18, trader1, deadline
        );
        vm.warp(uint256(deadline) + 1);
        vm.prank(trader2);
        assertEq(
            stopEngine.expire(address(token1), address(token2), false, stopId),
            1e18
        );
        assertEq(token1.balanceOf(trader1), beforeBalance);
        assertEq(
            stopEngine.getOrder(address(token1), address(token2), false, stopId).owner,
            address(0)
        );
    }

    function testStopDeadlineRejectsExpiredTransaction() public {
        vm.warp(100);
        vm.prank(trader1);
        vm.expectRevert(
            abi.encodeWithSelector(StopOrderEngine.DeadlineExpired.selector, uint64(99), uint256(100))
        );
        stopEngine.placeStopLimit(
            address(token1), address(token2), false, 90e8, 80e8, 1e18, trader1, 99
        );
    }

    function testRejectsAlreadyCrossedStop() public {
        vm.prank(trader1);
        vm.expectRevert();
        stopEngine.placeStopLimit(
            address(token1), address(token2), false, INITIAL_PRICE, 80e8, 1e18, trader1
        );
    }

    function testStopMarketBuyExecutesAndRefundsRemainder() public {
        vm.prank(trader1);
        uint32 stopId = stopEngine.placeStopMarket(IMatchingEngine.StopMarketInput({
            base: address(token1),
            quote: address(token2),
            isBid: true,
            stopPrice: 110e8,
            amount: 220e18,
            n: 2,
            slippageLimit: 20_000_000,
            deadline: 0,
            recipient: trader1
        }));

        matchingEngine.setSpread(address(token1), address(token2), 20_000_000, 20_000_000, false);
        matchingEngine.setSpread(address(token1), address(token2), 20_000_000, 20_000_000, true);
        // Two asks: trader2's triggering buy consumes the first; the newly crossed
        // stop-market buy consumes the second and refunds its unused quote.
        vm.startPrank(trader1);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 110e8,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 110e8,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        vm.stopPrank();

        uint256 baseBefore = token1.balanceOf(trader1);
        uint256 quoteBefore = token2.balanceOf(trader1);
        vm.prank(trader2);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 110e8,
                amount: 110e18,
                isMaker: false,
                n: 3,
                recipient: trader2
            })
        );

        // The exact regular fill above exhausts its own pass. A later order with
        // no regular resting bid provides the activation pass; the stop-market
        // buy then consumes the second ask.
        vm.prank(trader2);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 110e8,
                amount: 1e18,
                isMaker: false,
                n: 2,
                recipient: trader2
            })
        );

        assertEq(token1.balanceOf(trader1) - baseBefore, 0.999e18, "stop-market bought one ask after fee");
        // 220 quote is settlement for the two maker asks and 110 is the unused
        // stop-market input returned to its owner.
        assertEq(token2.balanceOf(trader1) - quoteBefore, 330e18, "settlement plus market remainder refund");
        assertEq(token2.balanceOf(address(matchingEngine)), 0, "engine retains no stop-market remainder");
        StopLimitOrderbook.StopOrder memory stopped = stopEngine.getOrder(
            address(token1), address(token2), true, stopId
        );
        assertEq(stopped.owner, address(0));
    }

    function testStopLifecycleEventsUseEngineAddressOnly() public {
        vm.recordLogs();
        vm.prank(trader1);
        stopEngine.placeStopLimit(
            address(token1), address(token2), false, 90e8, 80e8, 1e18, trader1
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 placedTopic = keccak256(
            "StopOrderPlaced(address,uint32,address,bool,bool,uint256,uint256,uint256,uint32,uint32,uint64)"
        );
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == placedTopic) {
                assertEq(logs[i].emitter, address(stopEngine));
                found = true;
            }
        }
        assertTrue(found, "canonical placement event missing");
    }

    function testRegularAndStopIdsAreSeparateNamespaces() public {
        vm.prank(trader1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 80e8,
                amount: 100e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        vm.prank(trader1);
        uint32 stopId = stopEngine.placeStopLimit(
            address(token1), address(token2), true, 110e8, 120e8, 120e18, trader1
        );

        assertEq(stopId, 1, "first stop id");
        assertEq(matchingEngine.getOrder(address(token1), address(token2), true, 1).owner, trader1);
        assertEq(
            stopEngine.getOrder(address(token1), address(token2), true, 1).owner,
            trader1
        );

        vm.prank(trader1);
        stopEngine.cancel(address(token1), address(token2), true, 1);
        assertEq(
            matchingEngine.getOrder(address(token1), address(token2), true, 1).owner,
            trader1,
            "cancelling stop id 1 must not cancel regular id 1"
        );
    }

    function testOnlyStopOwnerCanCancel() public {
        vm.prank(trader1);
        uint32 stopId = stopEngine.placeStopLimit(
            address(token1), address(token2), false, 90e8, 80e8, 1e18, trader1
        );

        vm.prank(trader2);
        vm.expectRevert();
        stopEngine.cancel(address(token1), address(token2), false, stopId);

        assertEq(
            stopEngine.getOrder(address(token1), address(token2), false, stopId).owner,
            trader1
        );
    }

    function testRejectsZeroRecipient() public {
        vm.prank(trader1);
        vm.expectRevert(StopOrderEngine.InvalidRecipient.selector);
        stopEngine.placeStopLimit(
            address(token1), address(token2), false, 90e8, 80e8, 1e18, address(0)
        );

        vm.prank(trader1);
        vm.expectRevert(StopOrderEngine.InvalidRecipient.selector);
        stopEngine.placeStopMarket(IMatchingEngine.StopMarketInput({
            base: address(token1),
            quote: address(token2),
            isBid: true,
            stopPrice: 110e8,
            amount: 120e18,
            n: 2,
            slippageLimit: 20_000_000,
            deadline: 0,
            recipient: address(0)
        }));
    }

    function testActivationEventLinksStopToCancelableRegularOrder() public {
        vm.prank(trader1);
        uint32 stopId = stopEngine.placeStopLimit(
            address(token1), address(token2), true, 110e8, 120e8, 120e18, trader1
        );

        matchingEngine.setSpread(address(token1), address(token2), 20_000_000, 20_000_000, false);
        vm.prank(trader1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 120e8,
                amount: 120e18,
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
                price: 120e8,
                amount: 1e18,
                isMaker: false,
                n: 1,
                recipient: trader2
            })
        );

        vm.recordLogs();
        vm.prank(trader2);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 120e8,
                amount: 120e18,
                isMaker: false,
                n: 2,
                recipient: trader2
            })
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 activatedTopic = keccak256(
            "StopOrderActivated(address,uint32,address,bool,bool,uint256,uint32)"
        );
        uint32 regularOrderId;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == activatedTopic) {
                assertEq(logs[i].emitter, address(stopEngine));
                assertEq(uint32(uint256(logs[i].topics[2])), stopId);
                (bool isBid, bool isMarket, uint256 limitPrice, uint32 linkedId) =
                    abi.decode(logs[i].data, (bool, bool, uint256, uint32));
                assertTrue(isBid);
                assertFalse(isMarket);
                assertEq(limitPrice, 120e8);
                regularOrderId = linkedId;
            }
        }
        assertTrue(regularOrderId != 0, "activation must expose regular order id");
        assertEq(
            matchingEngine.getOrder(address(token1), address(token2), true, regularOrderId).owner,
            trader1
        );
        assertEq(
            stopEngine.getOrder(address(token1), address(token2), true, stopId).owner,
            address(0),
            "activated stop is no longer cancellable as a stop"
        );

        vm.prank(trader1);
        vm.expectRevert();
        stopEngine.cancel(address(token1), address(token2), true, stopId);

        vm.prank(trader1);
        matchingEngine.cancelOrder(address(token1), address(token2), true, regularOrderId);
        assertEq(
            matchingEngine.getOrder(address(token1), address(token2), true, regularOrderId).owner,
            address(0)
        );
    }
}
