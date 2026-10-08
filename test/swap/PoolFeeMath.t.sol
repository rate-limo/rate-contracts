// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoolFeeMath} from "../../src/swap/libraries/PoolFeeMath.sol";

contract PoolFeeMathTest is Test {
    uint32 constant DENOM = 100000000;
    uint256 constant M = 600; // 10 minutes

    function test_vesting_isZeroAtMint() public pure {
        assertEq(PoolFeeMath.vestedNumerator(0, M, DENOM), 0);
    }

    function test_vesting_isFullAtMaturity() public pure {
        assertEq(PoolFeeMath.vestedNumerator(M, M, DENOM), DENOM);
    }

    function test_vesting_neverExceedsOne() public pure {
        assertEq(PoolFeeMath.vestedNumerator(M * 1000, M, DENOM), DENOM);
    }

    function test_vesting_isLinearBetween() public pure {
        assertEq(PoolFeeMath.vestedNumerator(M / 2, M, DENOM), DENOM / 2);
        assertEq(PoolFeeMath.vestedNumerator(M / 4, M, DENOM), DENOM / 4);
    }

    function test_vesting_tenSecondExitAgainstTenMinuteMaturity() public pure {
        assertEq(PoolFeeMath.vestedNumerator(10, M, DENOM), DENOM / 60);
    }

    function test_growthDelta_isZeroWhenNoLiquidity() public pure {
        assertEq(PoolFeeMath.growthDelta(1e18, 0), 0);
    }

    function test_growthDelta_thenRawEntitlement_roundTrips() public pure {
        uint256 liquidity = 1_000e18;
        uint256 fee = 7e18;
        uint256 growth = PoolFeeMath.growthDelta(fee, liquidity);
        uint256 raw = PoolFeeMath.rawEntitlement(liquidity, growth, 0);
        assertApproxEqAbs(raw, fee, 1);
    }

    function test_rawEntitlement_isProRata() public pure {
        uint256 total = 1_000e18;
        uint256 growth = PoolFeeMath.growthDelta(100e18, total);
        assertApproxEqAbs(PoolFeeMath.rawEntitlement(250e18, growth, 0), 25e18, 1);
        assertApproxEqAbs(PoolFeeMath.rawEntitlement(750e18, growth, 0), 75e18, 1);
    }

    function test_rawEntitlement_isZeroWhenGrowthHasNotMoved() public pure {
        assertEq(PoolFeeMath.rawEntitlement(1e18, 12345, 12345), 0);
    }

    function test_split_conservesTheWhole() public pure {
        (uint256 vested, uint256 forfeit) = PoolFeeMath.split(1000, DENOM / 4, DENOM);
        assertEq(vested, 250);
        assertEq(forfeit, 750);
        assertEq(vested + forfeit, 1000);
    }

    // vm.assume is a cheatcode call, so these cannot be `pure`.
    function testFuzz_split_neverCreatesOrDestroysValue(uint256 raw, uint32 num) public {
        vm.assume(num <= DENOM);
        (uint256 vested, uint256 forfeit) = PoolFeeMath.split(raw, num, DENOM);
        assertEq(vested + forfeit, raw);
        assertLe(vested, raw);
    }

    function testFuzz_vesting_isMonotonic(uint32 a, uint32 b) public {
        vm.assume(a <= b);
        assertLe(
            PoolFeeMath.vestedNumerator(a, M, DENOM),
            PoolFeeMath.vestedNumerator(b, M, DENOM)
        );
    }
}
