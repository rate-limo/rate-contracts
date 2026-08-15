pragma solidity >=0.8;

import {MockToken} from "../../../src/mock/MockToken.sol";
import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {IOrderbook} from "../../../src/exchange/interfaces/IOrderbook.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {console} from "forge-std/console.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";

/**
 * Does leftover dust affect a real trader, or is it only an accounting curiosity?
 *
 * `MatchingLib.matchAt` spends one unit of the taker's match budget on every order
 * it walks past, INCLUDING one it merely evicts:
 *
 *     } else if (required == 0) { ++matchAtInput.i; continue; }
 *
 * and the loop is gated on `matchAtInput.i < matchAtInput.n`. So an order it merely
 * evicts still costs the taker one of their `n` matches.
 *
 * FIXED 2026-08-05: an eviction is now counted against a separate
 * `MAX_DUST_EVICTIONS` cap instead of the taker's `n`. They received no fill, so
 * charging them a match let a queue of other people's remainders starve their
 * order. Both modes are still tested, because the mode is what decided whether the
 * old behaviour reached a user:
 *
 *  - **SizePriority** sorts a level by deposit descending. Dust is by construction
 *    smaller than the minimum order size, so it sorts BEHIND every fillable order
 *    and a taker reaches real liquidity first. Leftover budget then evicts dust as
 *    a side effect -- opportunistic cleanup, not starvation.
 *  - **PriceTimePriority** is FIFO, so a partially filled order stays at the HEAD
 *    and its unfillable remainder sits in front of everything behind it. Each one
 *    costs the next taker a match from a budget capped at `maxMatches`.
 *
 * Written to check a hypothesis that turned out to be wrong for SizePriority and
 * right for FIFO. Both cases are kept, because the answer to "does dust hurt
 * traders" is "only on FIFO pairs" and that is worth pinning.
 */
contract PoCDustEatsMatchBudgetTest is BaseSetup {
    MockToken base18;
    MockToken quote6;
    uint256 constant PRICE = 3000 * 1e8;
    address pair;

    function _setUpPair(ExchangeOrderbook.MatchingMode mode) internal {
        base18 = new MockToken("Eighteen", "E18", 18);
        quote6 = new MockToken("SixDec", "SIX", 6);
        matchingEngine.setDefaultFee(true, 0);
        matchingEngine.setDefaultFee(false, 0);
        matchingEngine.addPair(
            address(base18), address(quote6), PRICE, 0, address(base18), mode
        );
        pair = matchingEngine.getPair(address(base18), address(quote6));
        // Precondition: the anti-dust threshold is zero here, so leftovers persist.
        assertEq(IOrderbook(pair).convert(PRICE, 1, true), 0, "dust threshold must floor to zero");
    }

    /** Orders with a live deposit at the best bid. getOrders pads its array, so
     *  entries must be counted by deposit, not by length. */
    function _resting() internal view returns (uint256 n) {
        ExchangeOrderbook.Order[] memory os = IOrderbook(pair).getOrders(true, PRICE, 10);
        for (uint256 i = 0; i < os.length; i++) if (os[i].depositAmount > 0) n++;
    }

    /** Rests a bid and partially fills it, leaving a sub-minimum remainder behind. */
    function _leaveDustOrder(address maker, address filler) internal {
        uint256 deposit = 20000; // raw quote
        quote6.mint(maker, deposit);
        vm.prank(maker);
        quote6.approve(address(matchingEngine), deposit);
        vm.prank(maker);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base18),
                quote: address(quote6),
                price: PRICE,
                amount: deposit,
                isMaker: true,
                n: 5,
                recipient: maker
            })
        );

        uint256 fill = 5.8e12; // consumes 17,400, leaving 2,600 -- below the 3,000 floor
        base18.mint(filler, fill);
        vm.prank(filler);
        base18.approve(address(matchingEngine), fill);
        vm.prank(filler);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(base18),
                quote: address(quote6),
                price: PRICE,
                amount: fill,
                isMaker: true,
                n: 5,
                recipient: filler
            })
        );
    }

    function testDustOrdersConsumeTheNextTakersMatchBudget() public {
        super.setUp();
        _setUpPair(ExchangeOrderbook.MatchingMode.PriceTimePriority);

        // Three leftovers at the best price, each unfillable.
        _leaveDustOrder(trader1, trader2);
        console.log("resting after 1st:", _resting());
        _leaveDustOrder(address(0xD1), trader2);
        console.log("resting after 2nd:", _resting());
        _leaveDustOrder(address(0xD2), trader2);
        console.log("resting after 3rd:", _resting());

        // A real, fillable order behind them.
        uint256 realDeposit = 3_000_000; // 3 USDC -> comfortably above the floor
        quote6.mint(address(0xBEEF), realDeposit);
        vm.prank(address(0xBEEF));
        quote6.approve(address(matchingEngine), realDeposit);
        vm.prank(address(0xBEEF));
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base18),
                quote: address(quote6),
                price: PRICE,
                amount: realDeposit,
                isMaker: true,
                n: 5,
                recipient: address(0xBEEF)
            })
        );

        // A taker with a budget of exactly 3 matches -- enough for the real order if
        // the dust were free to skip, and not enough if it is not.
        uint256 sell = 1e18;
        base18.mint(attacker, sell);
        vm.prank(attacker);
        base18.approve(address(matchingEngine), sell);

        uint256 quoteBefore = quote6.balanceOf(attacker);
        vm.prank(attacker);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(base18),
                quote: address(quote6),
                price: PRICE,
                amount: sell,
                isMaker: true,
                n: 3,
                recipient: attacker
            })
        );
        uint256 received = quote6.balanceOf(attacker) - quoteBefore;

        console.log("taker budget (n):                3");
        console.log("dust orders ahead of the real one: 3");
        console.log("quote received by the taker:      ", received);

        // Benign under SizePriority even before the fix: _insertId keeps the level
        // sorted by deposit descending, so dust sorts behind every fillable order.
        assertEq(received, realDeposit, "SizePriority: dust sits behind real orders, taker fills");
        // And evictions no longer come out of `n`, so the sweep clears all three
        // rather than stopping at the budget.
        assertEq(_resting(), 0, "evictions are bounded separately, so the level is cleaned");
    }

    /** Same book, same taker, one more unit of budget: the real order fills. */
    function testOneMoreMatchIsEnoughOnceTheDustIsCleared() public {
        super.setUp();
        _setUpPair(ExchangeOrderbook.MatchingMode.PriceTimePriority);

        _leaveDustOrder(trader1, trader2);
        _leaveDustOrder(address(0xD1), trader2);
        _leaveDustOrder(address(0xD2), trader2);

        uint256 realDeposit = 3_000_000;
        quote6.mint(address(0xBEEF), realDeposit);
        vm.prank(address(0xBEEF));
        quote6.approve(address(matchingEngine), realDeposit);
        vm.prank(address(0xBEEF));
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base18),
                quote: address(quote6),
                price: PRICE,
                amount: realDeposit,
                isMaker: true,
                n: 5,
                recipient: address(0xBEEF)
            })
        );

        uint256 sell = 1e18;
        base18.mint(attacker, sell);
        vm.prank(attacker);
        base18.approve(address(matchingEngine), sell);

        uint256 quoteBefore = quote6.balanceOf(attacker);
        vm.prank(attacker);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(base18),
                quote: address(quote6),
                price: PRICE,
                amount: sell,
                isMaker: true,
                n: 4,
                recipient: attacker
            })
        );
        uint256 received = quote6.balanceOf(attacker) - quoteBefore;

        console.log("taker budget (n):                4");
        console.log("quote received by the taker:      ", received);

        assertGt(received, 0, "with budget for the dust plus one, the real order fills");
    }

    /**
     * The mode where it used to bite. `PriceTimePriority` is FIFO, so a partially
     * filled order stays at the head of its level and its unfillable remainder sits
     * in front of everything behind it. Each one used to cost the next taker a match
     * from a budget capped at `maxMatches` -- with a budget of 1 they received
     * nothing and paid gas for it. This asserts the fix: the eviction is free, and
     * the order behind it fills.
     */
    function testUnderFifoAnEvictionNoLongerSpendsTheTakersBudget() public {
        super.setUp();
        _setUpPair(ExchangeOrderbook.MatchingMode.PriceTimePriority);

        // One leftover, created first so FIFO keeps it at the head.
        _leaveDustOrder(trader1, trader2);
        assertEq(_resting(), 1, "one dust order resting");

        // A real, fillable order queued behind it.
        uint256 realDeposit = 3_000_000;
        quote6.mint(address(0xBEEF), realDeposit);
        vm.prank(address(0xBEEF));
        quote6.approve(address(matchingEngine), realDeposit);
        vm.prank(address(0xBEEF));
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(base18),
                quote: address(quote6),
                price: PRICE,
                amount: realDeposit,
                isMaker: true,
                n: 5,
                recipient: address(0xBEEF)
            })
        );

        uint256 sell = 1e18;
        base18.mint(attacker, sell);
        vm.prank(attacker);
        base18.approve(address(matchingEngine), sell);

        // Budget of exactly 1: enough for the real order, if the dust were free.
        uint256 quoteBefore = quote6.balanceOf(attacker);
        vm.prank(attacker);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(base18),
                quote: address(quote6),
                price: PRICE,
                amount: sell,
                isMaker: true,
                n: 1,
                recipient: attacker
            })
        );
        uint256 received = quote6.balanceOf(attacker) - quoteBefore;

        console.log("FIFO - taker budget:          1");
        console.log("FIFO - quote received:       ", received);

        assertEq(
            received, realDeposit,
            "FIFO: the eviction is free, so the single match reaches the real order"
        );
    }
}

