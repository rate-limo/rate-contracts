// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {Test, console2} from "forge-std/Test.sol";
import {MatchingEngine} from "../../src/exchange/MatchingEngine.sol";
import {OrderbookFactory} from "../../src/exchange/orderbooks/OrderbookFactory.sol";
import {Orderbook} from "../../src/exchange/orderbooks/Orderbook.sol";
import {WETH9} from "../../src/mock/WETH9.sol";
import {MockToken} from "../../src/mock/MockToken.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {BandPoolFactory} from "../../src/swap/BandPoolFactory.sol";
import {BandPositionManager} from "../../src/swap/BandPositionManager.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";
import {BandSwapRouter} from "../../src/swap/BandSwapRouter.sol";

/**
 * ETH/USDC on the real stack, with the decimals it actually has.
 *
 * Every other band suite runs 18-against-18, which is the one shape that cannot catch
 * a decimals bug -- and the pool the old one replaced had a dedicated asymmetric test
 * for exactly that reason, deleted with it. ETH is 18, USDC is 6, and the venue's
 * price space is 8, so a single fill crosses all three scales:
 *
 *     150,000 USDC   = 150000000000        (6)
 *     74.712342 ETH  = 74712342...e18      (18)
 *     $2,002.00      = 200200000000        (8)
 *
 * The numbers asserted here are the ones published in the ETH/USDC walkthrough. This
 * is where they stop being arithmetic and start being measured.
 *
 * This contract lists the pair, so it is the pool's creator, and it re-spaces the
 * ladder to 1 / 3 / 5% of the pair's 10% limit: the 0.10 / 0.30 / 0.50% the walkthrough
 * was written on. (The factory default, 20 / 60 / 100%, would be 2 / 6 / 10% here.)
 */
contract BandEthUsdcTest is Test {
    MatchingEngine engine;
    OrderbookFactory obFactory;
    BandPoolFactory poolFactory;
    BandPositionManager manager;
    BandSwapRouter router;
    Orderbook book;
    BandPool pool;
    MockToken eth;   // 18 decimals
    MockToken usdc;  // 6 decimals
    WETH9 weth;

    address lp = address(0xA11CE);
    address taker = address(0xABCD);
    address booker = address(0xB00C);
    address creator = address(0xC0FFEE);

    uint256 constant MID = 2000e8;      // $2,000.00 in the venue's 8-decimal price space
    uint256 constant PER_BAND = 100e18; // 100 ETH in each band

    function setUp() public {
        vm.warp(1_000_000);
        vm.roll(100);

        eth = new MockToken("Ether", "ETH", 18);
        usdc = new MockToken("USD Coin", "USDC", 6);
        weth = new WETH9();

        engine = new MatchingEngine();
        obFactory = new OrderbookFactory();
        obFactory.initialize(address(engine));
        engine.initialize(address(obFactory), booker, address(weth));

        manager = new BandPositionManager();
        manager.initialize("");
        router = new BandSwapRouter();

        poolFactory = new BandPoolFactory();
        poolFactory.initialize(address(engine), address(manager), address(new BandPool()), creator);
        manager.setPoolFactory(address(poolFactory));
        engine.setPoolFactory(address(poolFactory));
        engine.setSwapRouter(address(router));

        engine.setDefaultSpread(10000000, 10000000, true);   // 10%, out of the way
        engine.setDefaultSpread(10000000, 10000000, false);
        engine.setDefaultFee(true, 100000);                  // 0.10% taker
        engine.setDefaultFee(false, 100000);

        engine.addPair(
            address(eth), address(usdc), MID, 0, address(eth),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        book = Orderbook(payable(engine.getPair(address(eth), address(usdc))));
        pool = BandPool(poolFactory.getPool(address(eth), address(usdc)));
        uint32[] memory fracs = new uint32[](3);
        uint32[] memory mults = new uint32[](3);
        fracs[0] = 1000000;
        fracs[1] = 3000000;
        fracs[2] = 5000000;
        mults[0] = 100000000;
        mults[1] = 200000000;
        mults[2] = 300000000;
        pool.configureBands(fracs, mults);

        vm.warp(block.timestamp + 600); // let the oracle answer for real

        uint8[] memory bands = new uint8[](3);
        uint256[] memory baseAmts = new uint256[](3);
        for (uint8 i = 0; i < 3; i++) {
            bands[i] = i;
            baseAmts[i] = PER_BAND;
        }
        eth.mint(lp, PER_BAND * 3);
        vm.startPrank(lp);
        eth.approve(address(manager), type(uint256).max);
        manager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: baseAmts,
                quoteAmounts: new uint256[](3),
                minShares: new uint128[](3),
                recipient: lp,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    /// USDC in, ETH out. `usdcIn` is in USDC's own 6 decimals.
    function _buy(uint256 usdcIn, uint256 minOut) internal returns (uint256) {
        usdc.mint(taker, usdcIn);
        vm.startPrank(taker);
        usdc.approve(address(router), type(uint256).max);
        uint256 out = router.swap(address(pool), usdcIn, true, taker, minOut);
        vm.stopPrank();
        return out;
    }

    function _quote(uint256 usdcIn) internal returns (uint256 out) {
        uint256 snap = vm.snapshotState();
        usdc.mint(address(0xDEAD), usdcIn);
        vm.startPrank(address(0xDEAD));
        usdc.approve(address(router), type(uint256).max);
        out = router.swap(address(pool), usdcIn, true, address(0xDEAD), 0);
        vm.stopPrank();
        vm.revertToState(snap);
    }

    // ---- the decimals themselves --------------------------------------------

    function test_theThreeScalesAreWhatTheyShouldBe() public view {
        assertEq(eth.decimals(), 18);
        assertEq(usdc.decimals(), 6);
        assertEq(book.lmp(), 200000000000, "$2,000.00 as 2000e8");
    }

    /**
     * A band's inventory is ETH at 18 and its counter-side is USDC at 6, and the bound
     * that prices them is at 8. If any of the three were assumed equal, this fill would
     * be out by a factor of 1e12.
     */
    function test_aSmallBuyPricesCorrectlyAcrossAllThreeScales() public {
        uint256 out = _buy(2002e6, 0); // 2,002 USDC at band 0's $2,002.00 bound
        // One ETH, less the 0.10% taker fee.
        assertApproxEqRel(out, 1e18 - 1e15, 1e12, "2,002 USDC buys ~1 ETH net of fee");
    }

    // ---- the published walkthrough, measured ---------------------------------

    /**
     * The 520,000 USDC trade from the ETH/USDC artifact: it should exhaust band 0 and
     * band 1 and take part of band 2, delivering ~258.83 ETH.
     *
     * More than the 258.47 first published, and the difference IS the re-spacing:
     * band 2 quotes 2,010 rather than 2,020 and charges 3x rather than 4x, so the tail
     * of the trade is cheaper on both counts. A better fill for the taker is what the
     * wide band's LPs gave up to become reachable.
     */
    function test_theFiveTwentyKWalkMatchesWhatWasPublished() public {
        uint256 out = _buy(520_000e6, 0);

        (uint256 r0,) = pool.bandReserves(0);
        (uint256 r1,) = pool.bandReserves(1);
        (uint256 r2,) = pool.bandReserves(2);
        console2.log("delivered ETH (wei):", out);
        console2.log("band 0 ETH left:", r0);
        console2.log("band 1 ETH left:", r1);
        console2.log("band 2 ETH left:", r2);

        assertEq(r0, 0, "band 0 emptied");
        assertEq(r1, 0, "band 1 emptied");
        assertGt(r2, 0, "band 2 partly consumed");
        assertApproxEqRel(out, 258.8256e18, 1e15, "~258.83 ETH on the 0.50% ladder");
        assertApproxEqRel(r2, 40.6965e18, 1e15, "~40.70 ETH still resting in band 2");
    }

    /**
     * The price the book records, and why v1's clamp is gone. In v1 a production-width
     * spread (0.10%) left band 2 quoting 0.50% past the rail, so the pool traded at a
     * price the book could not record and the rail clamped the print. In v2 the same
     * `setSpread` call re-syncs the pool in the same transaction and every band shrinks
     * with the limit, so band 2's bound is INSIDE the rail and is recorded as it is.
     */
    function test_theWalkPrintsBandTwosOwnBoundInsideTheRail() public {
        // Production spread for this leg, so the rail is the real one.
        engine.setSpread(address(eth), address(usdc), 100000, 100000, true);
        assertEq(pool.pairLimit(true), 100000, "the engine synced the pool itself");
        (uint32 tol2,) = pool.bandTolerances(2);
        assertEq(tol2, 5000, "band 2 is 5% of 0.10% now, not 0.50%");

        _buy(520_000e6, 0);
        (uint256 r2,) = pool.bandReserves(2);
        assertLt(r2, PER_BAND, "the walk reached band 2");

        uint256 ceiling = (MID * (1e8 + 100000)) / 1e8; // 2,002.00
        uint256 band2Bound = (MID * (1e8 + 5000)) / 1e8; // 2,000.10, exact at this MID
        assertEq(book.lmp(), band2Bound, "recorded at band 2's own bound, unclamped");
        assertLt(book.lmp(), ceiling, "which the rail never had to touch");
    }

    // ---- the slippage limit, in ETH/USDC terms -------------------------------

    /// A trade quoted across all three bands fills at 5 bps. Nothing to object to.
    function test_allThreeBandsFillAtFiveBasisPoints() public {
        uint256 quoted = _quote(520_000e6);
        uint256 out = _buy(520_000e6, (quoted * 9995) / 10000);
        assertGt(out, 0, "the wide bands are not refused by a tight tolerance");
    }

    /**
     * What a tight tolerance DOES refuse. Quoted inside band 0, then pushed to band 1
     * by somebody else's trade: 29.9 bps of shortfall against a 5 bps bound.
     */
    function test_beingPushedOutOfBandZeroRevertsAtFiveBasisPoints() public {
        uint256 quoted = _quote(150_000e6);
        uint256 minOut = (quoted * 9995) / 10000;

        _buy(210_000e6, 0); // drains band 0 ahead of us

        usdc.mint(taker, 150_000e6);
        vm.startPrank(taker);
        usdc.approve(address(router), type(uint256).max);
        vm.expectPartialRevert(BandPool.SlippageExceeded.selector);
        router.swap(address(pool), 150_000e6, true, taker, minOut);
        vm.stopPrank();
    }

    /// The step, measured in this pair rather than asserted from the 18/18 fixture.
    function test_theStepOutOfBandZeroIsAboutThirtyBasisPoints() public {
        uint256 before_ = _quote(150_000e6);
        _buy(210_000e6, 0);
        uint256 after_ = _quote(150_000e6);
        uint256 stepBps = ((before_ - after_) * 10000) / before_;
        console2.log("band 0 -> band 1 step in ETH/USDC, bps:", stepBps);
        assertGt(stepBps, 25);
        assertLt(stepBps, 35);
    }

    // ---- the other direction, where decimals usually break -------------------

    /**
     * Selling ETH for USDC. The bands hold no USDC until something has bought from
     * them, so this buys first -- and then the output is 6-decimal where the input was
     * 18, which is the conversion most likely to be off by 1e12.
     */
    function test_sellingEthBackOutPaysUsdcAtTheRightScale() public {
        _buy(300_000e6, 0); // give the bands USDC to pay with

        eth.mint(taker, 10e18);
        vm.startPrank(taker);
        eth.approve(address(router), type(uint256).max);
        uint256 usdcOut = router.swap(address(pool), 10e18, false, taker, 0);
        vm.stopPrank();

        console2.log("10 ETH sold for USDC (6dp):", usdcOut);
        // ~10 ETH at just under $2,000 (band 0 sells at 2,000 x 0.999), less the fee.
        assertGt(usdcOut, 19_000e6, "paid in USDC's own scale, not ETH's");
        assertLt(usdcOut, 20_000e6);
    }

    /// Protocol fees accrue in the currency the taker received, at that scale.
    function test_protocolFeesAccrueInTheRightCurrencyAndScale() public {
        _buy(2002e6, 0);
        assertGt(pool.protocolFeesBase(), 0, "a buy pays its fee in ETH");
        assertEq(pool.protocolFeesQuote(), 0, "and nothing in USDC");

        _buy(300_000e6, 0);
        eth.mint(taker, 10e18);
        vm.startPrank(taker);
        eth.approve(address(router), type(uint256).max);
        router.swap(address(pool), 10e18, false, taker, 0);
        vm.stopPrank();
        assertGt(pool.protocolFeesQuote(), 0, "a sell pays its fee in USDC");
    }
}
