// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandPoolBase} from "./BandPoolBase.sol";

contract BandPoolCollectTest is BandPoolBase {
    function test_matureLpKeepsEverything() public {
        uint256 id = _addTo(0, 1_000e18);
        _swap(100e18);
        uint256 raw = _rawOwedBase(id);
        vm.warp(block.timestamp + 601);
        assertEq(_owedBase(id), raw);
    }

    function test_sameBlockClaimableIsNothing() public {
        uint256 id = _addTo(0, 1_000e18);
        _swap(100e18);
        assertEq(_owedBase(id), 0, "age zero vests nothing");
        assertGt(_rawOwedBase(id), 0, "but it did accrue");
    }

    function test_halfwayThroughTheRampKeepsHalf() public {
        uint256 id = _addTo(0, 1_000e18);
        _swap(100e18);
        uint256 raw = _rawOwedBase(id);
        vm.warp(block.timestamp + 300);
        assertApproxEqRel(_owedBase(id), raw / 2, 1e12);
    }

    function test_collectCannotBeClaimedTwice() public {
        uint256 id = _addTo(0, 1_000e18);
        _swap(100e18);
        vm.warp(block.timestamp + 601);
        _collect(id, address(this));
        assertEq(_owedBase(id), 0, "second claim pays nothing");
        (uint256 again,) = _collect(id, address(this));
        assertEq(again, 0);
    }

    function test_ageDoesNotResetOnCollect() public {
        uint256 id = _addTo(0, 1_000e18);
        _swap(100e18);
        vm.warp(block.timestamp + 601);
        _collect(id, address(this));
        assertEq(_view(id).createdAt, 1_000_000, "claiming is not re-minting");
    }

    function test_collectPaysTheRecipient() public {
        uint256 id = _addTo(0, 1_000e18);
        _swap(100e18);
        vm.warp(block.timestamp + 601);
        uint256 before_ = baseTok.balanceOf(address(this));
        (uint256 got,) = _collect(id, address(this));
        assertGt(got, 0);
        assertEq(baseTok.balanceOf(address(this)) - before_, got);
    }

    /// Collecting mid-ramp pays the vested part and the rest KEEPS vesting: after the
    /// ramp completes the two claims sum to the whole accrual.
    function test_anEarlyCollectLosesNothingOverTheRamp() public {
        uint256 id = _addTo(0, 1_000e18);
        _swap(100e18);
        uint256 raw = _rawOwedBase(id);
        vm.warp(block.timestamp + 300);
        (uint256 first,) = _collect(id, address(this));
        vm.warp(block.timestamp + 301);
        (uint256 second,) = _collect(id, address(this));
        assertApproxEqAbs(first + second, raw, 2, "the two claims are the whole accrual");
        assertGt(first, 0);
        assertGt(second, 0);
    }
}
