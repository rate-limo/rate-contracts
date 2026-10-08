// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandEthUsdcTest} from "./BandEthUsdc.t.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";

/**
 * THE WALL, END TO END, ON ETH/USDC — deposit, trade, fee, withdraw.
 *
 * Every figure the wall walkthrough publishes is measured here, on the real stack
 * with the decimals it actually has: ETH at 18, USDC at 6, prices at 8. The inherited
 * fixture already seeded bands 0/1/2 with 100 ETH each at a $2,000.00 mid, which is
 * the pool a second LP would actually be joining.
 *
 * The LP here deposits USDC ALONE, with no conversion, into a band that holds only
 * ETH — so the wall is opened on the side the band does not have. That is deliberate:
 * it is the case the mode exists for and the one the accounting has to get right.
 */
contract BandWallWalkthroughTest is BandEthUsdcTest {
    address wallLp = address(0xBEEF01);

    uint256 constant WALL_USDC = 200_000e6; // 200,000 USDC, in USDC's own 6 decimals

    function _openWall(uint8 band, uint256 usdcIn) internal returns (uint256 id, uint128 shares) {
        usdc.mint(wallLp, usdcIn);
        uint8[] memory bands = new uint8[](1);
        bands[0] = band;
        uint256[] memory zeroBase = new uint256[](1);
        uint256[] memory q = new uint256[](1);
        q[0] = usdcIn;
        uint128[] memory got;
        vm.startPrank(wallLp);
        usdc.approve(address(manager), type(uint256).max);
        (id, got) = manager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: zeroBase,
                quoteAmounts: q,
                minShares: new uint128[](1),
                recipient: wallLp,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
        shares = got[0];
    }

    /// ETH the taker sells into the pool, which is what a quote-side wall absorbs.
    function _sell(uint256 ethIn) internal returns (uint256 usdcOut) {
        eth.mint(taker, ethIn);
        vm.startPrank(taker);
        eth.approve(address(router), type(uint256).max);
        usdcOut = router.swap(address(pool), ethIn, false, taker, 0);
        vm.stopPrank();
    }

    /**
     * A USDC wall joining an ETH-only ladder: allowed, and priced by value.
     *
     * This used to revert -- the pro-rata rule cannot serve one token into a band
     * holding the other -- and `_price` now prices it against the anchor instead.
     * The walkthrough below still uses a band of its own, because a wall opening an
     * EMPTY band is the case its figures are about.
     */
    function test_aUsdcWallJoinsAnEthOnlyLadderByValue() public {
        engine.setPoolFeeShare(50000000);
        usdc.mint(wallLp, WALL_USDC);
        uint8[] memory bands = new uint8[](1);
        bands[0] = 0;
        uint256[] memory q = new uint256[](1);
        q[0] = WALL_USDC;
        vm.startPrank(wallLp);
        usdc.approve(address(manager), type(uint256).max);
        (, uint128[] memory got) = manager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: new uint256[](1),
                quoteAmounts: q,
                minShares: new uint128[](1),
                recipient: wallLp,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
        assertGt(got[0], 0, "the ETH-only band took the USDC");
        (, uint256 rq) = pool.bandReserves(0);
        assertEq(rq, WALL_USDC, "all of it became reserve");
    }

    /**
     * So the measured walkthrough runs on a band the wall OPENS: the ladder is
     * re-spaced to four bands and band 3 is left empty for it.
     */
    function test_theWallWalkthrough() public {
        // ---- a fourth, empty band for the wall to open -----------------------
        uint32[] memory fracs = new uint32[](4);
        uint32[] memory mults = new uint32[](4);
        fracs[0] = 1000000; fracs[1] = 3000000; fracs[2] = 5000000; fracs[3] = 7000000;
        mults[0] = 100000000; mults[1] = 200000000; mults[2] = 300000000; mults[3] = 300000000;
        pool.configureBands(fracs, mults);

        /*
         * The LPs' share of the taker fee. The inherited fixture never sets it, so it
         * is 0 there and every fee goes to the protocol -- which is a real setting, not
         * a bug, and measuring the wall on it would have published a zero yield. Both
         * deployed chains use 50%, so that is what this walks.
         */
        engine.setPoolFeeShare(50000000);

        // ---- 1. the deposit --------------------------------------------------
        (uint256 id, uint128 shares) = _openWall(3, WALL_USDC);
        (uint256 rb0, uint256 rq0) = pool.bandReserves(3);
        emit log_named_uint("1 deposit  usdc in      ", WALL_USDC);
        emit log_named_uint("1 deposit  shares minted", shares);
        emit log_named_uint("1 deposit  band eth     ", rb0);
        emit log_named_uint("1 deposit  band usdc    ", rq0);
        emit log_named_uint("1 deposit  lp eth held  ", eth.balanceOf(wallLp));
        assertEq(shares, WALL_USDC, "one share per USDC unit -- the opener sets the scale");
        assertEq(rb0, 0, "the wall invented no ETH");
        assertEq(rq0, WALL_USDC, "all of it is principal");

        // ---- 2. a trader sells ETH into the ladder ---------------------------
        uint256 usdcOut = _sell(60e18);
        (uint256 rb1, uint256 rq1) = pool.bandReserves(3);
        emit log_named_uint("2 trade    eth sold     ", 60e18);
        emit log_named_uint("2 trade    usdc to taker", usdcOut);
        emit log_named_uint("2 trade    band eth     ", rb1);
        emit log_named_uint("2 trade    band usdc    ", rq1);
        assertGt(rb1, 0, "the wall has been converted into ETH, by a trade");
        assertLt(rq1, WALL_USDC, "and spent USDC doing it");

        // ---- 3. the fee it earned -------------------------------------------
        vm.warp(block.timestamp + 7 days); // well past maturity, so everything vests
        uint256 feeEthBefore = eth.balanceOf(wallLp);
        uint256 feeUsdcBefore = usdc.balanceOf(wallLp);
        vm.prank(wallLp);
        manager.collect(id, wallLp);
        uint256 feeEth = eth.balanceOf(wallLp) - feeEthBefore;
        uint256 feeUsdc = usdc.balanceOf(wallLp) - feeUsdcBefore;
        emit log_named_uint("3 fees     eth          ", feeEth);
        emit log_named_uint("3 fees     usdc         ", feeUsdc);
        /*
         * FEES ACCRUE IN THE TOKEN THE BAND PAYS OUT, not the one it takes in.
         * `_fillBand` charges the fee on `out` and credits `feeGrowthQuote` on a sell
         * (quote leaving) and `feeGrowthBase` on a buy. So a wall that is being
         * converted INTO ETH earns its fee in USDC -- the side it is giving up.
         */
        assertGt(feeUsdc, 0, "paid in the token the band handed over");
        assertEq(feeEth, 0, "and not in the one it received");

        // ---- 4. the exit -----------------------------------------------------
        vm.prank(wallLp);
        (uint256 baseOut, uint256 quoteOut) =
            manager.decreaseLiquidity(id, 10_000, 0, 0, wallLp, block.timestamp);
        emit log_named_uint("4 withdraw eth out      ", baseOut);
        emit log_named_uint("4 withdraw usdc out     ", quoteOut);

        // ---- 5. the books --------------------------------------------------
        uint256 endEth = eth.balanceOf(wallLp);
        uint256 endUsdc = usdc.balanceOf(wallLp);
        emit log_named_uint("5 final    eth          ", endEth);
        emit log_named_uint("5 final    usdc         ", endUsdc);
        // Valued at the $2,000 mid, in USDC units: usdc + eth * 2000 / 1e12.
        uint256 endValue = endUsdc + (endEth * 2000) / 1e12;
        emit log_named_uint("5 final    value @2000  ", endValue);
        emit log_named_uint("5 final    started with  ", WALL_USDC);
        /*
         * The gain splits into two sources that must not be conflated:
         *   spread -- the wall bought ETH at band 3's bound, 0.7% under the mid
         *   fee    -- its half of the taker fee, at 3x for this band
         * Neither is protection from the price moving: valuing at the mid it converted
         * around is a measurement, not a hedge.
         */
        emit log_named_uint("5 split    from spread   ", (60e18 * 14) / 1e12);
        emit log_named_uint("5 split    from fee      ", feeUsdc);
        assertGe(endValue, WALL_USDC, "the wall is not down at the mid it converted around");

        (uint256 rbEnd, uint256 rqEnd) = pool.bandReserves(3);
        assertEq(rbEnd, 0, "nothing of the wall is left behind");
        assertEq(rqEnd, 0, "on either side");
        assertEq(eth.balanceOf(address(manager)), 0, "and nothing stranded in the manager");
        assertEq(usdc.balanceOf(address(manager)), 0, "on either side");
    }
}
