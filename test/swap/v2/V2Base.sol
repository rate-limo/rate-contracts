// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {BandBaseSetup} from "../BandBaseSetup.sol";
import {IBandPool} from "../../../src/swap/interfaces/IBandPool.sol";
import {IBandPositionManager} from "../../../src/swap/interfaces/IBandPositionManager.sol";

/**
 * The v2 manager suites: the real stack from `BandBaseSetup`, plus the array plumbing
 * one-token-many-bands calls need.
 *
 * `alice` and `bob` are LPs; `trader1` takes the other side. The engine's pool fee
 * share is set to half, because the real engine ships it at ZERO and every fee,
 * vesting and forfeit assertion would otherwise hold against a pool that never earns.
 */
abstract contract V2Base is BandBaseSetup {
    address internal alice;
    address internal bob;
    address internal stranger = address(0xBAD);

    function setUp() public virtual override {
        super.setUp();
        matchingEngine.setPoolFeeShare(50000000);
        alice = lp1;
        bob = users[1];
        _approveManager(alice);
        _approveManager(bob);
        vm.warp(1_000_000);
    }

    function _approveManager(address who) internal {
        vm.startPrank(who);
        token1.approve(address(positionManager), type(uint256).max);
        token2.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ array builders

    function _b(uint8 a) internal pure returns (uint8[] memory r) {
        r = new uint8[](1);
        r[0] = a;
    }

    function _b(uint8 a, uint8 c) internal pure returns (uint8[] memory r) {
        r = new uint8[](2);
        r[0] = a;
        r[1] = c;
    }

    function _b(uint8 a, uint8 c, uint8 d) internal pure returns (uint8[] memory r) {
        r = new uint8[](3);
        r[0] = a;
        r[1] = c;
        r[2] = d;
    }

    /// `n` copies of `v`.
    function _fill(uint256 n, uint256 v) internal pure returns (uint256[] memory r) {
        r = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            r[i] = v;
        }
    }

    function _u(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _u(uint256 a, uint256 c) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = c;
    }

    function _u(uint256 a, uint256 c, uint256 d) internal pure returns (uint256[] memory r) {
        r = new uint256[](3);
        r[0] = a;
        r[1] = c;
        r[2] = d;
    }

    function _mins(uint256 n) internal pure returns (uint128[] memory) {
        return new uint128[](n);
    }

    function _bps(uint16 a, uint16 c) internal pure returns (uint16[] memory r) {
        r = new uint16[](2);
        r[0] = a;
        r[1] = c;
    }

    function _bps(uint16 a, uint16 c, uint16 d) internal pure returns (uint16[] memory r) {
        r = new uint16[](3);
        r[0] = a;
        r[1] = c;
        r[2] = d;
    }

    // ------------------------------------------------------------ manager calls

    function _params(uint8[] memory bands, uint256[] memory baseAmts, uint256[] memory quoteAmts, address to)
        internal
        view
        returns (IBandPositionManager.MintParams memory)
    {
        return IBandPositionManager.MintParams({
            pool: address(pool),
            bands: bands,
            baseAmounts: baseAmts,
            quoteAmounts: quoteAmts,
            minShares: _mins(bands.length),
            recipient: to,
            deadline: block.timestamp
        });
    }

    function _mint(address who, uint8[] memory bands, uint256[] memory baseAmts, uint256[] memory quoteAmts)
        internal
        returns (uint256 id, uint128[] memory shares)
    {
        vm.prank(who);
        (id, shares) = positionManager.mint(_params(bands, baseAmts, quoteAmts, who));
    }

    /// Base-only, `perBand` into each of `bands`.
    function _mintBase(address who, uint8[] memory bands, uint256 perBand) internal returns (uint256 id) {
        (id,) = _mint(who, bands, _fill(bands.length, perBand), _fill(bands.length, 0));
    }

    function _topUp(address who, uint256 id, uint8[] memory bands, uint256[] memory baseAmts, uint256[] memory quoteAmts)
        internal
        returns (uint128[] memory shares)
    {
        vm.prank(who);
        shares = positionManager.increaseLiquidity(id, bands, baseAmts, quoteAmts, _mins(bands.length), block.timestamp);
    }

    function _decreaseAll(address who, uint256 id, uint16 bps) internal returns (uint256 b, uint256 q) {
        vm.prank(who);
        (b, q) = positionManager.decreaseLiquidity(id, bps, 0, 0, who, block.timestamp);
    }

    // ------------------------------------------------------------------- views

    function _held(uint256 id) internal view returns (IBandPool.BandView[] memory held) {
        (held,,) = pool.positionView(id);
    }

    /// The band's slot for `id`; zeroed when the token does not hold it.
    function _slot(uint256 id, uint8 band) internal view returns (IBandPool.BandView memory v) {
        IBandPool.BandView[] memory held = _held(id);
        for (uint256 i = 0; i < held.length; i++) {
            if (held[i].band == band) return held[i];
        }
    }

    function _sharesIn(uint256 id, uint8 band) internal view returns (uint128) {
        return _slot(id, band).shares;
    }

    function _owed(uint256 id) internal view returns (uint256 b, uint256 q) {
        (, b, q) = pool.positionView(id);
    }

    /// What `collect` would pay now: owed plus the vested part of every band's pending.
    function _claimable(uint256 id) internal view returns (uint256 cb, uint256 cq) {
        (IBandPool.BandView[] memory held, uint256 ob, uint256 oq) = pool.positionView(id);
        cb = ob;
        cq = oq;
        for (uint256 i = 0; i < held.length; i++) {
            cb += held[i].vestedBase;
            cq += held[i].vestedQuote;
        }
    }

    /// Everything accrued, vested or not.
    function _accrued(uint256 id) internal view returns (uint256 ab, uint256 aq) {
        (IBandPool.BandView[] memory held, uint256 ob, uint256 oq) = pool.positionView(id);
        ab = ob;
        aq = oq;
        for (uint256 i = 0; i < held.length; i++) {
            ab += held[i].pendingBase;
            aq += held[i].pendingQuote;
        }
    }

    /// A band slot's value in quote at the pool's anchor, the way the manager's solver values it.
    function _valueOf(IBandPool.BandView memory v) internal view returns (uint256) {
        uint256 baseValue = v.baseOwned == 0 ? 0 : book.convert(pool.anchorPrice(), v.baseOwned, true);
        return v.quoteOwned + baseValue;
    }

    function _positionValue(uint256 id) internal view returns (uint256 total) {
        IBandPool.BandView[] memory held = _held(id);
        for (uint256 i = 0; i < held.length; i++) {
            total += _valueOf(held[i]);
        }
    }

    /// How many logs with topic0 `sig` the POOL emitted, and the last of them.
    function _poolLog(Vm.Log[] memory logs, bytes32 sig) internal view returns (uint256 count, Vm.Log memory last) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(pool) || logs[i].topics.length == 0 || logs[i].topics[0] != sig) continue;
            count++;
            last = logs[i];
        }
    }
}
