// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {AssetGenerator} from "../../src/asset/AssetGenerator.sol";
import {AssetLaunchLib} from "../../src/asset/libraries/AssetLaunchLib.sol";
import {LadderBuyer} from "../../src/asset/LadderBuyer.sol";
import {IMatchingEngine} from "../../src/exchange/interfaces/IMatchingEngine.sol";
import {IOrderbook} from "../../src/exchange/interfaces/IOrderbook.sol";
import {MockBase} from "../../src/mock/MockBase.sol";
import {LadderBuyerTest} from "./LadderBuyer.t.sol";

/// A coin's quote is whatever its creator picked from the enabled options: USDC, a
/// tokenized stock, or the chain's gas coin (as WrappedNative). Buyers pay in it directly,
/// nothing is converted, and every fill is credited to the trader.
///
/// The fixture's engine is RISE-shaped: its WETH is a real wrapper and `nativeScale() == 0`.
contract LadderBuyerQuotesTest is LadderBuyerTest {
    bytes32 internal constant ORDER_MATCHED = keccak256(
        "OrderMatched(address,uint16,uint256,bool,uint256,uint256,bool,(address,address,uint256,uint256,uint256,uint256,uint64))"
    );

    // A gas-coin quote at ETH ~ $2,000: $5,000 -> $25,000 is 2.5 -> 12.5 ETH. The engine's
    // 1e8 price floor (100 units) caps supply near 2.5M at this start, so 1M here.
    uint256 internal constant SUPPLY_N = 1_000_000e18;
    uint256 internal constant STEP_N = 160_000e18;
    uint256 internal constant MCAP_ETH = 2.5e18;
    uint256 internal constant MIN_ETH = 0.0025e18;
    uint256 internal constant GRAD_ETH = 12.5e18;

    // An 18-decimal stock-like quote at ~$185: $5,000 is ~27 shares.
    MockBase internal nvda;
    uint256 internal constant MCAP_NVDA = 27e18;
    uint256 internal constant GRAD_NVDA = 135e18;

    uint256 internal constant ANY_PRICE = 1e30;

    function setUp() public override {
        super.setUp();
        assertEq(matchingEngine.nativeScale(), 0, "RISE shape: the engine's WETH unwraps");
        gen.setQuoteOption(
            address(wnative), true, MCAP_ETH, MIN_ETH, GRAD_ETH, ExchangeOrderbook.MatchingMode.PriceTimePriority, COIN_FEE
        );
        nvda = new MockBase("Tokenized NVDA", "NVDA");
        gen.setQuoteOption(
            address(nvda), true, MCAP_NVDA, 0.027e18, GRAD_NVDA, ExchangeOrderbook.MatchingMode.PriceTimePriority, COIN_FEE
        );
        vm.deal(alice, 100 ether);
        vm.deal(launcher, 100 ether);
        nvda.mint(launcher, 100e18);
        vm.startPrank(launcher);
        wnative.deposit{value: 1 ether}();
        wnative.approve(address(gen), type(uint256).max);
        nvda.approve(address(gen), type(uint256).max);
        vm.stopPrank();
    }

    function _launchIn(address quote, uint256 devBuy) internal returns (address coin) {
        vm.prank(launcher);
        coin = gen.launch{value: FEE}("Quoted Coin", "QTD", SUPPLY_N, quote, devBuy, FEES_ONLY);
    }

    function _poolOf(address coin, address quote) internal view returns (address p) {
        p = poolFactory.getPool(coin, quote);
        if (p == address(0)) p = poolFactory.getPool(quote, coin);
    }

    /// Every OrderMatched on `pair` names `who` as the taker the broker credits.
    function _assertSenders(Vm.Log[] memory logs, address pair, address who) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != ORDER_MATCHED) continue;
            (address p,,,,,,, IMatchingEngine.OrderMatch memory m) = abi.decode(
                logs[i].data, (address, uint16, uint256, bool, uint256, uint256, bool, IMatchingEngine.OrderMatch)
            );
            if (p != pair) continue;
            assertEq(m.sender, who, "OrderMatched.sender is the trader, never LadderBuyer");
            ++n;
        }
    }

    function _assertBuyerEmpty(address coin, address quote) internal view {
        assertEq(IERC20(coin).balanceOf(address(buyer)), 0, "no coin left in LadderBuyer");
        assertEq(IERC20(quote).balanceOf(address(buyer)), 0, "no quote left in LadderBuyer");
        assertEq(address(buyer).balance, 0, "no native coin left in LadderBuyer");
        assertEq(IERC20(quote).allowance(address(buyer), address(matchingEngine)), 0, "approval reset");
    }

    /* ------------------------------ the gas coin ------------------------------ */

    function test_nativeQuote_launch_buy_graduate_sell_endToEnd() public {
        address coin = _launchIn(address(wnative), MIN_ETH);
        AssetLaunchLib.Ladder memory l = gen.ladderOf(coin);
        assertTrue(_poolOf(coin, address(wnative)) != address(0), "a wrapper-quoted pair gets a band pool");

        // Buy the whole ladder with ETH, one call.
        uint256 ethBefore = alice.balance;
        vm.recordLogs();
        vm.prank(alice);
        (uint256 out, uint256 ethBack) =
            buyer.buyWithNative{value: 6 ether}(coin, address(wnative), ANY_PRICE, 0, alice, block.timestamp);
        assertGe(_assertSenders(vm.getRecordedLogs(), l.pair, alice), 5, "each step credited to alice");
        assertEq(out, STEP_N * 5 * 99 / 100, "all five steps, net of the 1% fee");
        assertGt(ethBack, 0, "the ladder costs less than 6 ETH");
        assertEq(alice.balance, ethBefore - 6 ether + ethBack, "unspent ETH came back as ETH");
        assertEq(IERC20(coin).balanceOf(alice), out);
        _assertBuyerEmpty(coin, address(wnative));
        console.log("ETH spent on the whole ladder (wei)", 6 ether - ethBack);

        // Graduation seeds a real pool in coin/wrapper with what the ladder raised.
        uint256 raised = wnative.balanceOf(l.escrow);
        assertGt(raised, 5 ether, "the escrow holds the raise, as an ERC-20");
        _graduate(coin);
        address pool = _poolOf(coin, address(wnative));
        assertEq(wnative.balanceOf(l.escrow), 0, "escrow swept");
        assertGe(wnative.balanceOf(pool), raised, "the pool holds the raise");

        // Sell back for native coin, into someone's resting wrapper bid.
        address maker = address(0xB1D);
        vm.deal(maker, 3 ether);
        uint256 lmp = IOrderbook(l.pair).lmp();
        vm.startPrank(maker);
        wnative.deposit{value: 2 ether}();
        wnative.approve(address(matchingEngine), type(uint256).max);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: coin, quote: address(wnative), price: lmp * 99 / 100, amount: 1 ether, isMaker: true, n: 1,
                recipient: maker
            })
        );
        vm.stopPrank();

        uint256 ethBeforeSell = alice.balance;
        // The buy's per-level rounding unit (1 wei of wrapper per level) was refunded by the
        // engine to alice as the order recipient; the sell must leave it exactly where it is.
        uint256 wrapperDust = wnative.balanceOf(alice);
        assertLe(wrapperDust, 5, "at most one wei per ladder level");
        vm.startPrank(alice);
        IERC20(coin).approve(address(buyer), type(uint256).max);
        wnative.approve(address(buyer), type(uint256).max);
        vm.recordLogs();
        (uint256 ethOut,) =
            buyer.sellForNative(coin, address(wnative), 50_000e18, lmp * 99 / 100, 1, alice, block.timestamp);
        vm.stopPrank();
        assertGe(_assertSenders(vm.getRecordedLogs(), l.pair, alice), 1, "the sell is credited to alice");
        assertGt(ethOut, 0);
        assertEq(alice.balance, ethBeforeSell + ethOut, "proceeds arrived as native coin");
        assertEq(wnative.balanceOf(alice), wrapperDust, "the sell's proceeds were all unwrapped");
        _assertBuyerEmpty(coin, address(wnative));
    }

    function test_nativeQuote_maxPrice_stopsAndRefundsEth() public {
        address coin = _launchIn(address(wnative), MIN_ETH);
        AssetLaunchLib.Ladder memory l = gen.ladderOf(coin);
        uint256 step1 = IOrderbook(l.pair).getOrder(false, l.askIds[1]).price;
        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        (uint256 out, uint256 ethBack) =
            buyer.buyWithNative{value: 6 ether}(coin, address(wnative), step1, 0, alice, block.timestamp);
        assertEq(out, STEP_N * 2 * 99 / 100, "steps 0 and 1 only");
        assertEq(alice.balance, ethBefore - 6 ether + ethBack);
        _assertBuyerEmpty(coin, address(wnative));
    }

    function test_nativeQuote_needsASupplyThePriceFloorCanExpress() public {
        // 1B coins at 2.5 ETH is 2.5e-9 ETH each: 0.25 of the engine's smallest price step.
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.ListingPriceTooLow.selector, 1));
        gen.launch{value: FEE}("Too Big", "BIG", SUPPLY, address(wnative), MIN_ETH, FEES_ONLY);
    }

    function test_buyWithNative_onlyTheCanonicalWrapper() public {
        address coin = _launch(address(usdc), MIN6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LadderBuyer.NotCanonicalWrapper.selector, address(usdc)));
        buyer.buyWithNative{value: 1 ether}(coin, address(usdc), ANY_PRICE, 0, alice, block.timestamp);
    }

    function test_noWrapperChain_nativePathsRevert() public {
        // Arc: the gas coin IS USDC, so no wrapper is deployed and buyers use `buy`.
        LadderBuyer arcStyle = new LadderBuyer(address(matchingEngine), address(0));
        vm.prank(alice);
        vm.expectRevert(LadderBuyer.NoWrappedNative.selector);
        arcStyle.buyWithNative{value: 1 ether}(address(1), address(0), ANY_PRICE, 0, alice, block.timestamp);
    }

    function test_strayNativeCoin_isRefused() public {
        vm.prank(alice);
        (bool ok,) = address(buyer).call{value: 1}("");
        assertFalse(ok, "only the wrapper may pay native coin in");
    }

    /* --------------------------- an 18-decimal stock -------------------------- */

    function test_stockQuote18Dec_walksTheLadder_creditedToTheBuyer() public {
        address coin = _launchIn(address(nvda), 0.027e18);
        AssetLaunchLib.Ladder memory l = gen.ladderOf(coin);
        nvda.mint(alice, 100e18);
        vm.prank(alice);
        nvda.approve(address(buyer), type(uint256).max);

        vm.recordLogs();
        vm.prank(alice);
        (uint256 out, uint256 back) = buyer.buy(coin, address(nvda), 100e18, ANY_PRICE, 0, alice, block.timestamp);
        assertGe(_assertSenders(vm.getRecordedLogs(), l.pair, alice), 5);
        assertEq(out, STEP_N * 5 * 99 / 100, "all five steps");
        assertGt(back, 0);
        console.log("NVDA spent on the whole ladder (wei)", 100e18 - back);
        _assertBuyerEmpty(coin, address(nvda));
    }

    /* ------------------------------- attribution ------------------------------ */

    function test_attribution_usdcBuy_isCreditedToTheBuyer() public {
        address coin = _launch(address(usdc), MIN6);
        AssetLaunchLib.Ladder memory l = gen.ladderOf(coin);
        _fund(alice, 11_000e6);
        vm.recordLogs();
        _buy(coin, 11_000e6, 2500, 0);
        assertGe(_assertSenders(vm.getRecordedLogs(), l.pair, alice), 5);
    }

    function test_gas_buyWithNative_wholeLadder() public {
        address coin = _launchIn(address(wnative), MIN_ETH);
        vm.prank(alice);
        buyer.buyWithNative{value: 6 ether}(coin, address(wnative), ANY_PRICE, 0, alice, block.timestamp);
        console.log("buyWithNative, 5 steps (gas)", vm.lastCallGas().gasTotalUsed);
    }
}
