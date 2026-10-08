// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandPoolBase} from "./BandPoolBase.sol";

contract BandPoolSwapTest is BandPoolBase {
    function test_swapCreditsBandGrowthNotPositions() public {
        uint256 id = _addTo(0, 1_000e18);
        _swap(100e18);
        (,, uint256 growth,,) = pool.bands(0);
        assertGt(growth, 0, "band accumulator moved");
        assertEq(_view(id).createdAt, 1_000_000, "position untouched by the swap");
    }

    function test_twoEqualLpsInOneBandSplitFiftyFifty() public {
        uint256 a = _addTo(0, 1_000e18);
        uint256 b = _addTo(0, 1_000e18);
        _swap(100e18);
        assertApproxEqRel(_rawOwedBase(a), _rawOwedBase(b), 1e12);
        assertGt(_rawOwedBase(a), 0);
    }

    function test_ageDoesNotChangeTheSplit() public {
        uint256 old_ = _addTo(0, 1_000e18);
        vm.warp(block.timestamp + 30 days);
        uint256 fresh = _addTo(0, 1_000e18);
        _swap(100e18);
        // the whole difference from the old model: at swap time, age is irrelevant
        assertApproxEqRel(_rawOwedBase(old_), _rawOwedBase(fresh), 1e12);
    }

    function test_emptyBandDoesNotHaltTheSwap() public {
        _addTo(1, 1_000e18); // band 0 left empty
        _swap(100e18);
        (,, uint256 g1,,) = pool.bands(1);
        assertGt(g1, 0);
    }

    function test_tighterBandFillsFirst() public {
        uint256 tight = _addTo(0, 1_000e18);
        uint256 wide = _addTo(1, 1_000e18);
        _swap(10e18);
        assertGt(_rawOwedBase(tight), 0);
        assertEq(_rawOwedBase(wide), 0, "wider band untouched by a small swap");
    }

    function test_proRataIsBySize() public {
        uint256 small = _addTo(0, 250e18);
        uint256 big = _addTo(0, 750e18);
        _swap(100e18);
        assertApproxEqRel(_rawOwedBase(big), _rawOwedBase(small) * 3, 1e12);
    }
}
