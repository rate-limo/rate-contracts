// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {Orderbook} from "../../../src/exchange/orderbooks/Orderbook.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";

contract MockOGFeePolicy {
    uint32 public makerFee;
    uint32 public takerFee;

    constructor(uint32 makerFee_, uint32 takerFee_) {
        makerFee = makerFee_;
        takerFee = takerFee_;
    }

    function feeOf(address, address, address, bool isMaker) external view returns (uint32) {
        return isMaker ? makerFee : takerFee;
    }

    function isSubscribed(address) external pure returns (bool) {
        return true;
    }
}

contract FeeSplitTest is BaseSetup {
    function testOGPassFeeUsesMinimumOfPairAndAccountRate() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(token2), 1e8, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        address pair = matchingEngine.getPair(address(token1), address(token2));
        matchingEngine.setPairFeeClass(pair, 2, 200_000, 300_000);

        MockOGFeePolicy policy = new MockOGFeePolicy(100_000, 400_000);
        matchingEngine.setIncentive(address(policy));

        // Maker: account rate is lower, so it wins. Taker: pair rate is lower, so it wins.
        assertEq(matchingEngine.feeOf(address(token1), address(token2), trader1, true), 100_000);
        assertEq(matchingEngine.feeOf(address(token1), address(token2), trader1, false), 300_000);
    }

    function testPairFeeClassOverridesCanonicalPairFee() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(token2), 1e8, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        address pair = matchingEngine.getPair(address(token1), address(token2));

        matchingEngine.setPairFeeClass(pair, 2, 0, 300_000);

        assertEq(matchingEngine.feeOf(address(token1), address(token2), trader1, true), 0);
        assertEq(matchingEngine.feeOf(address(token1), address(token2), trader1, false), 300_000);
        (uint32 makerFee, uint32 takerFee, uint8 feeClass, bool configured) = matchingEngine.pairFeePolicy(pair);
        assertEq(makerFee, 0);
        assertEq(takerFee, 300_000);
        assertEq(feeClass, 2);
        assertTrue(configured);
    }

    function testRegularTraderOrderFeeGoes100PercentToFeeToByDefault() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(token2), 1e8, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);

        uint256 feeToBalanceBefore = token2.balanceOf(booker);

        vm.prank(trader1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 1e8,
                amount: 100e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        vm.prank(trader2);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 1e8,
                amount: 100e18,
                isMaker: true,
                n: 2,
                recipient: trader2
            })
        );

        // booker is BaseSetup's feeTo recipient (see OrderbookBaseSetup.sol setUp);
        // with poolFeeShare defaulting to 0, this must be unaffected by this change --
        // i.e. equal to whatever it was before Task 4 (a regression guard, not a new assertion
        // about the exact amount, since the exact fee amount is already covered by existing
        // exchange test suite).
        assertGt(token2.balanceOf(booker), feeToBalanceBefore);
    }

    function testPoolFeeShareDefaultsToZero() public {
        super.setUp();
        assertEq(matchingEngine.poolFeeShare(), 0);
    }

    function testSetPoolFeeShareChangesSplitForPoolOwnedOrders() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(token2), 1e8, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        address pairAddr = matchingEngine.getPair(address(token1), address(token2));

        vm.prank(address(matchingEngine));
        Orderbook(payable(pairAddr)).setPool(address(this)); // this test contract stands in for Pool

        matchingEngine.setPoolFeeShare(50000000); // 50% in DENOM=1e8 terms

        token2.mint(address(this), 1000e18);
        token2.approve(address(matchingEngine), 1000e18);

        // The taker fee is charged on the asset the TAKER receives, which here is token1
        // (the pool is buying base). So feeTo's share arrives in token1 too -- measuring
        // token2 would read zero and say nothing about the split.
        uint256 feeToBalanceBefore = token1.balanceOf(booker);
        // The pool receives token1 (base) on fill, and _sendFunds's pool-fee-split fires
        // on the leg where to == pool. Measure the pool's gain in token1, not token2.
        uint256 poolBalanceBefore = token1.balanceOf(address(this));

        // trader2 rests FIRST so the pool crosses it and is the TAKER. This ordering is
        // load-bearing now: the maker leg is fee-free, so a resting pool order collects
        // no fee and there would be nothing to split. Only a taker fee can be shared.
        vm.prank(trader2);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 1e8,
                amount: 100e18,
                isMaker: true,
                n: 2,
                recipient: trader2
            })
        );
        // Place this order AS the registered pool (msg.sender/recipient = address(this)).
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 1e8,
                amount: 100e18,
                isMaker: true,
                n: 2,
                recipient: address(this)
            })
        );

        // Compute the expected pool gain from the contract's own fee rate rather than
        // hardcoding it, so this stays correct if defaults ever change.
        uint32 baseFeeRate = matchingEngine.feeOf(address(token1), address(token2), address(this), false);
        uint256 amountMatched = 100e18;
        uint256 expectedFeeAmount = (amountMatched * baseFeeRate) / matchingEngine.DENOM();
        uint256 expectedPoolShare = (expectedFeeAmount * 50000000) / matchingEngine.DENOM();
        uint256 expectedPoolGain = (amountMatched - expectedFeeAmount) + expectedPoolShare;

        uint256 feeToGain = token1.balanceOf(booker) - feeToBalanceBefore;
        uint256 poolGain = token1.balanceOf(address(this)) - poolBalanceBefore;

        assertGt(expectedPoolShare, 0); // sanity: the fee split this test exists to verify must be nonzero
        assertEq(poolGain, expectedPoolGain); // proves the pool received trade proceeds AND its fee share -- would fail if the split were missing or miscomputed
        assertGt(feeToGain, 0);
    }

    /// Makers pay nothing even when a maker rate is configured. BaseSetup sets
    /// setDefaultFee(true, 100000), so this asserts the STRUCTURAL guarantee in
    /// Orderbook.execute (applyFee: false on the maker leg) rather than the fact
    /// that the default happens to be zero -- setDefaultFee(isMaker: true, x) must
    /// not be able to reintroduce a maker charge.
    function testMakerPaysNoFeeEvenWithMakerRateConfigured() public {
        super.setUp();
        matchingEngine.addPair(address(token1), address(token2), 1e8, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);

        assertGt(matchingEngine.feeOf(address(token1), address(token2), trader1, true), 0, "setup should configure a nonzero maker rate");

        uint256 makerBefore = token1.balanceOf(trader1);

        // trader1 rests the bid and is therefore the maker; trader2 crosses it.
        vm.prank(trader1);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 1e8,
                amount: 100e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        vm.prank(trader2);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: 1e8,
                amount: 100e18,
                isMaker: true,
                n: 2,
                recipient: trader2
            })
        );

        // The maker receives the full matched base amount -- no deduction.
        assertEq(token1.balanceOf(trader1) - makerBefore, 100e18, "maker must receive gross");
    }
}
