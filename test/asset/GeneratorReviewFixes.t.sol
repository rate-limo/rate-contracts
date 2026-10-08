// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AssetGenerator} from "../../src/asset/AssetGenerator.sol";
import {MockBase} from "../../src/mock/MockBase.sol";
import {MockQuote} from "../../src/mock/MockQuote.sol";
import {DevBuyLaunchTest} from "./DevBuyLaunch.t.sol";

/// Second-review lows: L-a (no irreversible reassignment) and L-b (slippage caps survive
/// a generator replacement).
contract GeneratorReviewFixesTest is DevBuyLaunchTest {
    function test_reassignPairLister_refusesZero() public {
        (MockBase b, MockQuote q) = _newPair();
        address pair = _list(b, q, 10, 100_000);
        vm.expectRevert(AssetGenerator.ZeroAddress.selector);
        gen.reassignPairLister(pair, address(0));
        // Still reassignable afterwards.
        gen.reassignPairLister(pair, trader2);
        assertEq(gen.pairLister(pair), trader2);
    }

    function test_slippageLimitOf_forwardsToThePreviousGenerator() public {
        address coin = _launch(address(usdc), MIN6);
        AssetGenerator next = new AssetGenerator(address(this), address(matchingEngine));

        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.NotAGeneratedCoin.selector, coin));
        next.slippageLimitOf(coin, address(usdc));

        next.setFallbackIncentive(address(gen));
        assertEq(next.slippageLimitOf(coin, address(usdc)), gen.slippageLimitOf(coin, address(usdc)));
        assertEq(next.slippageLimitOf(coin, address(usdc)), 100, "the old coin keeps its Meme cap");
    }
}
