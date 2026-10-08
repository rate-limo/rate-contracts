// SPDX-License-Identifier: MIT
pragma solidity >=0.8;

import {MockToken} from "../../../src/mock/MockToken.sol";
import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {IOrderbook} from "../../../src/exchange/interfaces/IOrderbook.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * A partial fill must not leave an unfillable remainder resting on the book.
 *
 * `convert` floors before it scales, so a remainder can convert to zero in the
 * taker's asset: on an 18/6-decimal pair at ~2000 (ETH/USDC), any bid remainder
 * under ~2000 raw USDC. `Orderbook.fpop` evicts such an order, but only when a
 * LATER taker reaches its price. Until then it rests, the UI reads it as ≈100%
 * filled, and only its owner cancelling clears it -- the "open order that never
 * disappears" report. `MatchingLib.matchAt` now evicts it in the match that
 * leaves it, with `OrderDusted`.
 *
 * Every test here fails against the contracts before that change.
 */
contract PartialFillNeverLeavesDustTest is BaseSetup {
    bytes32 constant ORDER_MATCHED_TOPIC = keccak256(
        "OrderMatched(address,uint16,uint256,bool,uint256,uint256,bool,(address,address,uint256,uint256,uint256,uint256,uint64))"
    );
    bytes32 constant ORDER_DUSTED_TOPIC = keccak256("OrderDusted(address,uint16,uint256,bool,uint256,address,uint256)");

    uint256 constant ETH_PRICE = 2000e8;

    MockToken base;
    MockToken quote;
    address pair;

    function _pair(uint8 bDec, uint8 qDec, uint256 price) internal {
        super.setUp();
        base = new MockToken("B", "B", bDec);
        quote = new MockToken("Q", "Q", qDec);
        matchingEngine.addPair(
            address(base), address(quote), price, 0, address(base), ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        pair = matchingEngine.getPair(address(base), address(quote));
    }

    function _limit(address who, bool isBid, uint256 price, uint256 amount, bool isMaker) internal returns (bool ok) {
        MockToken t = isBid ? quote : base;
        t.mint(who, amount);
        vm.prank(who);
        t.approve(address(matchingEngine), amount);
        IMatchingEngine.LimitOrderInput memory input = IMatchingEngine.LimitOrderInput({
            base: address(base), quote: address(quote), price: price, amount: amount, isMaker: isMaker, n: 5, recipient: who
        });
        vm.prank(who);
        try (isBid ? matchingEngine.limitBuy : matchingEngine.limitSell)(input) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    /// Rest a maker order, fill it partially, and require that whatever is left
    /// either can still fill or is gone.
    function _check(uint8 bDec, uint8 qDec, uint256 price, uint256 deposit, uint256 take, bool makerIsBid) internal {
        _pair(bDec, qDec, price);
        if (!_limit(trader1, makerIsBid, price, deposit, true)) return;
        uint32 id = IOrderbook(pair).getOrderIds(makerIsBid, price, 1)[0];
        uint256 required =
            IOrderbook(pair).convert(price, IOrderbook(pair).getOrder(makerIsBid, id).depositAmount, !makerIsBid);
        if (required < 2) return;
        take = bound(take, 1, required - 1);
        if (!_limit(attacker, !makerIsBid, price, take, false)) return;
        ExchangeOrderbook.Order memory left = IOrderbook(pair).getOrder(makerIsBid, id);
        if (left.owner == address(0)) return;
        assertGt(
            IOrderbook(pair).convert(price, left.depositAmount, !makerIsBid),
            0,
            "a partial fill left an unfillable remainder on the book"
        );
    }

    function testFuzz_partialFill_base18_quote6(uint256 p, uint256 d, uint256 t, bool bid) public {
        _check(18, 6, bound(p, 1, 1e14), bound(d, 1, 1e30), t, bid);
    }

    function testFuzz_partialFill_base0_quote6(uint256 p, uint256 d, uint256 t, bool bid) public {
        _check(0, 6, bound(p, 1, 1e14), bound(d, 1, 1e24), t, bid);
    }

    function testFuzz_partialFill_base6_quote18(uint256 p, uint256 d, uint256 t, bool bid) public {
        _check(6, 18, bound(p, 1, 1e14), bound(d, 1, 1e30), t, bid);
    }

    function testFuzz_partialFill_base8_quote6(uint256 p, uint256 d, uint256 t, bool bid) public {
        _check(8, 6, bound(p, 1, 1e14), bound(d, 1, 1e24), t, bid);
    }

    function testFuzz_partialFill_ethUsdcPrices(uint256 p, uint256 d, uint256 t, bool bid) public {
        _check(18, 6, bound(p, 1000e8, 5000e8), bound(d, 1e10, 1e22), t, bid);
    }

    /**
     * The concrete case: ETH/USDC at 2000, fees off so the arithmetic is visible.
     * A 10.0015 USDC bid needs exactly 0.005 ETH to clear (convert floors to whole
     * 2000-raw steps, then scales). A taker sells one wei less: that converts to
     * 9.999999 USDC, a partial fill, and the 1,501 raw USDC left converts to zero
     * ETH, so nobody can ever fill it.
     */
    function test_partialFill_ethUsdc_dustIsEvictedAndRefundedInTheSameMatch() public {
        _pair(18, 6, ETH_PRICE);
        matchingEngine.setDefaultFee(true, 0);
        matchingEngine.setDefaultFee(false, 0);
        uint256 deposit = 10_001_500; // 10.0015 USDC
        assertTrue(_limit(trader1, true, ETH_PRICE, deposit, true), "bid rests");
        uint32 id = IOrderbook(pair).getOrderIds(true, ETH_PRICE, 1)[0];
        uint256 resting = IOrderbook(pair).getOrder(true, id).depositAmount;

        uint256 makerQuoteBefore = quote.balanceOf(trader1);
        vm.recordLogs();
        assertEq(IOrderbook(pair).convert(ETH_PRICE, resting, false), 0.005 ether, "precondition: 0.005 ETH clears it");
        assertTrue(_limit(attacker, false, ETH_PRICE, 0.005 ether - 1, false), "taker sells 0.005 ETH less one wei");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // The match itself reported a partial fill...
        bool matched;
        bool dusted;
        uint256 refunded;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == ORDER_MATCHED_TOPIC) {
                (,, uint256 matchedId,,,, bool clear,) = abi.decode(
                    logs[i].data, (address, uint16, uint256, bool, uint256, uint256, bool, IMatchingEngine.OrderMatch)
                );
                assertEq(matchedId, id);
                assertFalse(clear, "the fill itself did not clear the order");
                matched = true;
            } else if (logs[i].topics[0] == ORDER_DUSTED_TOPIC) {
                assertTrue(matched, "OrderDusted follows the OrderMatched that left the dust");
                (,, uint256 dustedId, bool isBid,, address owner, uint256 r) =
                    abi.decode(logs[i].data, (address, uint16, uint256, bool, uint256, address, uint256));
                assertEq(dustedId, id);
                assertTrue(isBid);
                assertEq(owner, trader1);
                refunded = r;
                dusted = true;
            }
        }
        assertTrue(dusted, "the unfillable remainder is evicted in the same transaction");

        // ...and the book and the maker's balance agree with the event.
        assertEq(IOrderbook(pair).getOrder(true, id).owner, address(0), "order deleted");
        assertTrue(IOrderbook(pair).isEmpty(true, ETH_PRICE), "level emptied");
        assertGt(refunded, 0);
        assertEq(IOrderbook(pair).convert(ETH_PRICE, refunded, false), 0, "what was refunded really was dust");
        assertLt(refunded, resting);
        assertEq(quote.balanceOf(trader1) - makerQuoteBefore, refunded, "the maker got the remainder back");
    }

    /// A fillable remainder is left exactly where it was: the second `fpop` is a read.
    function test_partialFill_fillableRemainderStaysResting() public {
        _pair(18, 6, ETH_PRICE);
        assertTrue(_limit(trader1, true, ETH_PRICE, 20e6, true), "20 USDC bid rests");
        uint32 id = IOrderbook(pair).getOrderIds(true, ETH_PRICE, 1)[0];

        vm.recordLogs();
        assertTrue(_limit(attacker, false, ETH_PRICE, 0.005 ether, false), "taker sells 0.005 ETH");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != ORDER_DUSTED_TOPIC, "nothing evicted");
        }
        ExchangeOrderbook.Order memory left = IOrderbook(pair).getOrder(true, id);
        assertEq(left.owner, trader1, "still resting");
        assertGt(IOrderbook(pair).convert(ETH_PRICE, left.depositAmount, false), 0);
    }
}
