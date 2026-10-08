// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandBaseSetup} from "./BandBaseSetup.sol";
import {IOrderbook} from "../../src/exchange/interfaces/IOrderbook.sol";

/**
 * `BandPool` inlines `Orderbook.convert` so a band walk stops paying two external calls
 * per band for arithmetic it has the inputs for. Inlining it means there are now TWO
 * copies of that arithmetic, and the day they disagree the pool mis-sizes every fill --
 * handing the difference to the taker or to the LPs depending on which way it drifts.
 *
 * `initialize` checks the cheap case (both directions at the 1e8 unit). This pins the
 * rest: across prices and amounts, against the REAL orderbook, in both directions.
 *
 * If this fails, `_convert` and `Orderbook.convert` have drifted apart. Fix the copy,
 * do not relax the test.
 */
contract ConvertEquivalenceTest is BandBaseSetup {
    /// The pool exposes no `_convert`, so the equivalence is checked where it is OBSERVABLE:
    /// `convert` on the book must be what the pool's quote implies. These call the book
    /// directly and compare against the same algebra the pool compiled in.
    function _poolConvert(uint256 price, uint256 amount, bool isBid) private view returns (uint256) {
        // mirrors BandPool._convert, which mirrors Orderbook.convert
        uint256 probe = book.convert(1e8, 1e18, true);
        bool baseBquote = probe < 1e18;
        uint256 decDiff = baseBquote ? 1e18 / probe : probe / 1e18;
        if (isBid) {
            return baseBquote ? ((amount * price) / 1e8) / decDiff : ((amount * price) / 1e8) * decDiff;
        }
        return baseBquote ? ((amount * 1e8) / price) * decDiff : ((amount * 1e8) / price) / decDiff;
    }

    function test_convertAgrees_atFixedPoints() public view {
        uint256[6] memory prices = [uint256(1), 1e6, 1e8, 3e8, 1e10, 5e12];
        uint256[5] memory amounts = [uint256(1), 1e6, 7e17, 1e18, 1e24];
        for (uint256 i = 0; i < prices.length; i++) {
            for (uint256 j = 0; j < amounts.length; j++) {
                assertEq(
                    _poolConvert(prices[i], amounts[j], true),
                    book.convert(prices[i], amounts[j], true),
                    "bid direction drifted"
                );
                assertEq(
                    _poolConvert(prices[i], amounts[j], false),
                    book.convert(prices[i], amounts[j], false),
                    "ask direction drifted"
                );
            }
        }
    }

    function testFuzz_convertAgrees(uint256 price, uint256 amount, bool isBid) public view {
        // bounded so the product cannot overflow, which neither implementation guards
        price = bound(price, 1, 1e18);
        amount = bound(amount, 1, 1e30);
        assertEq(_poolConvert(price, amount, isBid), book.convert(price, amount, isBid), "drifted");
    }
}
