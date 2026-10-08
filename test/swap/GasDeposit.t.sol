// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {BigTok, NoFeeEngine} from "./BandDepositCeiling.t.sol";

/// Prices at 2.0 so the conversion is not the identity the fee suites rely on.
contract GasDepositBook {
    /// The listing price the pool anchors to until the TWAP can answer.
    function lmp() external pure returns (uint256) { return 2e8; }

    function twap(uint32) external pure returns (uint256, uint32) { return (2e8, 300); }
    function convert(uint256 p, uint256 amount, bool isBid) external pure returns (uint256) {
        return isBid ? (amount * p) / 1e8 : (amount * 1e8) / p;
    }
}

/**
 * What a deposit costs, so the position layout is priced rather than argued.
 *
 * Measured on 2026-08-22 in v1, before and after dropping per-position ranges:
 *
 *   first deposit    300,338 -> 140,770   (-53%)
 *   repeat deposit   108,222 ->  59,643   (-45%)
 *   43rd deposit     212,235 ->  59,590   (-72%, and now flat)
 *   exit              13,824 ->  10,200   (-26%)
 *
 * v2 keys positions by token id and keeps one packed slot per (token, band), so a
 * deposit is either a NEW token entering the band or a TOP-UP of a slot that already
 * exists. Both are measured; neither may depend on what else is in the pool.
 */
contract GasDepositTest is Test {
    address pm = address(0xBEEF);
    address creator = address(0xC0FFEE);

    function _pool() internal returns (BandPool p, BigTok baseTok, BigTok quoteTok) {
        baseTok = new BigTok();
        quoteTok = new BigTok();
        p = new BandPool();
        uint32[] memory t = new uint32[](3);
        uint32[] memory fm = new uint32[](3);
        for (uint256 _f = 0; _f < 3; _f++) fm[_f] = 100000000; // 1x, unless a test says otherwise
        // 0.1 / 0.3 / 0.5% under the stub's 10% limit.
        t[0] = 1000000; t[1] = 3000000; t[2] = 5000000;
        p.initialize(BandPool.InitParams({
            id: 1, base: address(baseTok), quote: address(quoteTok),
            orderbook: address(new GasDepositBook()), engine: address(new NoFeeEngine()),
            positionManager: pm, creator: creator, maturity: 600, spreadFracs: t,
            feeMultipliers: fm
        }));
        p.syncLimit();
        baseTok.mint(pm, 1_000_000e18);
        vm.prank(pm);
        baseTok.approve(address(p), type(uint256).max);
        vm.warp(1_000_000);
    }

    /// Base-only into band 0, as the manager would call it.
    function _add(BandPool p, uint256 id) internal returns (uint256 gasUsed) {
        uint8[] memory b = new uint8[](1);
        uint256[] memory ba = new uint256[](1);
        uint256[] memory qa = new uint256[](1);
        ba[0] = 1_000e18;
        vm.prank(pm);
        uint256 g = gasleft();
        p.increase(id, b, ba, qa);
        gasUsed = g - gasleft();
    }

    function test_firstDepositIntoAnEmptyBand() public {
        (BandPool p,,) = _pool();
        console2.log("first deposit        ", _add(p, 1));
    }

    function test_aNewPositionIntoAnOccupiedBand() public {
        (BandPool p,,) = _pool();
        _add(p, 1);
        console2.log("new position         ", _add(p, 2));
    }

    function test_aTopUpOfAnExistingSlot() public {
        (BandPool p,,) = _pool();
        _add(p, 1);
        vm.warp(block.timestamp + 60); // so the clock blend does real work
        console2.log("top-up               ", _add(p, 1));
    }

    /**
     * There is no list to walk, so a deposit costs the same whatever else is in the
     * pool. The 2nd and the 43rd new position into one band must cost the same.
     */
    function test_depositCostDoesNotDependOnWhatElseIsInThePool() public {
        (BandPool p,,) = _pool();
        _add(p, 1);
        uint256 early = _add(p, 2);
        for (uint256 i = 3; i < 43; i++) _add(p, i);
        uint256 late = _add(p, 43);

        console2.log("2nd deposit          ", early);
        console2.log("43rd deposit         ", late);
        assertApproxEqAbs(late, early, 100, "flat in pool contents");
    }

    /// Top-ups are flat in the slot's history as well: the 40th costs what the 2nd did.
    function test_topUpCostDoesNotDependOnHowOftenTheSlotWasToppedUp() public {
        (BandPool p,,) = _pool();
        _add(p, 1);
        vm.warp(block.timestamp + 1);
        uint256 early = _add(p, 1);
        for (uint256 i = 0; i < 38; i++) {
            vm.warp(block.timestamp + 1);
            _add(p, 1);
        }
        vm.warp(block.timestamp + 1);
        uint256 late = _add(p, 1);
        console2.log("2nd top-up           ", early);
        console2.log("40th top-up          ", late);
        assertApproxEqAbs(late, early, 100, "flat in slot history");
    }

    function test_exitCost() public {
        (BandPool p,,) = _pool();
        _add(p, 1);
        vm.prank(pm);
        uint256 g = gasleft();
        p.decrease(1, 10_000, pm);
        console2.log("exit                 ", g - gasleft());
    }
}
