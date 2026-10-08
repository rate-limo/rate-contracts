// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoolPositions} from "../../src/swap/PoolPositions.sol";
import {IBandPool} from "../../src/swap/interfaces/IBandPool.sol";
import {BandPoolBase} from "./BandPoolBase.sol";

/// Exposes the v2 position internals one at a time, so each can be pinned on its own.
contract PositionsHarness is PoolPositions {
    uint32 internal _limit = 10000000;

    function init(address creator_, uint64 maturity_, uint32[] calldata t, uint32[] calldata m) external {
        _initBands(creator_, maturity_, t, m);
    }

    function pokeGrowth(uint8 i, uint256 gBase, uint256 gQuote) external {
        _bands[i].feeGrowthBase = gBase;
        _bands[i].feeGrowthQuote = gQuote;
    }

    function setSlot(uint256 id, uint8 band, uint128 shares, uint64 createdAt) external {
        _slot[id][band] = Slot({shares: shares, createdAt: createdAt});
    }

    function setPending(uint256 id, uint8 band, uint128 b, uint128 q) external {
        _pending[id][band] = Amounts({base: b, quote: q});
    }

    function accrue(uint256 id, uint8 band) external {
        _accrue(id, band);
    }

    function lockVested(uint256 id, uint8 band) external {
        _lockVested(id, band);
    }

    function blend(uint64 createdAt, uint256 shares, uint256 addedAt, uint256 added) external view returns (uint64) {
        return _blendCreatedAt(createdAt, shares, addedAt, added);
    }

    function tolerance(uint32 frac, uint32 limit) external pure returns (uint32) {
        return _tolerance(frac, limit);
    }

    function mulDivUp(uint256 a, uint256 p, uint256 w) external pure returns (uint256) {
        return _mulDivUp(a, p, w);
    }

    function ckpt(uint256 id, uint8 band) external view returns (uint256, uint256) {
        Checkpoint storage c = _ckpt[id][band];
        return (c.base, c.quote);
    }

    function pending(uint256 id, uint8 band) external view returns (uint128, uint128) {
        Amounts storage p = _pending[id][band];
        return (p.base, p.quote);
    }

    function owed(uint256 id) external view returns (uint128, uint128) {
        Amounts storage o = _owed[id];
        return (o.base, o.quote);
    }

    function _storedLimits() internal view override returns (uint32, uint32) {
        return (_limit, _limit);
    }
}

contract PoolPositionsTest is Test {
    PositionsHarness h;
    address creator = address(0xC0FFEE);
    uint256 constant Q128 = 1 << 128;
    uint32 constant DENOM = 100000000;

    function setUp() public {
        h = new PositionsHarness();
        uint32[] memory t = new uint32[](2);
        uint32[] memory fm = new uint32[](2);
        for (uint256 _f = 0; _f < 2; _f++) fm[_f] = 100000000; // 1x, unless a test says otherwise
        t[0] = 1000000;
        t[1] = 3000000;
        h.init(creator, 600, t, fm);
        vm.warp(1_000_000);
    }

    /// A slot with no shares takes the band's growth as its baseline: nothing that was
    /// earned before it existed becomes pending.
    function test_accrue_snapshotsTheBandGrowthForAnEmptySlot() public {
        h.pokeGrowth(0, 12345, 678);
        h.accrue(7, 0);
        (uint256 cb, uint256 cq) = h.ckpt(7, 0);
        assertEq(cb, 12345);
        assertEq(cq, 678);
        (uint128 pb, uint128 pq) = h.pending(7, 0);
        assertEq(uint256(pb) + pq, 0, "no pre-existing growth is credited");
    }

    function test_accrue_creditsGrowthTimesSharesSinceTheCheckpoint() public {
        h.setSlot(1, 0, 1_000, uint64(block.timestamp));
        h.accrue(1, 0); // checkpoint at 0
        h.pokeGrowth(0, 5 * Q128, 2 * Q128);
        h.accrue(1, 0);
        (uint128 pb, uint128 pq) = h.pending(1, 0);
        assertEq(pb, 5_000);
        assertEq(pq, 2_000);
        (uint256 cb,) = h.ckpt(1, 0);
        assertEq(cb, 5 * Q128, "the checkpoint moved up to now");

        h.accrue(1, 0);
        (pb,) = h.pending(1, 0);
        assertEq(pb, 5_000, "accruing twice credits once");
    }

    /**
     * Why `_accrue` must run BEFORE the shares change. Two slots see identical growth;
     * one is accrued then grown, the other grown then accrued. The second measures the
     * old growth against the new share count and is over-credited.
     */
    function test_accrue_mustSnapshotBeforeSharesChange() public {
        h.setSlot(1, 0, 1_000, 0);
        h.setSlot(2, 0, 1_000, 0);
        h.accrue(1, 0);
        h.accrue(2, 0);
        h.pokeGrowth(0, 3 * Q128, 0);

        h.accrue(1, 0);
        h.setSlot(1, 0, 4_000, 0);
        h.setSlot(2, 0, 4_000, 0);
        h.accrue(2, 0);

        (uint128 right,) = h.pending(1, 0);
        (uint128 wrong,) = h.pending(2, 0);
        assertEq(right, 3_000, "old growth on the old shares");
        assertEq(wrong, 12_000, "the wrong order credits old growth to new shares");
    }

    function test_lockVested_atAgeZeroMovesNothing() public {
        h.setSlot(1, 0, 1_000, uint64(block.timestamp));
        h.setPending(1, 0, 1_000, 500);
        h.lockVested(1, 0);
        (uint128 ob, uint128 oq) = h.owed(1);
        assertEq(uint256(ob) + oq, 0);
        (uint128 pb, uint128 pq) = h.pending(1, 0);
        assertEq(pb, 1_000);
        assertEq(pq, 500);
    }

    function test_lockVested_halfWayMovesHalfRoundedDown() public {
        h.setSlot(1, 0, 1_000, uint64(block.timestamp - 300));
        h.setPending(1, 0, 1_001, 3);
        h.lockVested(1, 0);
        (uint128 ob, uint128 oq) = h.owed(1);
        (uint128 pb, uint128 pq) = h.pending(1, 0);
        assertEq(ob, 500, "1001 / 2 floored");
        assertEq(oq, 1);
        assertEq(pb, 501, "the dust stays on the unvested side");
        assertEq(pq, 2);
    }

    function test_lockVested_atMaturityMovesEverythingAndSumsAcrossBands() public {
        h.setSlot(1, 0, 1_000, uint64(block.timestamp - 600));
        h.setSlot(1, 1, 1_000, uint64(block.timestamp - 10_000));
        h.setPending(1, 0, 700, 0);
        h.setPending(1, 1, 300, 40);
        h.lockVested(1, 0);
        h.lockVested(1, 1);
        (uint128 ob, uint128 oq) = h.owed(1);
        assertEq(ob, 1_000, "owed is per token, summed over the bands that earned it");
        assertEq(oq, 40);
        (uint128 pb,) = h.pending(1, 0);
        assertEq(pb, 0);
    }

    function test_blend_anEmptySlotTakesTheDepositTime() public view {
        assertEq(h.blend(123, 0, 1_000_000, 50), 1_000_000);
    }

    /// Inside the maturity window (setUp is at t = 1,000,000, maturity 600) the blend is
    /// the plain share-weighted mean: (c*S + t*dS) / (S + dS).
    function test_blend_isShareWeighted() public view {
        assertEq(h.blend(999_500, 1_000, 999_900, 1_000), 999_700, "equal shares meet in the middle");
        assertEq(h.blend(999_500, 3_000, 999_900, 1_000), 999_600);
        assertEq(h.blend(999_500, 1, 999_900, 2), 999_766, "rounded down");
    }

    /// Past the window each side counts as exactly one maturity old: the ramp saturates
    /// there, so a month of age is worth no more vesting than ten minutes of it.
    function test_blend_capsEachAgeAtMaturity() public view {
        assertEq(h.blend(0, 1_000, 1_000_000, 1_000), 999_700, "a month-old slot counts as 600s old");
        // 0.1% of the capital fully vested -> 0.1% of a maturity of age, i.e. 0.6s.
        assertEq(h.blend(0, 1_000, 1_000_000, 999_000), 999_999, "old capital lends only its share of vesting");
    }

    function test_blend_aLargeTopUpLandsNearNow() public view {
        uint64 c = h.blend(0, 1_000, 1_000_000, 1_000_000_000);
        assertGe(c, 999_000);
        assertLe(c, 1_000_000);
    }

    function test_tolerance_isTheFractionOfTheLimitRoundedDown() public view {
        assertEq(h.tolerance(1000000, 10000000), 100000, "1% of 10% is 0.1%");
        assertEq(h.tolerance(20000000, 4), 0, "too small to express: idle");
        assertEq(h.tolerance(DENOM, type(uint32).max), type(uint32).max, "never above the limit");
    }

    function test_mulDivUp_roundsTowardTheForfeit() public view {
        assertEq(h.mulDivUp(10, 1, 3), 4);
        assertEq(h.mulDivUp(9, 1, 3), 3);
        assertEq(h.mulDivUp(1, 1, 1_000), 1, "a tiny removal still forfeits");
    }
}

/**
 * The same ordering claims against the real pool, where the order is the pool's and
 * not a harness's, and `_mask` membership as the pool maintains it.
 */
contract PoolPositionsPoolTest is BandPoolBase {
    function _quoteFor(uint256 amount) internal {
        quoteTok.mint(pm, amount);
        vm.prank(pm);
        quoteTok.approve(address(pool), type(uint256).max);
    }

    function test_increaseSetsTheBandBit() public {
        uint256 id = _addTo(1, 1_000e18);
        assertEq(pool.bandMaskOf(id), 2);
        _topUp(id, 0, 1_000e18);
        assertEq(pool.bandMaskOf(id), 3);
        (IBandPool.BandView[] memory held,,) = pool.positionView(id);
        assertEq(held.length, 2);
        assertEq(held[0].band, 0);
        assertEq(held[1].band, 1);
    }

    function test_emptyingABandClearsOnlyItsBit() public {
        uint256 id = _addTo(0, 1_000e18);
        _topUp(id, 1, 1_000e18);
        vm.prank(pm);
        pool.decreaseBand(id, 0, type(uint128).max, pm);
        assertEq(pool.bandMaskOf(id), 2);
    }

    function test_aPartialWithdrawalKeepsTheBit() public {
        uint256 id = _addTo(0, 1_000e18);
        vm.prank(pm);
        pool.decreaseBand(id, 0, 1, pm);
        assertEq(pool.bandMaskOf(id), 1);
    }

    function test_aMoveOutOfABandMovesTheBit() public {
        uint256 id = _addTo(0, 1_000e18);
        vm.prank(pm);
        pool.move(id, 0, 1, type(uint128).max, pm);
        assertEq(pool.bandMaskOf(id), 2, "membership follows the capital");
    }

    function test_aDepositIntoAClosedBandReverts() public {
        vm.prank(creator);
        pool.setBandOpen(0, false);
        baseTok.mint(pm, 1_000e18);
        vm.prank(pm);
        baseTok.approve(address(pool), type(uint256).max);
        uint8[] memory b = new uint8[](1);
        uint256[] memory ba = new uint256[](1);
        ba[0] = 1_000e18;
        vm.prank(pm);
        vm.expectRevert(abi.encodeWithSelector(PoolPositions.BandClosed.selector, uint8(0)));
        pool.increase(1, b, ba, new uint256[](1));
    }

    function test_aMoveIntoAClosedBandReverts() public {
        uint256 id = _addTo(0, 1_000e18);
        vm.prank(creator);
        pool.setBandOpen(1, false);
        vm.prank(pm);
        vm.expectRevert(abi.encodeWithSelector(PoolPositions.BandClosed.selector, uint8(1)));
        pool.move(id, 0, 1, type(uint128).max, pm);
    }

    /// Closing stops new liquidity only; the LPs already inside can still leave.
    function test_aClosedBandStillPaysOut() public {
        uint256 id = _addTo(0, 1_000e18);
        vm.prank(creator);
        pool.setBandOpen(0, false);
        vm.prank(pm);
        (uint256 baseOut,) = pool.decreaseBand(id, 0, type(uint128).max, pm);
        assertEq(baseOut, 1_000e18);
    }

    function test_aDepositDoesNotCreditGrowthEarnedBeforeIt() public {
        _addTo(0, 1_000e18);
        _swap(100e18);
        (uint256 br, uint256 qr) = pool.bandReserves(0);
        _quoteFor(qr);
        uint256 late = _nextId++;
        baseTok.mint(pm, br);
        vm.prank(pm);
        baseTok.approve(address(pool), type(uint256).max);
        _increase(pool, late, 0, br, qr);
        (uint256 ab, uint256 aq) = _accrued(late);
        assertEq(ab + aq, 0, "the checkpoint was taken at deposit");
    }

    /**
     * A top-up doubles the slot's shares. Were the fee accrued AFTER the shares
     * changed, the fees earned before it would be counted twice.
     */
    function test_aTopUpAccruesTheOldFeesOnTheOldShares() public {
        uint256 id = _addTo(0, 1_000e18);
        _swap(100e18);
        (uint256 before,) = _accrued(id);
        assertGt(before, 0);

        (uint256 br, uint256 qr) = pool.bandReserves(0);
        baseTok.mint(pm, br);
        _quoteFor(qr);
        _increase(pool, id, 0, br, qr); // doubles the shares

        (uint256 afterTopUp,) = _accrued(id);
        assertEq(afterTopUp, before, "the pre-top-up fee is measured once, on the old shares");
    }

    /// Vested fees are locked into owed before the clock blends, so the old capital's
    /// vesting progress is not diluted by the top-up.
    function test_aTopUpLocksTheVestedFeeBeforeBlending() public {
        uint256 id = _addTo(0, 1_000e18);
        _swap(100e18);
        vm.warp(block.timestamp + 600); // fully vested
        (uint256 vested,) = _claimable(id);

        (uint256 br, uint256 qr) = pool.bandReserves(0);
        baseTok.mint(pm, br * 1_000);
        _quoteFor(qr * 1_000);
        _increase(pool, id, 0, br * 1_000, qr * 1_000);

        (, uint256 owedBase,) = pool.positionView(id);
        assertEq(owedBase, vested, "every vested unit locked in before the fresh capital blended");
        (uint256 claimable,) = _claimable(id);
        assertEq(claimable, vested, "still payable in full after the top-up");
    }
}
