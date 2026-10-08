pragma solidity >=0.8;

import {MockToken} from "../../../src/mock/MockToken.sol";
import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {IOrderbook} from "../../../src/exchange/interfaces/IOrderbook.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {console} from "forge-std/console.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";

/** Measures the eviction transaction itself, so the OrderDusted emit can be
 *  isolated from the ~21M of shared setUp. Asserts nothing about the event, so
 *  it runs identically with and without the emit. */
contract GasProbeOrderDustedTest is BaseSetup {
    function testGasOfTheEvictingSweep() public {
        super.setUp();
        MockToken base18 = new MockToken("Eighteen", "E18", 18);
        MockToken quote6 = new MockToken("SixDec", "SIX", 6);
        matchingEngine.setDefaultFee(true, 0);
        matchingEngine.setDefaultFee(false, 0);
        uint256 price = 3000 * 1e8;
        matchingEngine.addPair(address(base18), address(quote6), price, 0, address(base18),
            ExchangeOrderbook.MatchingMode.PriceTimePriority);

        uint256 deposit = 20000;
        quote6.mint(trader1, deposit);
        vm.prank(trader1); quote6.approve(address(matchingEngine), deposit);
        vm.prank(trader1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base18),
                quote: address(quote6),
                price: price,
                amount: deposit,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );

        // Since 2026-10-04 the eviction happens in THIS fill, the one that leaves the
        // 2,600 remainder (MatchingLib._evictIfDust), so this is the transaction to
        // measure; the sweep after it finds nothing left to evict.
        uint256 firstFill = 5.8e12;
        base18.mint(trader2, firstFill);
        vm.prank(trader2); base18.approve(address(matchingEngine), firstFill);
        vm.prank(trader2);
        uint256 gFill = gasleft();
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(base18),
                quote: address(quote6),
                price: price,
                amount: firstFill,
                isMaker: true,
                n: 5,
                recipient: trader2
            })
        );
        console.log("partial fill that evicts its dust, gas:", gFill - gasleft());

        uint256 sell = 1e15;
        base18.mint(attacker, sell);
        vm.prank(attacker); base18.approve(address(matchingEngine), sell);

        vm.prank(attacker);
        uint256 g0 = gasleft();
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(base18),
                quote: address(quote6),
                price: price,
                amount: sell,
                isMaker: true,
                n: 5,
                recipient: attacker
            })
        );
        uint256 used = g0 - gasleft();
        console.log("sweep after it (nothing to evict) gas:", used);
    }

    /** The common path for comparison: an ordinary partial fill, no eviction. */
    function testGasOfAnOrdinaryPartialFill() public {
        super.setUp();
        MockToken base18 = new MockToken("Eighteen", "E18", 18);
        MockToken quote6 = new MockToken("SixDec", "SIX", 6);
        matchingEngine.setDefaultFee(true, 0);
        matchingEngine.setDefaultFee(false, 0);
        uint256 price = 3000 * 1e8;
        matchingEngine.addPair(address(base18), address(quote6), price, 0, address(base18),
            ExchangeOrderbook.MatchingMode.PriceTimePriority);

        uint256 deposit = 20000;
        quote6.mint(trader1, deposit);
        vm.prank(trader1); quote6.approve(address(matchingEngine), deposit);
        vm.prank(trader1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base18),
                quote: address(quote6),
                price: price,
                amount: deposit,
                isMaker: true,
                n: 5,
                recipient: trader1
            })
        );

        // 5e12 leaves 5,000 raw quote, which still converts to base: a partial fill
        // with nothing to evict. (5.8e12 would leave dust, which is now evicted in
        // the same fill and would no longer be the ordinary path.)
        uint256 fill = 5e12;
        base18.mint(trader2, fill);
        vm.prank(trader2); base18.approve(address(matchingEngine), fill);

        vm.prank(trader2);
        uint256 g0 = gasleft();
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(base18),
                quote: address(quote6),
                price: price,
                amount: fill,
                isMaker: true,
                n: 5,
                recipient: trader2
            })
        );
        console.log("ordinary partial fill gas:", g0 - gasleft());
    }
}
