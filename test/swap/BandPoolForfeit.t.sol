// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandPoolBase} from "./BandPoolBase.sol";

/// Only a WITHDRAWAL forfeits in v2: collect pays the vested part and leaves the rest
/// vesting. A forfeit goes to the band's other shares, or to the protocol when none.
contract BandPoolForfeitTest is BandPoolBase {
    function test_forfeitGoesToTheOtherLpsNotBack() public {
        uint256 holder = _addTo(0, 1_000e18);
        uint256 jit = _addTo(0, 1_000e18);
        _swap(100e18);
        uint256 holderBefore = _rawOwedBase(holder);
        _decrease(jit, 10_000, address(this)); // age 0, forfeits everything
        assertGt(_rawOwedBase(holder), holderBefore, "the holder received the forfeit");
    }

    function test_theForfeiterCannotClaimItsOwnForfeit() public {
        _addTo(0, 1_000e18);
        uint256 jit = _addTo(0, 1_000e18);
        _swap(100e18);
        _decrease(jit, 10_000, address(this));
        vm.warp(block.timestamp + 601);
        assertEq(_owedBase(jit), 0, "a forfeit must not come back on a later claim");
    }

    function test_aDominantForfeiterDoesNotRecoverMostOfIt() public {
        // 99% of the band forfeiting: crediting over the band's total shares instead of
        // over the OTHER shares would hand it back ~99%.
        uint256 small = _addTo(0, 10e18);
        uint256 whale = _addTo(0, 990e18);
        _swap(100e18);
        uint256 smallBefore = _rawOwedBase(small);
        uint256 whaleRaw = _rawOwedBase(whale);
        _decrease(whale, 10_000, address(this));
        uint256 gained = _rawOwedBase(small) - smallBefore;
        assertApproxEqRel(gained, whaleRaw, 1e12, "the small LP receives the WHOLE forfeit");
        vm.warp(block.timestamp + 601);
        assertEq(_owedBase(whale), 0);
    }

    function test_soleLpForfeitLeavesThePoolRatherThanVanishing() public {
        uint256 only = _addTo(0, 1_000e18);
        _swap(100e18);
        uint256 before_ = pool.protocolFeesBase();
        _decrease(only, 10_000, address(this));
        assertGt(pool.protocolFeesBase(), before_, "nobody to credit, so it accrues to the protocol");
    }

    function test_partialWithdrawForfeitsProRata() public {
        _addTo(0, 1_000e18);
        uint256 jit = _addTo(0, 1_000e18);
        _swap(100e18);
        uint256 raw = _rawOwedBase(jit);
        _decrease(jit, 2_500, address(this)); // a quarter of the shares leave
        // Rounded UP on the forfeit, so what remains is at most three quarters.
        assertLe(_rawOwedBase(jit), raw - raw / 4, "a quarter of the unvested fee went with them");
        assertApproxEqRel(_rawOwedBase(jit), (raw * 3) / 4, 1e12);
    }

    function test_collectForfeitsNothing() public {
        uint256 holder = _addTo(0, 1_000e18);
        uint256 jit = _addTo(0, 1_000e18);
        _swap(100e18);
        uint256 jitRaw = _rawOwedBase(jit);
        uint256 holderRaw = _rawOwedBase(holder);
        _collect(jit, address(this)); // age 0: nothing vested, nothing lost
        assertEq(_rawOwedBase(jit), jitRaw, "the unvested fee is still there");
        assertEq(_rawOwedBase(holder), holderRaw, "and nobody else received any of it");
    }
}
