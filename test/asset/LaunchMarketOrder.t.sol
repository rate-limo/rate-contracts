// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMatchingEngine} from "../../src/exchange/interfaces/IMatchingEngine.sol";
import {IOrderbook} from "../../src/exchange/interfaces/IOrderbook.sol";
import {OrderPlacementLib} from "../../src/exchange/libraries/OrderPlacementLib.sol";
import {LadderBuyerTest} from "./LadderBuyer.t.sol";

/**
 * A DIRECT market order against a coin still in its launch ladder.
 *
 * AssetLaunchLib closes the bands at launch, so before graduation the pool takes nothing by
 * construction. The app routes launch buys through LadderBuyer, whose limit orders never
 * revert, but a direct market order goes through the engine's REQUIRE_FILL rule
 * (QuoteNotPrice.t.sol): it must match the book within the spread, or it reverts
 * InsufficientLiquidity. These pin which side of that rule each direction lands on.
 */
contract LaunchMarketOrderTest is LadderBuyerTest {
    function _market(address coin, bool isBuy, uint256 amount) internal {
        IMatchingEngine.MarketOrderInput memory o = IMatchingEngine.MarketOrderInput({
            base: coin, quote: address(usdc), amount: amount,
            isMaker: false, n: 5, recipient: alice, slippageLimit: 1_000_000
        });
        vm.prank(alice);
        if (isBuy) matchingEngine.marketBuy(o);
        else matchingEngine.marketSell(o);
    }

    /// Nothing bids on a launching coin and the pool is closed: a market sell has nothing
    /// to trade against, and reverts rather than refunding in silence.
    function test_directMarketSell_onLaunchingCoin_reverts() public {
        address coin = _launch(address(usdc), MIN6);
        _fund(alice, 11_000e6);
        _buy(coin, 1_500e6, 2500, 0);
        uint256 coins = IERC20(coin).balanceOf(alice);
        vm.prank(alice);
        IERC20(coin).approve(address(matchingEngine), type(uint256).max);

        vm.expectRevert(OrderPlacementLib.InsufficientLiquidity.selector);
        _market(coin, false, coins);
        assertEq(IERC20(coin).balanceOf(alice), coins, "nothing was spent");
    }

    /// A market buy against the ladder's open step is a book match, so the bands being
    /// closed does not matter: it fills from the step the price sits at.
    function test_directMarketBuy_onLaunchingCoin_fillsFromTheLadder() public {
        address coin = _launch(address(usdc), MIN6);
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(matchingEngine), type(uint256).max);

        _market(coin, true, 100e6);
        assertGt(IERC20(coin).balanceOf(alice), 0, "filled from the first launch step");
    }
}
