pragma solidity >=0.8;

import {MockToken} from "../../../src/mock/MockToken.sol";
import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {IOrderbook} from "../../../src/exchange/interfaces/IOrderbook.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {console} from "forge-std/console.sol";

/**
 * FIXED 2026-08-05. This began as a PoC: when a pair's base token had far fewer
 * decimals than its quote (e.g. 0-decimal base vs 6-decimal quote), the
 * dust-closeout in `_decreaseOrder` handed the taker the maker's ENTIRE remaining
 * deposit instead of the `converted` amount their delivered size earned — because
 * `dust = convert(price, 1, isBid)` scaled by `decDiff` and could be economically
 * large (500 whole USDC at the numbers below).
 *
 * The threshold is gone. `_decreaseOrder` now deletes only on `clear` or on a
 * genuinely empty remainder, and an unfillable leftover is evicted and REFUNDED TO
 * ITS OWNER by `Orderbook.fpop`. So the value goes back to the maker rather than to
 * whoever happened to trade against them. The test now pins that.
 *
 * `_deposit`'s own `OrderSizeTooSmall` guard independently rejects any order
 * whose own delivered amount is exactly 1 raw unit (converted == minRequired
 * when amount == 1, always), so the smallest fill that can even reach
 * `execute()` is 2 raw units. Numbers below use that floor: maker rests a
 * bid worth `converted(2 units) + dust` so the leftover after a fair 2-unit
 * fill lands exactly on the dust boundary.
 */
contract DecimalsDustBonusTest is BaseSetup {
    function testDustClosoutNoLongerGivesTakerTheMakersDeposit() public {
        super.setUp();

        // 0-decimal base (e.g. a whole-unit "shares" token), 6-decimal quote (like USDC).
        MockToken zeroDecBase = new MockToken("ZeroDec", "ZD", 0);
        MockToken sixDecQuote = new MockToken("SixDec", "SIX", 6);

        // Isolate the dust-closeout effect from fee accounting.
        matchingEngine.setDefaultFee(true, 0);
        matchingEngine.setDefaultFee(false, 0);

        // price = 500 (human) -> 500 * 1e8 on-chain (8-decimal fixed point, DENOM = 1e8).
        uint256 price = 500 * 1e8;
        matchingEngine.addPair(address(zeroDecBase), address(sixDecQuote), price, 0, address(zeroDecBase), ExchangeOrderbook.MatchingMode.PriceTimePriority);

        // dust = convert(price, 1, isBid=true) = ((1*price)/1e8) * decDiff(1e6) = 500 * 1e6 raw quote units = 500 SIX.
        // `_deposit`'s own OrderSizeTooSmall guard rejects amount=1 (converted==minRequired
        // always at amount=1), so the smallest fill that reaches execute() is amount=2,
        // fair-valued at 2*500 = 1000 SIX. Maker rests a bid worth that fair value plus
        // exactly one more `dust` (1500 SIX), so the leftover after a fair 2-unit fill
        // (1500 - 1000 = 500) lands exactly on the dust boundary.
        uint256 fairValueForAmountDelivered = 1000 * 1e6; // 1000 SIX: fair value of a 2-unit fill
        uint256 dust = 500 * 1e6; // 500 SIX
        uint256 makerDeposit = fairValueForAmountDelivered + dust; // 1500 SIX
        sixDecQuote.mint(trader1, makerDeposit);
        vm.prank(trader1);
        sixDecQuote.approve(address(matchingEngine), makerDeposit);
        vm.prank(trader1);
        matchingEngine.limitBuy(address(zeroDecBase), address(sixDecQuote), price, makerDeposit, true, 5, trader1);

        // Attacker fills with the smallest fill size the size-guard allows: 2 raw base tokens.
        uint256 attackerFillAmount = 2;
        zeroDecBase.mint(attacker, attackerFillAmount);
        vm.prank(attacker);
        zeroDecBase.approve(address(matchingEngine), attackerFillAmount);

        uint256 quoteBalanceBefore = sixDecQuote.balanceOf(attacker);
        uint256 makerBaseBalanceBefore = zeroDecBase.balanceOf(trader1);
        vm.prank(attacker);
        matchingEngine.limitSell(address(zeroDecBase), address(sixDecQuote), price, attackerFillAmount, true, 5, attacker);
        uint256 quoteBalanceAfter = sixDecQuote.balanceOf(attacker);
        uint256 makerBaseBalanceAfter = zeroDecBase.balanceOf(trader1);

        uint256 actuallyReceived = quoteBalanceAfter - quoteBalanceBefore;
        uint256 makerBaseReceived = makerBaseBalanceAfter - makerBaseBalanceBefore;

        console.log("fair value for the 2 raw base tokens delivered (SIX, 6dec):", fairValueForAmountDelivered);
        console.log("actually received (SIX, 6dec):                             ", actuallyReceived);
        console.log("maker base tokens received:                                ", makerBaseReceived);

        // Fixed: the taker receives exactly what their 2-unit delivery was worth.
        // No `dust` bonus, because there is no longer a dust threshold to trigger one.
        assertEq(actuallyReceived, fairValueForAmountDelivered, "taker receives fair value, not the maker's deposit");
        assertLt(actuallyReceived, makerDeposit, "taker must NOT receive the maker's full remaining deposit");
        assertEq(makerDeposit - actuallyReceived, dust, "the disputed `dust` stays with the maker");

        // The maker still receives only what was delivered to them -- but they keep
        // the unspent 500 SIX as a resting remainder instead of losing it. That
        // remainder converts to zero base and so can never fill: the next taker to
        // reach it triggers fpop's eviction, which refunds it and emits OrderDusted.
        assertEq(makerBaseReceived, attackerFillAmount, "maker receives the base actually delivered");
        assertFalse(
            IOrderbook(matchingEngine.getPair(address(zeroDecBase), address(sixDecQuote)))
                .isEmpty(true, price),
            "the maker's remainder is still theirs, resting, awaiting eviction+refund"
        );
    }

    /**
     * Mirror finding for an ETH(18dec)/USDC(6dec)-shaped pair at a realistic
     * price (~$3000): `dust` itself floors to 0, so the bonus above cannot
     * occur here -- but the anti-dust cleanup in `_decreaseOrder` degenerates
     * to "only clears an order that's already at exactly zero", meaning true
     * leftover dust CAN persist unfilled on the book. Also confirms the
     * `OrderSizeTooSmall` minimum order size for this pair/price is a mere
     * 3000 raw quote units ($0.003).
     */
    function testEthUsdcShapedPairDustFloorsToZero() public {
        super.setUp();

        MockToken eighteenDecBase = new MockToken("EighteenDec", "E18", 18); // ETH-shaped
        MockToken sixDecQuote = new MockToken("SixDec", "SIX", 6); // USDC-shaped

        uint256 price = 3000 * 1e8; // $3000, 8-decimal fixed point
        matchingEngine.addPair(address(eighteenDecBase), address(sixDecQuote), price, 0, address(eighteenDecBase), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        address pair = matchingEngine.getPair(address(eighteenDecBase), address(sixDecQuote));

        uint256 dustBuySide = IOrderbook(pair).convert(price, 1, false); // 1 raw quote unit -> base
        uint256 dustSellSide = IOrderbook(pair).convert(price, 1, true); // 1 raw base unit -> quote
        assertEq(dustBuySide, 0, "buy-side dust should floor to zero for this decimals/price combo");
        assertEq(dustSellSide, 0, "sell-side dust should floor to zero for this decimals/price combo");

        // Minimum order size in this direction: smallest amount whose converted
        // value exceeds convert(price, 1, ...) == 0, i.e. any nonzero conversion.
        uint256 justBelowMin = IOrderbook(pair).convert(price, 2999, false);
        uint256 atMin = IOrderbook(pair).convert(price, 3000, false);
        assertEq(justBelowMin, 0, "2999 raw USDC-like units should still convert to zero base");
        assertGt(atMin, 0, "3000 raw USDC-like units ($0.003) is the minimum that converts to nonzero base");
    }
}
