// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AssetGenerator} from "../../src/asset/AssetGenerator.sol";
import {AssetLaunchLib} from "../../src/asset/libraries/AssetLaunchLib.sol";
import {IOrderbook} from "../../src/exchange/interfaces/IOrderbook.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {DevBuyLaunchTest} from "./DevBuyLaunch.t.sol";

/**
 * Two-transaction launches, for chains whose per-transaction gas cap cannot hold a whole
 * launch. Tempo prices a new storage slot at 250k gas under a 30M cap, and launch()
 * measured 29.98M there; `ladderDeferred` moves the five ladder asks (~12M on Tempo)
 * into a second call, `placeLadder`.
 *
 * What must hold: the deferred ladder is the SAME ladder an inline launch places, nothing
 * can be bought or graduated before it exists, and it can be placed exactly once.
 */
contract DeferredLadderTest is DevBuyLaunchTest {
    function _deferredLaunch() internal returns (address coin) {
        gen.setLadderDeferred(true);
        coin = _launch(address(usdc), MIN6);
    }

    function test_deferredLaunch_listsWithNoLadder() public {
        address coin = _deferredLaunch();
        AssetLaunchLib.Ladder memory l = gen.ladderOf(coin);
        assertTrue(l.pair != address(0), "the pair is listed");
        for (uint256 i; i < 5; i++) assertEq(l.askIds[i], 0, "no ask placed yet");
        (, uint256 askHead) = IOrderbook(l.pair).heads();
        assertEq(askHead, 0, "nothing for sale before placeLadder");
        // The ladder and the held-back supply wait in the generator.
        assertEq(IERC20(coin).balanceOf(address(gen)), SUPPLY - IERC20(coin).balanceOf(launcher));
    }

    function test_graduation_refusesAnUnplacedLadder() public {
        address coin = _deferredLaunch();
        vm.expectRevert(AssetLaunchLib.LadderNotPlaced.selector);
        gen.graduate(coin);
    }

    function test_placeLadder_placesTheSameLadderAsAnInlineLaunch() public {
        address inline_ = _launch(address(usdc), MIN6);
        address deferred = _deferredLaunch();
        vm.prank(address(0xBEEF)); // anyone may place it
        gen.placeLadder(deferred);

        AssetLaunchLib.Ladder memory a = gen.ladderOf(inline_);
        AssetLaunchLib.Ladder memory b = gen.ladderOf(deferred);
        assertEq(b.restoreBuySpread, a.restoreBuySpread, "same spread restore");
        for (uint256 i; i < 5; i++) {
            ExchangeOrderbook.Order memory oa = IOrderbook(a.pair).getOrder(false, a.askIds[i]);
            ExchangeOrderbook.Order memory ob = IOrderbook(b.pair).getOrder(false, b.askIds[i]);
            assertTrue(b.askIds[i] != 0, "placed");
            assertEq(ob.price, oa.price, "same step price");
            assertEq(ob.depositAmount, oa.depositAmount, "same step size");
            assertEq(ob.owner, b.escrow, "owned by the coin's escrow");
        }
        assertEq(IERC20(deferred).balanceOf(address(gen)), 0, "generator keeps nothing");
        assertEq(
            IERC20(deferred).balanceOf(b.escrow), IERC20(inline_).balanceOf(a.escrow), "same held-back supply"
        );
    }

    function test_placeLadder_onlyOnce() public {
        address coin = _deferredLaunch();
        gen.placeLadder(coin);
        vm.expectRevert(AssetLaunchLib.LadderAlreadyPlaced.selector);
        gen.placeLadder(coin);
    }

    function test_placeLadder_inlineLaunchIsAlreadyPlaced() public {
        address coin = _launch(address(usdc), MIN6);
        vm.expectRevert(AssetLaunchLib.LadderAlreadyPlaced.selector);
        gen.placeLadder(coin);
    }

    function test_placeLadder_unknownCoinReverts() public {
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.CoinNotLaunched.selector, address(0xC0FFEE)));
        gen.placeLadder(address(0xC0FFEE));
    }

    function test_setLadderDeferred_isAdminOnly() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        gen.setLadderDeferred(true);
    }

    function test_deferredLaunch_sellsOutAndGraduates() public {
        address coin = _deferredLaunch();
        gen.placeLadder(coin);
        for (uint256 i; i < 5; i++) _buyStep(coin, address(uint160(0xB0 + i)), i);
        gen.graduate(coin); // arms
        vm.warp(block.timestamp + gen.GRADUATION_DELAY());
        gen.graduate(coin);
        (,,,,,,,, bool graduated) = gen.launches(coin);
        assertTrue(graduated, "graduated");
    }
}
