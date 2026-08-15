// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8;

import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {Orderbook} from "../../../src/exchange/orderbooks/Orderbook.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {MatchingEngine} from "../../../src/exchange/MatchingEngine.sol";
import {console} from "forge-std/console.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";

/// Regression for the unbounded order-queue jam.
///
/// This file replaces PoC_UnboundedOrderQueue.t.sol, whose two tests asserted that the
/// jam EXISTS: insert cost growing linearly with queue depth, and a limit order dying
/// out-of-gas with zero return data at a 700k cap. Both now fail, because SizePriority —
/// the only mode that walked the queue — was removed on 2026-08-06. Deleting them would
/// have thrown away the only executable description of the bug, so the assertions are
/// inverted instead: same setup, opposite expectation.
///
/// What made the original bug dangerous was not the gas, it was the silence. The revert
/// carried NO return data — not TooManyMatches, not OrderSizeTooSmall — so viem had
/// nothing to decode and the UI had nothing to explain. Any future change that
/// reintroduces a per-insert traversal fails here rather than in production.
contract UnboundedOrderQueueRegression is BaseSetup {
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

    /// DESCENDING deposit size on purpose: this is the ordering that forced SizePriority
    /// to append at the tail every time, walking the whole list. It is the worst case for
    /// the old code and must stay the shape under test.
    function _stackAsks(uint256 count, uint256 startAmount) internal {
        for (uint256 i = 0; i < count; i++) {
            vm.prank(trader1);
            matchingEngine.limitSell(
                IMatchingEngine.LimitOrderInput({
                    base: address(token1),
                    quote: address(token2),
                    price: PRICE,
                    amount: startAmount - i * 1e6,
                    isMaker: true,
                    n: 2,
                    recipient: trader1
                })
            );
        }
    }

    function test_insertGasDoesNotGrowWithQueueDepth() public {
        _list();
        _stackAsks(1, 1000e18);

        uint256 g0 = gasleft();
        vm.prank(trader1);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: PRICE,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        uint256 shallow = g0 - gasleft();

        _stackAsks(400, 900e18);

        g0 = gasleft();
        vm.prank(trader1);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: PRICE,
                amount: 1e17,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        uint256 deep = g0 - gasleft();

        console.log("limitSell gas, ~2 resting orders  :", shallow);
        console.log("limitSell gas, ~400 resting orders:", deep);

        // The old path went 154,199 -> 412,505 here (~645 gas per resting order). A little
        // slack for warm/cold storage, but nothing that scales with depth.
        assertLt(deep, (shallow * 3) / 2, "insert cost must not scale with queue depth");
    }

    /// The user-visible half: with a deep queue, a plain limit order used to die
    /// out-of-gas at a wallet-realistic cap and return ZERO bytes. It must now succeed.
    function test_limitOrderSucceedsAtWalletGasCapOnDeepQueue() public {
        _list();
        _stackAsks(1200, 5000e18);

        bytes memory callData = abi.encodeWithSelector(
            MatchingEngine.limitSell.selector,
            address(token1),
            address(token2),
            PRICE,
            uint256(1e16),
            true,
            uint32(2),
            trader1
        );

        vm.prank(trader1);
        (bool ok, bytes memory ret) = address(matchingEngine).call{gas: 700_000}(callData);

        assertTrue(ok, "a limit order on a 1200-deep queue must fit in a wallet gas cap");
        console.log("returndata length on success:", ret.length);
    }
}
