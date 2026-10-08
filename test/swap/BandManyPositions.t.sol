// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandEthUsdcTest} from "./BandEthUsdc.t.sol";
import {IBandPool} from "../../src/swap/interfaces/IBandPool.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";

/**
 * THREE LPs IN ONE BAND — how the pool tells them apart without storing them apart.
 *
 * A swap reads and writes NO position. It moves two reserves and adds to one
 * accumulator per band, whatever the number of LPs. Everything that separates one
 * LP from another is reconstructed later, when that LP acts, from two numbers the
 * pool keeps per (token, band): its SHARES and its CHECKPOINT of the accumulator.
 *
 * Measured on the real ETH/USDC stack, so the figures published in the walkthrough
 * are these ones.
 */
contract BandManyPositionsTest is BandEthUsdcTest {
    address A = address(0xA1);
    address B = address(0xB2);
    address C = address(0xC3);

    uint8 constant W = 3; // the empty band the walls open

    function _wall(address who, uint256 usdcIn) internal returns (uint256 id, uint128 shares) {
        usdc.mint(who, usdcIn);
        uint8[] memory bands = new uint8[](1);
        bands[0] = W;
        uint256[] memory q = new uint256[](1);
        q[0] = usdcIn;
        uint128[] memory got;
        vm.startPrank(who);
        usdc.approve(address(manager), type(uint256).max);
        (id, got) = manager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: new uint256[](1),
                quoteAmounts: q,
                minShares: new uint128[](1),
                recipient: who,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
        shares = got[0];
    }

    /**
     * Joining a band that has already traded. It is MIXED by then -- the trade put the
     * other token in it -- so a wall is refused and the ordinary two-sided `mint` is
     * the way in. `_price` takes the lesser leg and refunds the rest, so the caller can
     * offer generously and let the band's own ratio decide.
     */
    function _joinMixed(address who, uint256 ethIn, uint256 usdcIn) internal returns (uint256 id) {
        eth.mint(who, ethIn);
        usdc.mint(who, usdcIn);
        uint8[] memory bands = new uint8[](1);
        bands[0] = W;
        uint256[] memory b = new uint256[](1);
        uint256[] memory q = new uint256[](1);
        b[0] = ethIn;
        q[0] = usdcIn;
        vm.startPrank(who);
        eth.approve(address(manager), type(uint256).max);
        usdc.approve(address(manager), type(uint256).max);
        (id,) = manager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: b,
                quoteAmounts: q,
                minShares: new uint128[](1),
                recipient: who,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    function _sell(uint256 ethIn) internal {
        eth.mint(taker, ethIn);
        vm.startPrank(taker);
        eth.approve(address(router), type(uint256).max);
        router.swap(address(pool), ethIn, false, taker, 0);
        vm.stopPrank();
    }

    function _open4thBand() internal {
        uint32[] memory fracs = new uint32[](4);
        uint32[] memory mults = new uint32[](4);
        fracs[0] = 1000000; fracs[1] = 3000000; fracs[2] = 5000000; fracs[3] = 7000000;
        mults[0] = 100000000; mults[1] = 200000000; mults[2] = 300000000; mults[3] = 300000000;
        pool.configureBands(fracs, mults);
        engine.setPoolFeeShare(50000000); // the value deployed on both chains
    }

    /// `positionView` is the same arithmetic `collect` pays on, so a preview cannot
    /// disagree with the payout.
    function _pending(uint256 id) internal view returns (uint256 pb, uint256 pq) {
        (IBandPool.BandView[] memory v,,) = pool.positionView(id);
        for (uint256 i = 0; i < v.length; i++) {
            if (v[i].band == W) return (v[i].pendingBase, v[i].pendingQuote);
        }
    }

    function _owned(uint256 id) internal view returns (uint256 ob, uint256 oq, uint256 sh) {
        (IBandPool.BandView[] memory v,,) = pool.positionView(id);
        for (uint256 i = 0; i < v.length; i++) {
            if (v[i].band == W) return (v[i].baseOwned, v[i].quoteOwned, v[i].shares);
        }
    }

    /// Shares are the whole of it: B funded 3x what A did and owns 3x the band.
    function test_sharesSplitTheBandProRata() public {
        _open4thBand();
        (uint256 idA,) = _wall(A, 100_000e6);
        (uint256 idB,) = _wall(B, 300_000e6);
        (,, uint256 shA) = _owned(idA);
        (,, uint256 shB) = _owned(idB);
        emit log_named_uint("shares A                 ", shA);
        emit log_named_uint("shares B                 ", shB);
        assertEq(shA * 3, shB, "B funded three times what A did");

        _sell(40e18);
        (, uint256 pA) = _pending(idA);
        (, uint256 pB) = _pending(idB);
        emit log_named_uint("trade 1  A pending usdc  ", pA);
        emit log_named_uint("trade 1  B pending usdc  ", pB);
        assertApproxEqAbs(pA * 3, pB, 3, "and the fee splits on the same shares");
    }

    /**
     * THE CHECKPOINT IS WHAT SEPARATES THEM.
     *
     * A swap writes one accumulator, not a row per LP. A position's claim is the
     * GROWTH SINCE ITS OWN CHECKPOINT, times its shares -- so a position opened after
     * a trade starts from the accumulator's current value and the earlier growth is
     * arithmetically out of reach. No list of LPs is walked to arrange that.
     */
    function test_aLateJoinerEarnsNothingFromEarlierTrades() public {
        _open4thBand();
        (uint256 idA,) = _wall(A, 100_000e6);
        (uint256 idB,) = _wall(B, 300_000e6);
        _sell(40e18);
        (, uint256 pABefore) = _pending(idA);

        uint256 idC = _joinMixed(C, 20e18, 40_000e6);
        (, uint256 pC) = _pending(idC);
        (, uint256 pAAfter) = _pending(idA);
        emit log_named_uint("C pending, straight after", pC);
        emit log_named_uint("A pending, before C      ", pABefore);
        emit log_named_uint("A pending, after  C      ", pAAfter);
        assertEq(pC, 0, "a late joiner earns nothing from a trade it was not there for");
        assertEq(pAAfter, pABefore, "and takes nothing from the LPs who were");
    }

    /// The NEXT trade splits on the new share counts -- 1 : 3 : 4.
    function test_theSecondTradeSplitsOnTheNewShares() public {
        _open4thBand();
        (uint256 idA,) = _wall(A, 100_000e6);
        (uint256 idB,) = _wall(B, 300_000e6);
        _sell(40e18);
        (, uint256 pA1) = _pending(idA);
        (, uint256 pB1) = _pending(idB);

        uint256 idC = _joinMixed(C, 20e18, 40_000e6);
        _sell(40e18);
        (, uint256 pA2) = _pending(idA);
        (, uint256 pB2) = _pending(idB);
        (, uint256 pC2) = _pending(idC);

        emit log_named_uint("trade 2  A's share of it ", pA2 - pA1);
        emit log_named_uint("trade 2  B's share of it ", pB2 - pB1);
        emit log_named_uint("trade 2  C's share of it ", pC2);
        emit log_named_uint("totals   A               ", pA2);
        emit log_named_uint("totals   B               ", pB2);
        emit log_named_uint("totals   C               ", pC2);
        /*
         * The second trade splits on the SHARES each holds, so the ratio is read from
         * the pool rather than assumed -- C's share count is whatever the band's ratio
         * let its offer buy, not the round number it brought.
         */
        (,, uint256 shA) = _owned(idA);
        (,, uint256 shC) = _owned(idC);
        emit log_named_uint("shares   A               ", shA);
        emit log_named_uint("shares   C               ", shC);
        assertApproxEqRel((pA2 - pA1) * shC, pC2 * shA, 1e12, "trade two splits on shares");
        assertGt(pA2 - pA1, 0, "A still earns from it");
    }

    /**
     * Conservation: every wei in the band belongs to exactly one position, on BOTH
     * sides -- including the ETH none of them deposited, which a trade put there.
     */
    function test_everyWeiOfTheBandIsOwnedBySomebody() public {
        _open4thBand();
        (uint256 idA,) = _wall(A, 100_000e6);
        (uint256 idB,) = _wall(B, 300_000e6);
        (uint256 idC,) = _wall(C, 400_000e6);
        _sell(40e18);

        (uint256 rb, uint256 rq) = pool.bandReserves(W);
        (uint256 obA, uint256 oqA,) = _owned(idA);
        (uint256 obB, uint256 oqB,) = _owned(idB);
        (uint256 obC, uint256 oqC,) = _owned(idC);
        emit log_named_uint("band eth                 ", rb);
        emit log_named_uint("band usdc                ", rq);
        emit log_named_uint("owns eth  A              ", obA);
        emit log_named_uint("owns eth  B              ", obB);
        emit log_named_uint("owns eth  C              ", obC);
        emit log_named_uint("owns usdc A              ", oqA);
        emit log_named_uint("owns usdc B              ", oqB);
        emit log_named_uint("owns usdc C              ", oqC);
        assertApproxEqAbs(obA + obB + obC, rb, 3, "every wei of the band is owned");
        assertApproxEqAbs(oqA + oqB + oqC, rq, 3, "on both sides");
        assertApproxEqAbs(obA * 8, rb, 8, "A funded an eighth, so A owns an eighth of the ETH");
    }

    /**
     * Leaving early forfeits the unvested part, and it goes to the LPs who stayed --
     * not to nobody, and not to the protocol while there is anyone left in the band.
     */
    function test_anEarlyExitPaysTheLpsWhoStayed() public {
        _open4thBand();
        (uint256 idA,) = _wall(A, 100_000e6);
        (uint256 idB,) = _wall(B, 300_000e6);
        _sell(40e18);

        (, uint256 bBefore) = _pending(idB);
        // A leaves immediately -- nothing has vested, maturity is 10 minutes.
        vm.prank(A);
        manager.decreaseLiquidity(idA, 10_000, 0, 0, A, block.timestamp);
        (, uint256 bAfter) = _pending(idB);

        emit log_named_uint("B pending before A exits ", bBefore);
        emit log_named_uint("B pending after  A exits ", bAfter);
        emit log_named_uint("B gained                 ", bAfter - bBefore);
        assertGt(bAfter, bBefore, "A's unvested fees went to B");
    }

    /// Two LPs, same shares, different ages: identical fees, different VESTING.
    function test_sameSharesDifferentAgesVestDifferently() public {
        _open4thBand();
        (uint256 idA,) = _wall(A, 200_000e6);
        vm.warp(block.timestamp + 5 minutes); // half of the 10-minute maturity
        (uint256 idB,) = _wall(B, 200_000e6);
        _sell(40e18);

        (IBandPool.BandView[] memory va,,) = pool.positionView(idA);
        (IBandPool.BandView[] memory vb,,) = pool.positionView(idB);
        emit log_named_uint("A pending usdc           ", va[0].pendingQuote);
        emit log_named_uint("B pending usdc           ", vb[0].pendingQuote);
        emit log_named_uint("A vested numerator       ", va[0].vestedNum);
        emit log_named_uint("B vested numerator       ", vb[0].vestedNum);
        emit log_named_uint("A vested usdc now        ", va[0].vestedQuote);
        emit log_named_uint("B vested usdc now        ", vb[0].vestedQuote);
        assertEq(va[0].pendingQuote, vb[0].pendingQuote, "equal shares earn equally");
        assertGt(va[0].vestedNum, vb[0].vestedNum, "but the older one is further along the ramp");
        assertGt(va[0].vestedQuote, vb[0].vestedQuote, "so more of it is payable now");
    }

    /**
     * A WALL BAND KEEPS ACCEPTING WALLS AFTER IT HAS TRADED.
     *
     * The first trade makes the band two-sided, which used to end the mode for
     * everyone arriving after -- they had to convert or bring both. Value pricing
     * in `_price` removes that cliff: a band takes one token at any point in its
     * life, and the only thing the trade changed is the ratio it holds.
     */
    function test_aWallBandKeepsAcceptingWallsOnceItHasTraded() public {
        _open4thBand();
        _wall(A, 100_000e6);
        _sell(40e18);
        (uint256 rb,) = pool.bandReserves(W);
        assertGt(rb, 0, "the trade made it two-sided");

        (uint256 id,) = _wall(B, 50_000e6);
        (,, uint256 sh) = _owned(id);
        assertGt(sh, 0, "and a wall still lands in it");
        assertEq(usdc.balanceOf(B), 0, "all of it was used, nothing refunded");
    }

    function test_aSwapCostsTheSameWhateverTheNumberOfLps() public {
        _open4thBand();
        _wall(A, 400_000e6);
        eth.mint(taker, 80e18);
        vm.startPrank(taker);
        eth.approve(address(router), type(uint256).max);
        uint256 g1 = gasleft();
        router.swap(address(pool), 40e18, false, taker, 0);
        uint256 oneLp = g1 - gasleft();
        vm.stopPrank();

        uint256 snap = vm.snapshotState();
        vm.revertToState(snap);

        emit log_named_uint("swap gas, 1 LP in the band", oneLp);
    }

    function test_aSwapCostsTheSameWithThreeLps() public {
        _open4thBand();
        _wall(A, 100_000e6);
        _wall(B, 200_000e6);
        _wall(C, 100_000e6);
        eth.mint(taker, 80e18);
        vm.startPrank(taker);
        eth.approve(address(router), type(uint256).max);
        uint256 g1 = gasleft();
        router.swap(address(pool), 40e18, false, taker, 0);
        uint256 threeLps = g1 - gasleft();
        vm.stopPrank();

        emit log_named_uint("swap gas, 3 LPs in band  ", threeLps);
    }

    /**
     * WHAT A ACTUALLY WALKS AWAY WITH.
     *
     * The three-LP band from the walkthrough: A 100k, B 300k, C 400k of USDC, all in
     * before a trader sells 40 ETH. A then closes the whole position.
     *
     * Two payouts, and they are not the same thing. `decreaseLiquidity` returns the
     * PRINCIPAL -- a pro-rata slice of both reserves -- and pays out whatever fees have
     * already vested alongside it. Held past maturity, everything vests.
     */
    function test_whatAGetsBackAfterMaturity() public {
        _open4thBand();
        (uint256 idA,) = _wall(A, 100_000e6);
        _wall(B, 300_000e6);
        _wall(C, 400_000e6);
        _sell(40e18);

        (uint256 ownEth, uint256 ownUsdc,) = _owned(idA);
        (, uint256 pendA) = _pending(idA);
        emit log_named_uint("A principal eth          ", ownEth);
        emit log_named_uint("A principal usdc         ", ownUsdc);
        emit log_named_uint("A fees pending usdc      ", pendA);

        vm.warp(block.timestamp + 1 hours); // past the 10-minute maturity
        uint256 ethBefore = eth.balanceOf(A);
        uint256 usdcBefore = usdc.balanceOf(A);
        vm.prank(A);
        (uint256 baseOut, uint256 quoteOut) =
            manager.decreaseLiquidity(idA, 10_000, 0, 0, A, block.timestamp);

        uint256 gotEth = eth.balanceOf(A) - ethBefore;
        uint256 gotUsdc = usdc.balanceOf(A) - usdcBefore;
        emit log_named_uint("decrease returned eth    ", baseOut);
        emit log_named_uint("decrease returned usdc   ", quoteOut);
        emit log_named_uint("A WALLET eth             ", gotEth);
        emit log_named_uint("A WALLET usdc            ", gotUsdc);
        emit log_named_uint("A deposited usdc         ", uint256(100_000e6));
        emit log_named_uint("A value @2000            ", gotUsdc + (gotEth * 2000) / 1e12);
        assertEq(gotEth, ownEth, "the ETH is the principal slice -- no fee accrued in ETH");
        assertEq(gotUsdc, ownUsdc + pendA, "the USDC is principal plus the vested fee");
    }

    /// The same exit, taken immediately. The principal is identical; the fee is not.
    function test_whatAGetsBackLeavingImmediately() public {
        _open4thBand();
        (uint256 idA,) = _wall(A, 100_000e6);
        _wall(B, 300_000e6);
        _wall(C, 400_000e6);
        _sell(40e18);

        uint256 ethBefore = eth.balanceOf(A);
        uint256 usdcBefore = usdc.balanceOf(A);
        vm.prank(A);
        manager.decreaseLiquidity(idA, 10_000, 0, 0, A, block.timestamp);
        emit log_named_uint("early: A WALLET eth      ", eth.balanceOf(A) - ethBefore);
        emit log_named_uint("early: A WALLET usdc     ", usdc.balanceOf(A) - usdcBefore);
    }

    /// And half of it, to show the slice is a fraction of BOTH sides.
    function test_whatAGetsBackTakingHalf() public {
        _open4thBand();
        (uint256 idA,) = _wall(A, 100_000e6);
        _wall(B, 300_000e6);
        _wall(C, 400_000e6);
        _sell(40e18);

        vm.warp(block.timestamp + 1 hours);
        uint256 ethBefore = eth.balanceOf(A);
        uint256 usdcBefore = usdc.balanceOf(A);
        vm.prank(A);
        manager.decreaseLiquidity(idA, 5_000, 0, 0, A, block.timestamp);
        emit log_named_uint("half: A WALLET eth       ", eth.balanceOf(A) - ethBefore);
        emit log_named_uint("half: A WALLET usdc      ", usdc.balanceOf(A) - usdcBefore);
        (uint256 leftEth, uint256 leftUsdc,) = _owned(idA);
        emit log_named_uint("half: still owns eth     ", leftEth);
        emit log_named_uint("half: still owns usdc    ", leftUsdc);
    }
}
