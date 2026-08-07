// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {SwapRouter} from "../../src/swap/SwapRouter.sol";
import {ISwapRouter} from "../../src/swap/interfaces/ISwapRouter.sol";
import {Pool} from "../../src/swap/Pool.sol";
import {PositionManager} from "../../src/swap/PositionManager.sol";
import {IPool} from "../../src/swap/interfaces/IPool.sol";
import {IPositionManager} from "../../src/swap/interfaces/IPositionManager.sol";
import {MockQuote} from "../../src/mock/MockQuote.sol";

contract RouterTest is PoolBaseSetup {
    SwapRouter router;
    uint256 positionId;

    ISwapRouter.RemainderConfig empty;

    function setUp() public override {
        super.setUp();
        router = new SwapRouter(address(poolFactory));
        // The real article, replacing PoolBaseSetup's trader1 stand-in: Pool.swap is
        // onlyRouter and reads this address off the engine.
        matchingEngine.setSwapRouter(address(router));

        vm.prank(lp1);
        token1.approve(address(pool), 10000e18);
        vm.prank(lp1);
        token2.approve(address(pool), 10000e18);
        vm.prank(positionManager);
        positionId = pool.addLiquidity(50e8, 150e8, 5000000, 1000e18, 1000e18, lp1);
    }

    // Deploys a second token1-quoted pair (mirroring testMultiHopSwapChainsThroughTwoPools's
    // token3 pattern) with `lpBase`/`lpQuote` liquidity at a 5% tolerance, so callers can size
    // it either "well-stocked" (full match) or "thin" (partial match) for a given hop amount.
    function _setupSecondPool(uint256 lpBase, uint256 lpQuote) private returns (MockQuote token3, Pool secondPool) {
        token3 = new MockQuote("Quote2", "QUOTE2");
        token3.mint(lp1, 10000e18);

        matchingEngine.addPair(
            address(token1), address(token3), 1e8, 1, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        secondPool = Pool(poolFactory.getPool(address(token1), address(token3)));
        vm.warp(block.timestamp + 600);

        vm.prank(lp1);
        token1.approve(address(secondPool), lpBase);
        vm.prank(lp1);
        token3.approve(address(secondPool), lpQuote);
        vm.prank(positionManager);
        secondPool.addLiquidity(5e7, 15e7, 5000000, lpBase, lpQuote, lp1);
    }

    // Deploys a fresh PositionManager wired to both the pool factory and this test's router (via
    // setRouter), then lists a dedicated token1-quoted pair for it -- same "needs a freshly-listed
    // pair" reasoning as _setupSecondPool and testSingleHopPartialFillDepositsRemainderToLP.
    function _setupPositionManagerWithRouter() private returns (PositionManager pm, Pool posPool, MockQuote posToken) {
        pm = new PositionManager();
        pm.initialize("ipfs://iter-positions/{id}.json");
        pm.setPoolFactory(address(poolFactory));
        pm.setRouter(address(router));
        poolFactory.setPositionManager(address(pm));

        posToken = new MockQuote("Quote4", "QUOTE4");
        posToken.mint(lp1, 10000e18);

        matchingEngine.addPair(
            address(token1), address(posToken), 1e8, 1, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        posPool = Pool(poolFactory.getPool(address(token1), address(posToken)));
        vm.warp(block.timestamp + 600);
    }

    function testRouterRemoveLiquidityByOwnerSucceedsAndEmitsLiquidityRemoved() public {
        (PositionManager pm, Pool posPool, MockQuote posToken) = _setupPositionManagerWithRouter();

        vm.prank(lp1);
        token1.approve(address(posPool), 200e18);
        vm.prank(lp1);
        posToken.approve(address(posPool), 200e18);
        vm.prank(lp1);
        uint256 tokenId = pm.addLiquidity(address(posPool), 5e7, 15e7, 5000000, 200e18, 200e18);
        (, uint256 removedPositionId) = pm.tokenPosition(tokenId);

        uint256 lp1Token1Before = token1.balanceOf(lp1);

        vm.recordLogs();
        vm.prank(lp1);
        router.removeLiquidity(address(pm), tokenId, 200e18, 200e18, lp1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(token1.balanceOf(lp1), lp1Token1Before + 200e18);
        IPool.Position memory p = posPool.getPosition(removedPositionId);
        assertEq(p.baseAmount, 0);
        assertEq(p.quoteAmount, 0);

        Vm.Log memory remLog =
            _findLog(logs, keccak256("LiquidityRemoved(address,uint256,address,uint256,uint256)"), address(router));
        assertEq(remLog.topics[1], bytes32(uint256(uint160(address(posPool)))));
        assertEq(remLog.topics[2], bytes32(removedPositionId));
        assertEq(remLog.topics[3], bytes32(uint256(uint160(lp1))));
        (uint256 baseAmount, uint256 quoteAmount) = abi.decode(remLog.data, (uint256, uint256));
        assertEq(baseAmount, 200e18);
        assertEq(quoteAmount, 200e18);
    }

    function testRouterRemoveLiquidityByApprovedOperatorSucceeds() public {
        (PositionManager pm, Pool posPool, MockQuote posToken) = _setupPositionManagerWithRouter();

        vm.prank(lp1);
        token1.approve(address(posPool), 100e18);
        vm.prank(lp1);
        posToken.approve(address(posPool), 100e18);
        vm.prank(lp1);
        uint256 tokenId = pm.addLiquidity(address(posPool), 5e7, 15e7, 5000000, 100e18, 100e18);

        // lp1 never approves the router itself -- only trader1, as an ERC1155 operator on
        // PositionManager directly. removeLiquidityFor authorizes against `caller` (trader1, the
        // real msg.sender of the router call), so this works with no router-level approval at all.
        vm.prank(lp1);
        pm.setApprovalForAll(trader1, true);

        uint256 lp1Token1Before = token1.balanceOf(lp1);

        vm.prank(trader1);
        router.removeLiquidity(address(pm), tokenId, 100e18, 100e18, lp1);

        assertEq(token1.balanceOf(lp1), lp1Token1Before + 100e18);
    }

    function testRouterRemoveLiquidityRevertsForUnauthorizedCaller() public {
        (PositionManager pm, Pool posPool, MockQuote posToken) = _setupPositionManagerWithRouter();

        vm.prank(lp1);
        token1.approve(address(posPool), 100e18);
        vm.prank(lp1);
        posToken.approve(address(posPool), 100e18);
        vm.prank(lp1);
        uint256 tokenId = pm.addLiquidity(address(posPool), 5e7, 15e7, 5000000, 100e18, 100e18);

        // trader2 holds nothing and was never approved -- proves the router can't be used to
        // drain someone else's position just because the router itself is a trusted forwarder.
        vm.prank(trader2);
        vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotOwnerOrApproved.selector, tokenId, trader2));
        router.removeLiquidity(address(pm), tokenId, 100e18, 100e18, trader2);
    }

    function testRemoveLiquidityForRevertsWhenNotCalledByRouter() public {
        (PositionManager pm, Pool posPool, MockQuote posToken) = _setupPositionManagerWithRouter();

        vm.prank(lp1);
        token1.approve(address(posPool), 100e18);
        vm.prank(lp1);
        posToken.approve(address(posPool), 100e18);
        vm.prank(lp1);
        uint256 tokenId = pm.addLiquidity(address(posPool), 5e7, 15e7, 5000000, 100e18, 100e18);

        // Even the position's own owner can't bypass the router by calling removeLiquidityFor
        // directly -- onlyRouter doesn't care who `caller` claims to be, only who msg.sender is.
        vm.prank(lp1);
        vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotRouter.selector, lp1));
        pm.removeLiquidityFor(lp1, tokenId, 100e18, 100e18, lp1);
    }

    // Scans recorded logs for the first one matching `sig` emitted by `emitter` -- used instead of
    // vm.expectEmit for the new router-level events because their non-indexed fields (amountOut,
    // leftover, fee-adjusted amounts) depend on matching-engine internals the test would otherwise
    // have to duplicate; decoding the real emitted log after the fact and comparing it against the
    // call's own return value is exact without that duplication.
    function _findLog(Vm.Log[] memory logs, bytes32 sig, address emitter) private pure returns (Vm.Log memory) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig && logs[i].emitter == emitter) {
                return logs[i];
            }
        }
        revert("log not found");
    }

    function testSingleHopSwap() public {
        vm.prank(trader1);
        token2.approve(address(router), 100e18);

        address[] memory path = new address[](2);
        path[0] = address(token2);
        path[1] = address(token1);

        vm.prank(trader1);
        uint256 amountOut = router.swap(path, 100e18, 0, trader1, ISwapRouter.RemainderMode.Refund, empty);

        assertGt(amountOut, 0);
        assertGt(token1.balanceOf(trader1), 0);
    }

    function testSingleHopSwapEmitsHopExecutedAndSwapExecuted() public {
        vm.prank(trader1);
        token2.approve(address(router), 100e18);

        address[] memory path = new address[](2);
        path[0] = address(token2);
        path[1] = address(token1);

        vm.recordLogs();
        vm.prank(trader1);
        uint256 amountOut = router.swap(path, 100e18, 0, trader1, ISwapRouter.RemainderMode.Refund, empty);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Vm.Log memory hopLog = _findLog(
            logs, keccak256("HopExecuted(address,address,address,uint256,uint256,uint256)"), address(router)
        );
        assertEq(hopLog.topics[1], bytes32(uint256(uint160(address(pool)))));
        (address hopTokenIn, address hopTokenOut, uint256 hopAmountIn, uint256 hopAmountOut, uint256 hopLeftover) =
            abi.decode(hopLog.data, (address, address, uint256, uint256, uint256));
        assertEq(hopTokenIn, address(token2));
        assertEq(hopTokenOut, address(token1));
        assertEq(hopAmountIn, 100e18);
        assertEq(hopAmountOut, amountOut);
        assertEq(hopLeftover, 0);

        Vm.Log memory swapLog = _findLog(
            logs, keccak256("SwapExecuted(address,address,address,uint256,uint256)"), address(router)
        );
        assertEq(swapLog.topics[1], bytes32(uint256(uint160(trader1))));
        (address swapTokenIn, address swapTokenOut, uint256 swapAmountIn, uint256 swapAmountOut) =
            abi.decode(swapLog.data, (address, address, uint256, uint256));
        assertEq(swapTokenIn, address(token2));
        assertEq(swapTokenOut, address(token1));
        assertEq(swapAmountIn, 100e18);
        assertEq(swapAmountOut, amountOut);
    }

    function testMultiHopSwapEmitsHopExecutedPerHop() public {
        (MockQuote token3,) = _setupSecondPool(500e18, 500e18);

        vm.prank(trader1);
        token2.approve(address(router), 50e18);

        address[] memory path = new address[](3);
        path[0] = address(token2);
        path[1] = address(token1);
        path[2] = address(token3);

        vm.recordLogs();
        vm.prank(trader1);
        uint256 amountOut = router.swap(path, 50e18, 0, trader1, ISwapRouter.RemainderMode.Refund, empty);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 hopSig = keccak256("HopExecuted(address,address,address,uint256,uint256,uint256)");
        uint256 hopCount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == hopSig && logs[i].emitter == address(router)) {
                hopCount++;
            }
        }
        assertEq(hopCount, 2); // one HopExecuted per pool touched, regardless of leftover

        Vm.Log memory swapLog = _findLog(logs, keccak256("SwapExecuted(address,address,address,uint256,uint256)"), address(router));
        (,, uint256 swapAmountIn, uint256 swapAmountOut) = abi.decode(swapLog.data, (address, address, uint256, uint256));
        assertEq(swapAmountIn, 50e18);
        assertEq(swapAmountOut, amountOut);
        assertGt(token3.balanceOf(trader1), 0);
    }

    function testSingleHopSwapRevertsBelowMinAmountOut() public {
        vm.prank(trader1);
        token2.approve(address(router), 100e18);

        address[] memory path = new address[](2);
        path[0] = address(token2);
        path[1] = address(token1);

        vm.prank(trader1);
        vm.expectRevert();
        router.swap(path, 100e18, type(uint256).max, trader1, ISwapRouter.RemainderMode.Refund, empty);
    }

    function testSwapRevertsForUnknownPool() public {
        // Approve first -- without this, the call reverts at the initial
        // TransferHelper.safeTransferFrom (missing allowance) before ever reaching the pool
        // lookup, and a bare vm.expectRevert() would pass either way without proving
        // PoolDoesNotExist actually fires.
        vm.prank(trader1);
        token2.approve(address(router), 100e18);

        address[] memory path = new address[](2);
        path[0] = address(token2);
        path[1] = address(0xDEAD);

        vm.prank(trader1);
        vm.expectRevert(abi.encodeWithSelector(ISwapRouter.PoolDoesNotExist.selector, address(token2), address(0xDEAD)));
        router.swap(path, 100e18, 0, trader1, ISwapRouter.RemainderMode.Refund, empty);
    }

    function testMultiHopSwapChainsThroughTwoPools() public {
        (MockQuote token3,) = _setupSecondPool(500e18, 500e18);

        vm.prank(trader1);
        token2.approve(address(router), 50e18);

        address[] memory path = new address[](3);
        path[0] = address(token2);
        path[1] = address(token1);
        path[2] = address(token3);

        vm.prank(trader1);
        uint256 amountOut = router.swap(path, 50e18, 0, trader1, ISwapRouter.RemainderMode.Refund, empty);

        assertGt(amountOut, 0);
        assertGt(token3.balanceOf(trader1), 0);
    }

    // The behavior this whole task changed: a non-final hop's partial fill used to revert the
    // entire path (MidPathPartialFill). It no longer does -- the hop's matched output still
    // continues to the next hop, and its unmatched input is disposed of per `remainderMode`
    // immediately, same as any other hop's remainder.
    function testMidPathPartialFillRefundsInsteadOfReverting() public {
        // Shrink hop 1's liquidity so it can only partially fill; hop 2 still has ample
        // liquidity for whatever hop 1 actually produces.
        vm.prank(positionManager);
        pool.removeLiquidity(positionId, 995e18, 0, lp1); // leaves 5e18 base available
        (MockQuote token3,) = _setupSecondPool(500e18, 500e18);

        vm.prank(trader1);
        token2.approve(address(router), 1000e18);

        address[] memory path = new address[](3);
        path[0] = address(token2);
        path[1] = address(token1);
        path[2] = address(token3);

        // Independently compute hop 1's expected unfilled amount the same way Pool.swap does:
        // the shrunk position offers exactly 5e18 base (all of it, since 1000e18 quote demand
        // vastly exceeds it), matched at this pool's own 5% slippage bound (100e8 * 1.05).
        uint256 boundPrice = (100e8 * (1e8 + 5000000)) / 1e8;
        uint256 matchedQuoteSpent = book.convert(boundPrice, 5e18, true); // base->quote

        uint256 traderQuoteBefore = token2.balanceOf(trader1);

        vm.prank(trader1);
        uint256 amountOut = router.swap(path, 1000e18, 0, trader1, ISwapRouter.RemainderMode.Refund, empty);

        // The route completed: hop 2 matched hop 1's real 5e18 base output into token3.
        assertGt(amountOut, 0);
        assertGt(token3.balanceOf(trader1), 0);
        // Hop 1's unmatched quote came straight back to the trader, net spend == matchedQuoteSpent.
        assertEq(token2.balanceOf(trader1), traderQuoteBefore - matchedQuoteSpent);
    }

    function testMidPathPartialFillRestsRemainderAsOrder() public {
        vm.prank(positionManager);
        pool.removeLiquidity(positionId, 995e18, 0, lp1);
        (MockQuote token3,) = _setupSecondPool(500e18, 500e18);

        vm.prank(trader1);
        token2.approve(address(router), 1000e18);

        address[] memory path = new address[](3);
        path[0] = address(token2);
        path[1] = address(token1);
        path[2] = address(token3);

        uint256 traderQuoteBefore = token2.balanceOf(trader1);

        vm.prank(trader1);
        uint256 amountOut = router.swap(path, 1000e18, 0, trader1, ISwapRouter.RemainderMode.RestAsOrder, empty);

        assertGt(amountOut, 0);
        assertGt(token3.balanceOf(trader1), 0);
        // Nothing refunded to the wallet this time -- the whole 1000e18 quote left it, and the
        // unmatched portion is now an order, not a balance.
        assertEq(token2.balanceOf(trader1), traderQuoteBefore - 1000e18);

        (uint256 bidHead,) = matchingEngine.heads(address(token1), address(token2));
        assertGt(bidHead, 0);
        uint32 orderId = book.orderHead(true, bidHead);
        ExchangeOrderbook.Order memory restingOrder = book.getOrder(true, orderId);
        assertEq(restingOrder.owner, trader1);
    }

    function testSingleHopPartialFillRefundsRemainder() public {
        vm.prank(positionManager);
        pool.removeLiquidity(positionId, 995e18, 0, lp1);

        vm.prank(trader1);
        token2.approve(address(router), 1000e18);

        address[] memory path = new address[](2);
        path[0] = address(token2);
        path[1] = address(token1);

        uint256 boundPrice = (100e8 * (1e8 + 5000000)) / 1e8;
        uint256 matchedQuoteSpent = book.convert(boundPrice, 5e18, true);
        uint256 traderQuoteBefore = token2.balanceOf(trader1);

        vm.prank(trader1);
        uint256 amountOut = router.swap(path, 1000e18, 0, trader1, ISwapRouter.RemainderMode.Refund, empty);

        // The shrunk position had exactly 5e18 base available and all of it was consumed --
        // not merely "at most 5e18", the full available amount -- minus the taker fee applied
        // on the router's own balance-delta receipt (Orderbook._sendFunds, applyFee=true). The
        // explicit uint256(...) casts below are load-bearing, not stylistic: multiplying a
        // uint256 literal directly against a uint32 (takerFeeRate's declared type) resolves the
        // whole expression's mobile type down to uint32 under Solidity's literal-typing rules,
        // so 5e18 * takerFeeRate reverts with a checked-arithmetic panic despite the
        // mathematically correct product fitting uint256 easily -- confirmed by bisection while
        // writing this test.
        uint32 takerFeeRate = matchingEngine.feeOf(address(token1), address(token2), address(router), false);
        uint256 fee = (uint256(5e18) * uint256(takerFeeRate)) / matchingEngine.DENOM();
        assertEq(amountOut, 5e18 - fee);
        assertEq(token2.balanceOf(trader1), traderQuoteBefore - matchedQuoteSpent);
    }

    function testSingleHopPartialFillRestsRemainderAsOrder() public {
        vm.prank(positionManager);
        pool.removeLiquidity(positionId, 995e18, 0, lp1);

        vm.prank(trader1);
        token2.approve(address(router), 1000e18);

        address[] memory path = new address[](2);
        path[0] = address(token2);
        path[1] = address(token1);

        uint256 traderQuoteBefore = token2.balanceOf(trader1);

        vm.prank(trader1);
        uint256 amountOut = router.swap(path, 1000e18, 0, trader1, ISwapRouter.RemainderMode.RestAsOrder, empty);

        uint32 takerFeeRate = matchingEngine.feeOf(address(token1), address(token2), address(router), false);
        uint256 fee = (uint256(5e18) * uint256(takerFeeRate)) / matchingEngine.DENOM();
        assertEq(amountOut, 5e18 - fee);
        assertEq(token2.balanceOf(trader1), traderQuoteBefore - 1000e18);

        (uint256 bidHead,) = matchingEngine.heads(address(token1), address(token2));
        assertGt(bidHead, 0);
        uint32 orderId = book.orderHead(true, bidHead);
        ExchangeOrderbook.Order memory restingOrder = book.getOrder(true, orderId);
        assertEq(restingOrder.owner, trader1);
    }

    // DepositToLP needs the pool's own `positionManager` to be a real PositionManager contract
    // -- PoolBaseSetup wires the default token1/token2 pool to a placeholder address (0xBEEF)
    // before any test runs, and that's baked in at Pool.initialize time with no setter, so this
    // mode is exercised on a dedicated, freshly-listed pair instead (same pattern
    // PositionManagerAddLiquidity.t.sol uses for the same reason).
    function testSingleHopPartialFillDepositsRemainderToLP() public {
        PositionManager pm = new PositionManager();
        pm.initialize("ipfs://iter-positions/{id}.json");
        poolFactory.setPositionManager(address(pm));

        MockQuote token4 = new MockQuote("Quote3", "QUOTE3");
        token4.mint(lp1, 10000e18);
        token4.mint(trader1, 10000e18);

        matchingEngine.addPair(
            address(token1), address(token4), 1e8, 1, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        Pool thirdPool = Pool(poolFactory.getPool(address(token1), address(token4)));
        vm.warp(block.timestamp + 600);

        vm.prank(lp1);
        token1.approve(address(thirdPool), 5e18);
        // thirdPool was created AFTER poolFactory.setPositionManager(pm) above, so its own
        // wired positionManager is the real `pm`, not the placeholder 0xBEEF the default
        // token1/token2 pool got at its own creation time -- prank the real one here.
        vm.prank(address(pm));
        thirdPool.addLiquidity(5e7, 15e7, 5000000, 5e18, 0, lp1); // base-only, thin: 5e18 total

        vm.prank(trader1);
        token4.approve(address(router), 1000e18);

        address[] memory path = new address[](2);
        path[0] = address(token4);
        path[1] = address(token1);

        ISwapRouter.RemainderConfig memory cfg =
            ISwapRouter.RemainderConfig({restPrice: 0, lpMinPrice: 5e7, lpMaxPrice: 15e7, lpSlippageLimit: 5000000});

        vm.recordLogs();
        vm.prank(trader1);
        uint256 amountOut = router.swap(path, 1000e18, 0, trader1, ISwapRouter.RemainderMode.DepositToLP, cfg);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint32 takerFeeRate = matchingEngine.feeOf(address(token1), address(token4), address(router), false);
        uint256 fee = (uint256(5e18) * uint256(takerFeeRate)) / matchingEngine.DENOM();
        assertEq(amountOut, 5e18 - fee);
        // PositionManager.nextTokenId increments from 0 via ++nextTokenId in addLiquidity, so
        // the first-ever mint on this fresh instance is always id 1.
        uint256 tokenId = 1;
        assertEq(pm.balanceOf(trader1, tokenId), 1);
        (address posPool, uint256 posId) = pm.tokenPosition(tokenId);
        assertEq(posPool, address(thirdPool));
        IPool.Position memory p = thirdPool.getPosition(posId);
        assertEq(p.baseAmount, 0);
        assertGt(p.quoteAmount, 0);

        // SwapRouter mirrors IPool.LiquidityAdded from its own address so an indexer watching
        // only SwapRouter sees this remainder-originated position without also watching thirdPool.
        Vm.Log memory liqLog = _findLog(
            logs,
            keccak256("LiquidityAdded(address,uint256,address,uint256,uint256,uint32,uint256,uint256)"),
            address(router)
        );
        assertEq(liqLog.topics[1], bytes32(uint256(uint160(address(thirdPool)))));
        assertEq(liqLog.topics[2], bytes32(posId));
        assertEq(liqLog.topics[3], bytes32(uint256(uint160(trader1))));
        (uint256 minPrice, uint256 maxPrice, uint32 slippageLimit, uint256 baseAmount, uint256 quoteAmount) =
            abi.decode(liqLog.data, (uint256, uint256, uint32, uint256, uint256));
        assertEq(minPrice, 5e7);
        assertEq(maxPrice, 15e7);
        assertEq(slippageLimit, 5000000);
        assertEq(baseAmount, 0);
        assertEq(quoteAmount, p.quoteAmount);
    }
}
