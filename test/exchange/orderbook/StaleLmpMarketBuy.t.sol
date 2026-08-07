pragma solidity >=0.8;

import {MatchingEngine} from "../../../src/exchange/MatchingEngine.sol";
import {IOrderbook} from "../../../src/exchange/interfaces/IOrderbook.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {console} from "forge-std/console.sol";

/// Scenario under test: lmp (and therefore mktPrice) sits ABOVE the best ask,
/// then a market buy arrives. Does it still match the asks resting below the
/// market price?
contract StaleLmpMarketBuyTest is BaseSetup {
    function _pair() internal view returns (address) {
        return matchingEngine.getPair(address(token1), address(token2));
    }

    function testMarketBuyMatchesAsksBelowMarketPrice() public {
        super.setUp();
        // list at 1000; lmp is seeded to the listing price
        matchingEngine.addPair(
            address(token1),
            address(token2),
            1000e8,
            0,
            address(token1),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );

        // Rest asks BELOW the listing price: 900 and 950. The spread clamp pulls
        // these up and drags lmp down with them, so afterwards we reset lmp via
        // the admin updatePair path -- that writes lmp without touching the book,
        // which is precisely the "market price above the best ask" state.
        vm.prank(trader1);
        matchingEngine.limitSell(address(token1), address(token2), 900e8, 1e18, true, 5, trader1);
        vm.prank(trader1);
        matchingEngine.limitSell(address(token1), address(token2), 950e8, 1e18, true, 5, trader1);

        matchingEngine.updatePair(address(token1), address(token2), 1000e8, 0);

        (uint256 bidHead, uint256 askHead) = matchingEngine.heads(address(token1), address(token2));
        uint256 lmp = IOrderbook(_pair()).lmp();
        uint256 mkt = matchingEngine.mktPrice(address(token1), address(token2));

        console.log("--- before market buy ---");
        console.log("bidHead      ", bidHead);
        console.log("askHead      ", askHead);
        console.log("lmp          ", lmp);
        console.log("mktPrice     ", mkt);

        // The precondition: stored lmp sits above the best ask. Note mktPrice does
        // NOT -- the asks-only branch of _mktPrice clamps it to min(lmp, askHead),
        // so the reported market price is pinned to the ask. That clamp is the
        // answer to "can mktPrice exceed askHead": on a one-sided book, no.
        assertGt(lmp, askHead, "precondition: stored lmp must exceed askHead");
        assertEq(mkt, askHead, "mktPrice is clamped down to askHead on an asks-only book");

        uint256 baseBefore = token1.balanceOf(trader2);

        // Market buy with enough quote to clear both asks (~1850 + fees).
        vm.prank(trader2);
        token2.approve(address(matchingEngine), 5000e18);
        vm.prank(trader2);
        matchingEngine.marketBuy(
            address(token1),
            address(token2),
            2000e18,
            true,
            5,
            trader2,
            2000000
        );

        uint256 baseReceived = token1.balanceOf(trader2) - baseBefore;
        (bidHead, askHead) = matchingEngine.heads(address(token1), address(token2));

        console.log("--- after market buy ---");
        console.log("base received", baseReceived);
        console.log("bidHead      ", bidHead);
        console.log("askHead      ", askHead);
        console.log("lmp          ", IOrderbook(_pair()).lmp());
        console.log("mktPrice     ", matchingEngine.mktPrice(address(token1), address(token2)));

        // Did it actually fill against the cheap asks?
        assertGt(baseReceived, 0, "market buy filled nothing");
    }

    /// On a TWO-sided book _mktPrice returns lmp unclamped, so mktPrice really can
    /// exceed askHead. This is the state the question describes.
    function testTwoSidedBookMktPriceExceedsAskHead() public {
        super.setUp();
        matchingEngine.addPair(
            address(token1),
            address(token2),
            1000e8,
            0,
            address(token1),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );

        // one ask below, one bid below it, so both heads exist
        vm.prank(trader1);
        matchingEngine.limitSell(address(token1), address(token2), 950e8, 1e18, true, 5, trader1);
        vm.prank(trader2);
        token2.approve(address(matchingEngine), 5000e18);
        vm.prank(trader2);
        matchingEngine.limitBuy(address(token1), address(token2), 800e8, 100e18, true, 5, trader2);

        matchingEngine.updatePair(address(token1), address(token2), 1000e8, 0);

        (uint256 bidHead, uint256 askHead) = matchingEngine.heads(address(token1), address(token2));
        uint256 mkt = matchingEngine.mktPrice(address(token1), address(token2));
        console.log("--- two-sided book ---");
        console.log("bidHead      ", bidHead);
        console.log("askHead      ", askHead);
        console.log("lmp          ", IOrderbook(_pair()).lmp());
        console.log("mktPrice     ", mkt);

        assertGt(mkt, askHead, "two-sided: mktPrice exceeds askHead, unclamped");

        uint256 baseBefore = token1.balanceOf(trader2);
        vm.prank(trader2);
        matchingEngine.marketBuy(address(token1), address(token2), 2000e18, true, 5, trader2, 2000000);
        uint256 received = token1.balanceOf(trader2) - baseBefore;

        console.log("base received", received);
        console.log("lmp after    ", IOrderbook(_pair()).lmp());
        assertGt(received, 0, "market buy must still fill the ask below market price");
    }

    /// Same setup, but only ONE ask below market, to read the resulting lmp cleanly.
    function testLmpDirectionAfterBuyingBelowMarket() public {
        super.setUp();
        matchingEngine.addPair(
            address(token1),
            address(token2),
            1000e8,
            0,
            address(token1),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );

        vm.prank(trader1);
        matchingEngine.limitSell(address(token1), address(token2), 900e8, 1e18, true, 5, trader1);

        // restore lmp above the ask (see note in the test above)
        matchingEngine.updatePair(address(token1), address(token2), 1000e8, 0);

        uint256 lmpBefore = IOrderbook(_pair()).lmp();
        console.log("lmp before   ", lmpBefore);

        vm.prank(trader2);
        token2.approve(address(matchingEngine), 5000e18);
        vm.prank(trader2);
        matchingEngine.marketBuy(
            address(token1),
            address(token2),
            950e18,
            false, // isMaker false: no remainder resting, isolate the match path
            5,
            trader2,
            2000000
        );

        uint256 lmpAfter = IOrderbook(_pair()).lmp();
        console.log("lmp after    ", lmpAfter);
        console.log("mktPrice     ", matchingEngine.mktPrice(address(token1), address(token2)));

        // A BUY that moved the price DOWN would prove the match path is unguarded.
        if (lmpAfter < lmpBefore) {
            console.log(">>> buy moved lmp DOWN");
        } else if (lmpAfter > lmpBefore) {
            console.log(">>> buy moved lmp UP");
        } else {
            console.log(">>> lmp unchanged");
        }
    }
}
