// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {LadderBuyer} from "../../src/asset/LadderBuyer.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {IMatchingEngine} from "../../src/exchange/interfaces/IMatchingEngine.sol";
import {IOrderbook} from "../../src/exchange/interfaces/IOrderbook.sol";
import {LadderBuyerQuotesTest} from "./LadderBuyerQuotes.t.sol";

contract FoT is ERC20 {
    constructor() ERC20("Fee", "FOT") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function _update(address from, address to, uint256 v) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = v / 100;
            super._update(from, address(0xdead), fee);
            v -= fee;
        }
        super._update(from, to, v);
    }
}

/// Regressions for the LadderBuyer security review (scratchpad/c4 PoC_LadderEvict,
/// PoC_LadderMisc). Each was a working grief or leak before the fix.
contract LadderBuyerRegressionsTest is LadderBuyerQuotesTest {
    address internal eve = address(0xE7E);
    uint256[4] internal planted = [uint256(600), 900, 1300, 2000];

    /// Anyone holding one coin rests an ask that expires immediately.
    function _plantExpiredAsk(address coin, address quote, uint256 price) internal returns (uint32 id) {
        vm.startPrank(eve);
        IERC20(coin).approve(address(matchingEngine), type(uint256).max);
        id = matchingEngine.createOrder(
            IMatchingEngine.CreateOrderInput({
                base: coin, quote: quote, isBid: false, isLimit: true, orderId: 0, price: price, amount: 1e18, n: 1,
                recipient: eve, isMaker: true, slippageLimit: 0, deadline: uint64(block.timestamp)
            })
        ).id;
        vm.stopPrank();
        assertGt(id, 0, "planted ask rests");
    }

    /// Expired asks between every pair of ladder steps (the reviewer's book).
    function _plantedBook() internal returns (address coin, address pair) {
        coin = _launch(address(usdc), MIN6);
        pair = matchingEngine.getPair(coin, address(usdc));
        _fund(eve, 10e6);
        vm.prank(eve);
        buyer.buy(coin, address(usdc), 10e6, 500, 0, eve, block.timestamp);
        for (uint256 i; i < 4; ++i) _plantExpiredAsk(coin, address(usdc), planted[i]);
        vm.warp(block.timestamp + 2);
    }

    /* ------------------------------- M-1: expired ------------------------------ */

    function test_m1_expiredAsks_protectedBuy_fillsTheWholeLadder() public {
        (address coin, address pair) = _plantedBook();
        _fund(alice, 11_000e6);
        uint256 minOut = STEP * 4 * 99 / 100;
        vm.prank(alice);
        (uint256 out,) = buyer.buy(coin, address(usdc), 11_000e6, 2500, minOut, alice, block.timestamp);
        assertGe(out, minOut, "planted expired asks no longer stall the walk");
        for (uint256 i; i < 4; ++i) assertEq(IOrderbook(pair).orderHead(false, planted[i]), 0, "expired ask cleared");
        _assertBuyerEmpty(coin, address(usdc));
    }

    function test_m1_expiredAsks_unprotectedBuy_noBudgetLeaksToTheRecipient() public {
        (address coin,) = _plantedBook();
        _fund(alice, 11_000e6);
        uint256 q0 = usdc.balanceOf(alice);
        vm.prank(alice);
        (uint256 out, uint256 refunded) = buyer.buy(coin, address(usdc), 11_000e6, 2500, 0, alice, block.timestamp);
        assertGt(out, STEP * 4 * 99 / 100, "most of the ladder, not one step");
        // Spent from alice's wallet net of everything returned to her, by any route,
        // equals what the engine kept: no budget detoured around `refunded`.
        uint256 netSpent = q0 - usdc.balanceOf(alice);
        assertApproxEqAbs(11_000e6 - refunded, netSpent, 10, "returned only via refunded, plus per-level dust");
    }

    function test_m1_buyWithNative_expiredAsk_noWrapperPayout() public {
        address coin = _launchIn(address(wnative), MIN_ETH);
        address pair = matchingEngine.getPair(coin, address(wnative));
        vm.deal(eve, 1 ether);
        vm.prank(eve);
        buyer.buyWithNative{value: 0.01 ether}(coin, address(wnative), ANY_PRICE, 0, eve, block.timestamp);
        uint256 next = IOrderbook(pair).askHead();
        _plantExpiredAsk(coin, address(wnative), next * 6 / 5);
        vm.warp(block.timestamp + 2);

        vm.prank(alice);
        (uint256 out,) = buyer.buyWithNative{value: 20 ether}(coin, address(wnative), ANY_PRICE, 0, alice, block.timestamp);
        assertGt(out, STEP_N * 4 * 99 / 100, "walk not stalled");
        assertLe(wnative.balanceOf(alice), 10, "no budget paid out as wrapper, only per-level dust");
        _assertBuyerEmpty(coin, address(wnative));
    }

    /* --------------------------------- M-1: dust ------------------------------- */

    /// Rewrites one resting order's deposit in place. Normal flow cannot leave an ask whose
    /// remainder converts to zero here (the fill rounding is exact), so the dust order the
    /// engine guards against is made directly: find the slot `getOrder` reads that holds
    /// the deposit, and overwrite it.
    function _setDeposit(address pair, bool isBid, uint32 id, uint256 amount) internal {
        uint256 current = IOrderbook(pair).getOrder(isBid, id).depositAmount;
        vm.record();
        IOrderbook(pair).getOrder(isBid, id);
        (bytes32[] memory reads,) = vm.accesses(pair);
        for (uint256 i; i < reads.length; ++i) {
            if (uint256(vm.load(pair, reads[i])) != current) continue;
            vm.store(pair, reads[i], bytes32(amount));
            if (IOrderbook(pair).getOrder(isBid, id).depositAmount == amount) return;
            vm.store(pair, reads[i], bytes32(current));
        }
        revert("deposit slot not found");
    }

    /// A dust-only level between steps: its only ask converts to zero quote.
    function test_m1_dustOnlyLevel_isEvicted_andTheWalkContinues() public {
        address coin = _launch(address(usdc), MIN6);
        address pair = matchingEngine.getPair(coin, address(usdc));
        // Clear step 0 so a level at 600 is the next thing in the way.
        _fund(alice, 20_000e6);
        vm.prank(alice);
        buyer.buy(coin, address(usdc), 800e6 + 10, 500, 0, alice, block.timestamp);
        vm.prank(alice);
        IERC20(coin).transfer(eve, 1e18);
        vm.startPrank(eve);
        IERC20(coin).approve(address(matchingEngine), type(uint256).max);
        matchingEngine.limitSell(IMatchingEngine.LimitOrderInput({
            base: coin, quote: address(usdc), price: 600, amount: 1e18, isMaker: true, n: 1, recipient: eve
        }));
        vm.stopPrank();
        uint32 id = IOrderbook(pair).orderHead(false, 600);
        // 0.01 coin at 600 is 0.06 of a quote unit: dust. (The pair still holds the coins.)
        _setDeposit(pair, false, id, 1e16);
        assertEq(IOrderbook(pair).convert(600, 1e16, true), 0, "it is dust");

        uint256 q0 = usdc.balanceOf(alice);
        uint256 c0 = IERC20(coin).balanceOf(alice);
        vm.prank(alice);
        (, uint256 refunded) = buyer.buy(coin, address(usdc), 10_000e6, 2500, 0, alice, block.timestamp);
        assertEq(IOrderbook(pair).orderHead(false, 600), 0, "dust evicted");
        assertEq(IERC20(coin).balanceOf(alice) - c0, STEP * 4 * 99 / 100, "steps 1-4 all filled past the dust");
        assertApproxEqAbs(10_000e6 - refunded, q0 - usdc.balanceOf(alice), 20, "only a few units outside refunded");
        _assertBuyerEmpty(coin, address(usdc));
    }

    /* --------------------------------- L-1 / L-2 -------------------------------- */

    function test_l1_loweredMaxMatches_stillTrades() public {
        address coin = _launch(address(usdc), MIN6);
        matchingEngine.setMaxMatches(10);
        _fund(alice, 1_000e6);
        vm.prank(alice);
        (uint256 out,) = buyer.buy(coin, address(usdc), 1_000e6, 2500, 0, alice, block.timestamp);
        assertGt(out, 0, "orders use n = maxMatches, not a hard-coded 20");
    }

    function test_l2_feeOnTransfer_refundIsWhatArrived_strayBalanceUntouched() public {
        FoT fot = new FoT();
        matchingEngine.addPair(
            address(fot), address(usdc), 1e8, block.timestamp, address(usdc), ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        fot.mint(eve, 1_000e18);
        fot.mint(address(buyer), 50e18); // stray / donated balance
        vm.startPrank(eve);
        fot.approve(address(buyer), type(uint256).max);
        // minPrice unreachable: no order is sent, everything is unspent.
        (, uint256 refunded) =
            buyer.sell(address(fot), address(usdc), 1_000e18, type(uint128).max, 0, eve, block.timestamp);
        vm.stopPrank();
        assertEq(refunded, 990e18, "refund = the 990 that arrived, not the nominal 1,000");
        assertEq(fot.balanceOf(address(buyer)), 50e18, "the stray balance is not paid out");
    }

    /* ----------------------------------- I-1 ----------------------------------- */

    function test_i1_engineWethOnAnUnwrappingChain_isRefusedAsTheWrapper() public {
        vm.expectRevert(abi.encodeWithSelector(LadderBuyer.NotCanonicalWrapper.selector, address(weth)));
        new LadderBuyer(address(matchingEngine), address(weth));
    }

    function test_i2_zeroDeadline_reverts() public {
        address coin = _launch(address(usdc), MIN6);
        _fund(alice, 100e6);
        vm.prank(alice);
        vm.expectPartialRevert(LadderBuyer.DeadlinePassed.selector);
        buyer.buy(coin, address(usdc), 100e6, 2500, 0, alice, 0);
    }
}
