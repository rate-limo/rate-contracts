// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {AssetGenerator} from "../../src/asset/AssetGenerator.sol";
import {TempoAssetGenerator} from "../../src/tempo/TempoAssetGenerator.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {DevBuyLaunchTest} from "../asset/DevBuyLaunch.t.sol";
import {DeferredLadderTest} from "../asset/DeferredLadder.t.sol";

/**
 * Replays the launch suites against TempoAssetGenerator. It has AssetGenerator's ABI, so
 * the inherited tests drive it through the `gen` they already hold: every launch, ladder,
 * graduation and deferred-ladder test runs against the Tempo copy unchanged. Only the fee
 * differs -- taken in the quote token, because Tempo has no native coin -- and only the
 * fee test is overridden.
 */
abstract contract TempoGenerator is DevBuyLaunchTest {
    /// 1 USDC: the fee is in the quote token's units, not wei.
    uint256 internal constant QUOTE_FEE = 1e6;

    function setUp() public virtual override {
        super.setUp();
        TempoAssetGenerator tempo = new TempoAssetGenerator(address(this), address(matchingEngine));
        tempo.setFeeTo(feeTo);
        tempo.setLaunchFee(QUOTE_FEE);
        tempo.setQuoteOption(
            address(usdc), true, MCAP6, MIN6, GRAD6, ExchangeOrderbook.MatchingMode.PriceTimePriority, COIN_FEE
        );
        tempo.setQuoteOption(
            address(token2), true, 5_000e18, 5e18, 25_000e18, ExchangeOrderbook.MatchingMode.PriceTimePriority, COIN_FEE
        );
        // The same engine wiring the parent gave the native generator, moved to this one.
        matchingEngine.grantRole(keccak256("MARKET_MAKER_ROLE"), address(tempo));
        matchingEngine.setFeeManager(address(tempo));
        matchingEngine.setIncentive(address(tempo));
        vm.startPrank(launcher);
        usdc.approve(address(tempo), type(uint256).max);
        token2.approve(address(tempo), type(uint256).max);
        vm.stopPrank();
        gen = AssetGenerator(address(tempo));
    }

    function test_launchFee_goesToFeeTo_andTheExcessIsRefunded() public virtual override {
        uint256 quoteBefore = usdc.balanceOf(launcher);
        vm.prank(launcher);
        address coin = gen.launch("Launch Coin", "LNCH", SUPPLY, address(usdc), MIN6, FEES_ONLY);
        assertEq(usdc.balanceOf(feeTo), QUOTE_FEE, "fee paid in the quote token");
        assertEq(feeTo.balance, 0, "no native fee");
        assertEq(quoteBefore - usdc.balanceOf(launcher), QUOTE_FEE + MIN6, "the fee plus the dev buy, nothing else");
        assertTrue(coin != address(0));
    }
}

contract TempoDevBuyLaunchTest is TempoGenerator {
    function test_launch_revertsWhenTheQuoteFeeCannotBePaid() public {
        gen.setLaunchFee(type(uint128).max);
        vm.prank(launcher);
        vm.expectRevert();
        gen.launch("Launch Coin", "LNCH", SUPPLY, address(usdc), MIN6, FEES_ONLY);
    }

    function test_launch_withNoFeeTakesOnlyTheDevBuy() public {
        gen.setLaunchFee(0);
        uint256 quoteBefore = usdc.balanceOf(launcher);
        vm.prank(launcher);
        gen.launch("Launch Coin", "LNCH", SUPPLY, address(usdc), MIN6, FEES_ONLY);
        assertEq(quoteBefore - usdc.balanceOf(launcher), MIN6);
        assertEq(usdc.balanceOf(feeTo), 0);
    }
}

contract TempoDeferredLadderTest is TempoGenerator, DeferredLadderTest {
    function setUp() public override(TempoGenerator, DevBuyLaunchTest) {
        TempoGenerator.setUp();
    }

    function test_launchFee_goesToFeeTo_andTheExcessIsRefunded() public override(TempoGenerator, DevBuyLaunchTest) {
        TempoGenerator.test_launchFee_goesToFeeTo_andTheExcessIsRefunded();
    }
}
