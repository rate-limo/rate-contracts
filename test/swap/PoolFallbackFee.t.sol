// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {IMatchingEngine} from "../../src/exchange/interfaces/IMatchingEngine.sol";
import {Orderbook} from "../../src/exchange/orderbooks/Orderbook.sol";
import {MockBase} from "../../src/mock/MockBase.sol";
import {MockQuote} from "../../src/mock/MockQuote.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";
import {BandBaseSetup} from "./BandBaseSetup.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * A taker's remainder must be able to fill from the pool at the order's own price.
 *
 * `PoolFallbackLib.route` bounds the pool swap with `minAmountOut`. It used to be the GROSS
 * amount at the order's price, while `BandPool` pays out NET of its band fee -- so a pool
 * filling at exactly that price, the best its rail allows, always came up short by precisely
 * the fee, reverted `SlippageExceeded`, and the taker was refunded. On RISE KPRF1448/tUSD
 * (pool 0xBce97DC6..., three bands at +-0.02/0.06/0.10%, 1x/2x/3x fees on a 1% engine taker
 * rate) 300 tUSD at 500 asked for 60.0M KPRF and was offered 59.4M: never a fill.
 *
 * This replays that shape on a local stack: price 500, a 0.1% market spread, a 1% taker fee,
 * the same band fractions and fee multipliers, and only base in the pool.
 */
contract PoolFallbackFeeTest is BandBaseSetup {
    uint256 constant LOW = 500; // 0.000005 quote on the 1e8 grid
    uint32 constant MKT_SPREAD = 100_000; // 0.1%
    uint32 constant TAKER_FEE = 1_000_000; // 1%

    bytes32 constant POOLED = keccak256("RemainderRoutedToPool(address,address,uint256,uint256)");

    MockBase kprf;
    MockQuote tusd;
    Orderbook lowBook;
    BandPool lowPool;

    function setUp() public override {
        super.setUp();
        kprf = new MockBase("KPRF", "KPRF");
        tusd = new MockQuote("tUSD", "tUSD");
        kprf.mint(lp1, 1_000_000_000e18);
        tusd.mint(trader2, 1_000_000e18);

        // Defaults are copied into a pair when it is listed, so set them first.
        matchingEngine.setDefaultSpread(MKT_SPREAD, MKT_SPREAD, true);
        matchingEngine.setDefaultFee(false, TAKER_FEE);
        matchingEngine.addPair(
            address(kprf), address(tusd), LOW, 0, address(kprf),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        lowBook = Orderbook(payable(matchingEngine.getPair(address(kprf), address(tusd))));
        lowPool = BandPool(poolFactory.getPool(address(kprf), address(tusd)));

        uint32[] memory fracs = new uint32[](3);
        uint32[] memory mults = new uint32[](3);
        (fracs[0], fracs[1], fracs[2]) = (20_000_000, 60_000_000, 100_000_000); // of a 0.1% limit
        (mults[0], mults[1], mults[2]) = (100_000_000, 200_000_000, 300_000_000);
        lowPool.configureBands(fracs, mults);

        // ~66M KPRF per band, base only, as on RISE.
        vm.startPrank(lp1);
        kprf.approve(address(positionManager), type(uint256).max);
        uint8[] memory bands = new uint8[](3);
        uint256[] memory baseAmounts = new uint256[](3);
        for (uint8 i = 0; i < 3; i++) {
            bands[i] = i;
            baseAmounts[i] = 66_000_000e18;
        }
        positionManager.mint(IBandPositionManager.MintParams({
            pool: address(lowPool), bands: bands, baseAmounts: baseAmounts,
            quoteAmounts: new uint256[](3), minShares: new uint128[](3),
            recipient: lp1, deadline: block.timestamp
        }));
        vm.stopPrank();

        vm.prank(trader2);
        tusd.approve(address(matchingEngine), type(uint256).max);
    }

    function _pooled() internal returns (bool pooled) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == POOLED) pooled = true;
        }
    }

    function test_fixtureMatchesRise() public view {
        assertEq(lowBook.lmp(), LOW);
        assertEq(lowPool.effectiveFeeRate(0, matchingEngine.feeOf(address(kprf), address(tusd), address(matchingEngine), false)), TAKER_FEE);
        assertEq(lowBook.askHead(), 0, "the book is empty: only the pool can fill");
    }

    /// The RISE replay: a 300 tUSD market buy, isMaker = false, fills from the pool.
    function test_marketBuy_takerRemainder_fillsFromThePool() public {
        uint256 kprfBefore = kprf.balanceOf(trader2);
        uint256 tusdBefore = tusd.balanceOf(trader2);

        vm.recordLogs();
        vm.prank(trader2);
        matchingEngine.marketBuy(IMatchingEngine.MarketOrderInput({
            base: address(kprf), quote: address(tusd), amount: 300e18,
            isMaker: false, n: 5, recipient: trader2, slippageLimit: MKT_SPREAD
        }));
        assertTrue(_pooled(), "RemainderRoutedToPool must fire");

        uint256 received = kprf.balanceOf(trader2) - kprfBefore;
        uint256 spent = tusdBefore - tusd.balanceOf(trader2);
        assertEq(spent, 300e18, "the whole order went to the pool");

        // What 300 tUSD buys at 500, less the pool's 1%: 60.0M gross, 59.4M net -- the exact
        // pair of numbers measured on RISE, where 59.4M used to be refused against 60.0M.
        // (The engine's own taker fee is charged on book matches, not at deposit, so a
        // remainder routed to the pool pays only the pool's fee.)
        uint256 gross = (300e18 * 1e8) / LOW;
        assertEq(gross, 60_000_000e18);
        assertEq(received, gross - gross / 100, "filled at the order's price, net of the band-0 fee");
        assertEq(received, 59_400_000e18);
    }

    /// The fee is deducted; the PRICE bound is not loosened. A taker limit buy below the
    /// pool's price is still refused and refunded, exactly as before.
    function test_limitBuyBelowThePoolPrice_isStillRefused() public {
        uint256 tusdBefore = tusd.balanceOf(trader2);

        vm.recordLogs();
        vm.prank(trader2);
        matchingEngine.limitBuy(IMatchingEngine.LimitOrderInput({
            base: address(kprf), quote: address(tusd), price: LOW - 1,
            amount: 300e18, isMaker: false, n: 5, recipient: trader2
        }));
        assertFalse(_pooled(), "the pool fills at 500, worse than the 499 asked for");
        assertEq(tusd.balanceOf(trader2), tusdBefore, "refunded in full");
        assertEq(
            tusd.allowance(address(matchingEngine), address(lowPool)), 0, "no allowance left behind"
        );
    }
}
