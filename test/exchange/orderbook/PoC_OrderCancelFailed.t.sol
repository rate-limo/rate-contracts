// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8;

import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {Orderbook} from "../../../src/exchange/orderbooks/Orderbook.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";
import {MatchingEngine} from "../../../src/exchange/MatchingEngine.sol";
import {console} from "forge-std/console.sol";

/// Traces exactly what a failed cancel returns, layer by layer.
///
/// MatchingEngine.cancelOrder wraps Orderbook.cancelOrder in try/catch and re-throws the
/// raw catch bytes inside OrderCancelFailed(..., bytes reason). That produces a
/// TWO-LAYER revert: an outer MatchingEngine error whose last field is an inner Orderbook
/// error, ABI-encoded as opaque bytes.
///
/// Both layers are undecodable by the ABI the app actually ships:
///   - outer OrderCancelFailed is missing from apps/web/components/abis/MatchingEngine.json
///     and from packages/abis/src/matchingEngine.ts (verified by script, both copies)
///   - inner InvalidAccess lives in Orderbook's ABI, which the frontend does not ship at all
contract PoCOrderCancelFailed is BaseSetup {
    uint256 constant PRICE = 100e8;

    error InvalidAccess(address sender, address allowed);

    function _selectorOf(bytes memory b) internal pure returns (bytes4 sel) {
        if (b.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(b, 32))
        }
    }

    function _list() internal {
        matchingEngine.addPair(
            address(token1), address(token2), PRICE, 0, address(token1),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        book = Orderbook(payable(orderbookFactory.getPair(address(token1), address(token2))));
    }

    /// Cancel an order that no longer exists -- the single most common cancel failure:
    /// the order filled between the user opening the UI and the transaction landing.
    function test_PoC_cancelFilledOrder_producesTwoLayerUndecodableRevert() public {
        _list();

        // trader1 rests an ask; trader2 takes it in full, so the order is gone.
        vm.prank(trader1);
        IMatchingEngine.OrderResult memory placed =
            matchingEngine.limitSell(
                IMatchingEngine.LimitOrderInput({
                    base: address(token1),
                    quote: address(token2),
                    price: PRICE,
                    amount: 10e18,
                    isMaker: true,
                    n: 2,
                    recipient: trader1
                })
            );
        assertGt(placed.id, 0, "order rested");

        vm.prank(trader2);
        matchingEngine.marketBuy(
            IMatchingEngine.MarketOrderInput({
                base: address(token1),
                quote: address(token2),
                amount: 5000e18,
                isMaker: false,
                n: 5,
                recipient: trader2,
                slippageLimit: 100000
            })
        );

        assertEq(
            matchingEngine.getOrder(address(token1), address(token2), false, placed.id).owner,
            address(0),
            "order is gone -- owner reads as address(0)"
        );

        // trader1 now cancels the order they still believe is open.
        bytes memory callData = abi.encodeWithSelector(
            MatchingEngine.cancelOrder.selector, address(token1), address(token2), false, placed.id
        );
        vm.prank(trader1);
        (bool ok, bytes memory ret) = address(matchingEngine).call(callData);

        assertFalse(ok, "cancel reverts");
        console.log("raw returndata (%s bytes):", ret.length);
        console.logBytes(ret);

        // ---- Layer 1: the outer MatchingEngine error --------------------------------
        bytes4 outerSel = _selectorOf(ret);
        console.log("outer selector (OrderCancelFailed):");
        console.logBytes4(outerSel);
        assertEq(outerSel, MatchingEngine.OrderCancelFailed.selector, "outer is OrderCancelFailed");

        (address ob, uint32 id, bool isBid, address sender, bytes memory reason) =
            abi.decode(_stripSelector(ret), (address, uint32, bool, address, bytes));
        assertEq(ob, address(book));
        assertEq(id, placed.id);
        assertFalse(isBid);
        assertEq(sender, trader1);

        // ---- Layer 2: the inner Orderbook error, carried as opaque bytes ------------
        bytes4 innerSel = _selectorOf(reason);
        console.log("inner selector (Orderbook.InvalidAccess):");
        console.logBytes4(innerSel);
        console.log("inner reason length:", reason.length);
        assertEq(innerSel, InvalidAccess.selector, "inner is Orderbook.InvalidAccess");

        (address who, address allowed) = abi.decode(_stripSelector(reason), (address, address));
        console.log("InvalidAccess.sender :", who);
        console.log("InvalidAccess.allowed:", allowed);
        assertEq(who, trader1, "caller");
        assertEq(allowed, address(0), "order owner is zero -- the order does not exist");
    }

    /// The tolerant batch path does not revert -- it emits and returns a zero refund.
    /// A UI that only watches for a revert reads this as "cancelled successfully".
    function test_PoC_cancelOrders_batchSwallowsTheFailureEntirely() public {
        _list();

        vm.prank(trader1);
        IMatchingEngine.OrderResult memory placed =
            matchingEngine.limitSell(
                IMatchingEngine.LimitOrderInput({
                    base: address(token1),
                    quote: address(token2),
                    price: PRICE,
                    amount: 10e18,
                    isMaker: true,
                    n: 2,
                    recipient: trader1
                })
            );

        vm.prank(trader2);
        matchingEngine.marketBuy(
            IMatchingEngine.MarketOrderInput({
                base: address(token1),
                quote: address(token2),
                amount: 5000e18,
                isMaker: false,
                n: 5,
                recipient: trader2,
                slippageLimit: 100000
            })
        );

        IMatchingEngine.CancelOrderInput[] memory batch = new IMatchingEngine.CancelOrderInput[](1);
        batch[0] = IMatchingEngine.CancelOrderInput({
            base: address(token1), quote: address(token2), isBid: false, orderId: placed.id
        });

        vm.prank(trader1);
        uint256[] memory refunded = matchingEngine.cancelOrders(batch);

        // No revert. No error. Just a zero, indistinguishable from "cancelled an
        // already-empty order" -- the failure lives only in the OrderCancelSkipped event.
        assertEq(refunded[0], 0, "silent zero refund, transaction succeeds");
        console.log("cancelOrders returned refund:", refunded[0]);
    }

    function _stripSelector(bytes memory b) internal pure returns (bytes memory out) {
        out = new bytes(b.length - 4);
        for (uint256 i = 4; i < b.length; i++) {
            out[i - 4] = b[i];
        }
    }
}
