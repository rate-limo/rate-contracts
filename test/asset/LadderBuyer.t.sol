// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AssetLaunchLib} from "../../src/asset/libraries/AssetLaunchLib.sol";
import {LadderBuyer} from "../../src/asset/LadderBuyer.sol";
import {WrappedNative} from "../../src/mock/WrappedNative.sol";
import {IMatchingEngine} from "../../src/exchange/interfaces/IMatchingEngine.sol";
import {IOrderbook} from "../../src/exchange/interfaces/IOrderbook.sol";
import {DevBuyLaunchTest} from "./DevBuyLaunch.t.sol";

/// One Buy that walks a launch ladder, on the real engine. Steps rest at
/// 500 / 748 / 1119 / 1672 / 2500 and cost 800 / 1,196.8 / 1,790.4 / 2,675.2 / 4,000 USDC.
contract LadderBuyerTest is DevBuyLaunchTest {
    LadderBuyer internal buyer;
    WrappedNative internal wnative;
    address internal alice = address(0xA11CE);
    uint256 internal constant LADDER_COST = 10_462.4e6;

    function setUp() public virtual override {
        super.setUp();
        wnative = new WrappedNative("Wrapped Ether", "wETH");
        buyer = new LadderBuyer(address(matchingEngine), address(wnative));
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(buyer), type(uint256).max);
    }

    function _buy(address coin, uint256 quoteIn, uint256 maxPrice, uint256 minOut)
        internal
        returns (uint256 out, uint256 refunded)
    {
        vm.prank(alice);
        return buyer.buy(coin, address(usdc), quoteIn, maxPrice, minOut, alice, block.timestamp);
    }

    function _assertNothingLeft(address coin) internal view {
        assertEq(usdc.balanceOf(address(buyer)), 0, "no quote dust in LadderBuyer");
        assertEq(IERC20(coin).balanceOf(address(buyer)), 0, "no base dust in LadderBuyer");
        assertEq(IERC20(coin).allowance(address(buyer), address(matchingEngine)), 0, "base approval reset");
        assertEq(usdc.allowance(address(buyer), address(matchingEngine)), 0, "quote approval reset");
    }

    function _bidHead(address coin) internal view returns (uint256) {
        return IOrderbook(matchingEngine.getPair(coin, address(usdc))).bidHead();
    }

    function test_oneBuy_walksAllFiveSteps_atEachStepsPrice() public {
        address coin = _launch(address(usdc), MIN6);
        _fund(alice, 11_000e6);
        (uint256 out, uint256 refunded) = _buy(coin, 11_000e6, 2500, 0);

        assertEq(out, STEP * 5 * 99 / 100, "all five steps, net of the 1% taker fee");
        assertApproxEqAbs(11_000e6 - refunded, LADDER_COST, 5, "paid each step's own price");
        assertEq(IERC20(coin).balanceOf(alice), out);
        // Each level costs one unit more than its rounded price; that unit is refunded by
        // the engine to the recipient (alice), not through `refunded`.
        assertApproxEqAbs(usdc.balanceOf(alice), refunded, 5, "refund + per-level dust");
        AssetLaunchLib.Ladder memory l = gen.ladderOf(coin);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(IOrderbook(l.pair).getOrder(false, l.askIds[i]).depositAmount, 0, "ask consumed");
        }
        assertEq(_bidHead(coin), 0, "nothing rests on the book");
        _assertNothingLeft(coin);
        gen.graduate(coin); // reads as filled: arms
    }

    function test_partialBuy_whenQuoteRunsOut() public {
        address coin = _launch(address(usdc), MIN6);
        _fund(alice, 1_500e6);
        (uint256 out, uint256 refunded) = _buy(coin, 1_500e6, 2500, 0);

        // 800 buys all of step 0; the other 700 buys 700/1196.8 of step 1.
        uint256 step1 = STEP * 700e6 / 1196.8e6;
        assertApproxEqRel(out, (STEP + step1) * 99 / 100, 1e12, "step 0 + part of step 1");
        assertLe(refunded, 1e6, "at most dust returned");
        AssetLaunchLib.Ladder memory l = gen.ladderOf(coin);
        assertGt(IOrderbook(l.pair).getOrder(false, l.askIds[1]).depositAmount, 0, "step 1 still partly for sale");
        assertEq(_bidHead(coin), 0, "nothing rests on the book");
        _assertNothingLeft(coin);
    }

    function test_maxPrice_stopsAtThatStep_andRefundsTheRest() public {
        address coin = _launch(address(usdc), MIN6);
        _fund(alice, 11_000e6);
        (uint256 out, uint256 refunded) = _buy(coin, 11_000e6, 1119, 0);

        assertEq(out, STEP * 3 * 99 / 100, "steps 0-2 only");
        assertApproxEqAbs(11_000e6 - refunded, 800e6 + 1196.8e6 + 1790.4e6, 5, "nothing above 1119");
        AssetLaunchLib.Ladder memory l = gen.ladderOf(coin);
        assertEq(IOrderbook(l.pair).getOrder(false, l.askIds[3]).depositAmount, STEP, "step 3 untouched");
        assertEq(_bidHead(coin), 0, "nothing rests on the book");
        _assertNothingLeft(coin);
    }

    function test_minBaseOut_reverts_andLeavesNothingBehind() public {
        address coin = _launch(address(usdc), MIN6);
        _fund(alice, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LadderBuyer.InsufficientOutput.selector, STEP * 99 / 100, STEP));
        buyer.buy(coin, address(usdc), 800e6, 500, STEP, alice, block.timestamp);
        assertEq(usdc.balanceOf(alice), 1_000e6, "reverted: quote untouched");
    }

    function test_expiredDeadline_reverts() public {
        address coin = _launch(address(usdc), MIN6);
        _fund(alice, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LadderBuyer.DeadlinePassed.selector, block.timestamp - 1, block.timestamp));
        buyer.buy(coin, address(usdc), 800e6, 2500, 0, alice, block.timestamp - 1);
    }

    function test_sell_returnsQuote_andNeverRests() public {
        address coin = _launch(address(usdc), MIN6);
        _fund(alice, 11_000e6);
        _buy(coin, 1_500e6, 2500, 0);
        uint256 coins = IERC20(coin).balanceOf(alice);

        // A resting bid for the seller to hit, from someone else.
        usdc.mint(trader1, 100e6);
        vm.startPrank(trader1);
        usdc.approve(address(matchingEngine), type(uint256).max);
        uint256 lmp = IOrderbook(matchingEngine.getPair(coin, address(usdc))).lmp();
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: coin, quote: address(usdc), price: lmp * 99 / 100, amount: 100e6, isMaker: true, n: 1,
                recipient: trader1
            })
        );
        vm.stopPrank();

        vm.startPrank(alice);
        IERC20(coin).approve(address(buyer), type(uint256).max);
        (uint256 quoteOut, uint256 refunded) =
            buyer.sell(coin, address(usdc), coins, lmp * 99 / 100, 1, alice, block.timestamp);
        vm.stopPrank();

        assertGt(quoteOut, 0, "sold into the bid");
        assertGt(refunded, 0, "the part the bid could not take came back");
        assertApproxEqAbs(IERC20(coin).balanceOf(alice), refunded, 5, "refund + per-level dust");
        (, uint256 askHead) = IOrderbook(matchingEngine.getPair(coin, address(usdc))).heads();
        AssetLaunchLib.Ladder memory l = gen.ladderOf(coin);
        // A leftover sell would rest at the seller's floor, below step 1. The best ask is
        // still the ladder's own step 1, so the seller left nothing on the book.
        assertEq(askHead, IOrderbook(l.pair).getOrder(false, l.askIds[1]).price, "best ask is still the ladder's");
        _assertNothingLeft(coin);
    }

    function test_aRegularMarket_works() public {
        // token1/token2 from the band fixture: no launch, engine-default fees.
        vm.startPrank(trader1);
        token1.approve(address(matchingEngine), type(uint256).max);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1), quote: address(token2), price: LISTING, amount: 10e18, isMaker: true, n: 1,
                recipient: trader1
            })
        );
        vm.stopPrank();

        token2.mint(alice, 2_000e18);
        vm.startPrank(alice);
        token2.approve(address(buyer), type(uint256).max);
        (uint256 out, uint256 refunded) =
            buyer.buy(address(token1), address(token2), 2_000e18, LISTING, 0, alice, block.timestamp);
        vm.stopPrank();

        assertEq(out, 10e18 * 999 / 1000, "the whole ask, net of 0.1%");
        assertApproxEqAbs(refunded, 1_000e18, 1, "the 1,000 the ask could not absorb (1 unit of dust to the recipient)");
        assertEq(book.bidHead(), 0, "nothing rests on the book");
        assertEq(token1.balanceOf(address(buyer)) + token2.balanceOf(address(buyer)), 0);
    }
}
