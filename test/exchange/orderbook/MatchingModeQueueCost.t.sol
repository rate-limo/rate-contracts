// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8;

import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {Orderbook} from "../../../src/exchange/orderbooks/Orderbook.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {console} from "forge-std/console.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";

/// The queue jam is a property of the MATCHING MODE, not of the orderbook.
///
/// PoC_UnboundedOrderQueue shows placing an order costs O(depth) and eventually dies
/// out-of-gas with no return data. What it does not say is that this is avoidable today,
/// with no new data structure: ExchangeOrderbook._insertId returns through _insertFifo
/// for PriceTimePriority (line 44) and only falls through to the `while (head != 0)` walk
/// for SizePriority. _insertFifo appends via a tail pointer, so it is O(1).
///
/// Every addPair call site in contracts/script hardcoded SizePriority, so the vulnerable
/// mode was the de-facto default on every chain. This pins the difference so that choice
/// cannot be made again by accident.
contract MatchingModeQueueCost is BaseSetup {
    uint256 constant PRICE = 100e8;
    uint256 constant DEPTH = 300;

    function _listWith(ExchangeOrderbook.MatchingMode mode) internal {
        matchingEngine.addPair(address(token1), address(token2), PRICE, 0, address(token1), mode);
        book = Orderbook(payable(orderbookFactory.getPair(address(token1), address(token2))));
    }

    /// Descending size, so SizePriority must append at the tail every time -- the worst
    /// case, and the one a real book of similar-sized orders naturally produces.
    function _stack(uint256 count, uint256 startAmount) internal {
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

    function _marginalGas() internal returns (uint256 shallow, uint256 deep) {
        _stack(1, 1000e18);
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
        shallow = g0 - gasleft();

        _stack(DEPTH, 900e18);

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
        deep = g0 - gasleft();
    }

    /// Insert cost is flat regardless of how many orders rest at the price.
    function test_priceTimePriority_insertCostIsFlat() public {
        _listWith(ExchangeOrderbook.MatchingMode.PriceTimePriority);
        (uint256 shallow, uint256 deep) = _marginalGas();
        console.log("PTP           shallow:", shallow);
        console.log("PTP           deep   :", deep);
        // Allowed a little slack for warm/cold storage differences, but nothing
        // resembling the linear growth above.
        assertLt(deep, (shallow * 3) / 2, "PTP insert must not scale with queue depth");
    }
}
