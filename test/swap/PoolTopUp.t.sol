// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IBandPool} from "../../src/swap/interfaces/IBandPool.sol";
import {PositionsHarness} from "./PoolPositions.t.sol";
import {BandPoolBase} from "./BandPoolBase.sol";

/**
 * Once a slot is fully vested every later claim on it is 100%. If fresh liquidity
 * could be ADDED to it at that age, an attacker would keep one mature position as a
 * vehicle: top it up before a large swap, withdraw at full vest right after. The JIT
 * defence would return through a side door, and the code doing it would look like an
 * ordinary convenience feature.
 *
 * v1 closed the door by minting a fresh position for every deposit. v2 tops up the
 * SAME token and blends the slot's clock share-weighted:
 * `createdAt = (c×S + t×dS) / (S + dS)`. These pin the formula, and hold it to v1's
 * promise: fresh capital must not vest faster than it would have in a position of
 * its own.
 */
contract PoolTopUpTest is BandPoolBase {
    uint32 constant DENOM = 100000000;

    function test_aTopUpReusesTheTokenAndBlendsItsClock() public {
        uint256 id = _addTo(0, 1_000e18);
        uint256 c = block.timestamp;
        vm.warp(c + 30 days);
        _topUp(id, 0, 3_000e18);

        IBandPool.BandView memory v = _view(id);
        assertEq(v.shares, 4_000e18, "the same token holds both deposits");
        // Share-weighted over VESTING: the old capital's age is capped at the pool's
        // maturity (600s) first -- 30 days of it counts as exactly one maturity.
        uint256 capped = block.timestamp - 600;
        assertEq(v.createdAt, (capped * 1_000e18 + block.timestamp * 3_000e18) / 4_000e18, "share-weighted");
        assertEq(v.vestedNum, DENOM / 4, "a quarter of the capital was fully vested, so a quarter vests");
        (IBandPool.BandView[] memory held,,) = pool.positionView(id);
        assertEq(held.length, 1, "no second slot, no second position");
    }

    function test_aTopUpIntoAnotherBandHasItsOwnClock() public {
        uint256 id = _addTo(0, 1_000e18);
        uint256 c = block.timestamp;
        vm.warp(c + 30 days);
        _topUp(id, 1, 1_000e18);
        (IBandPool.BandView[] memory held,,) = pool.positionView(id);
        assertEq(held[0].createdAt, c, "the old band's age is untouched");
        assertEq(held[1].createdAt, block.timestamp, "new capital in a new band ages from now");
    }

    /**
     * v1's promise, stated for the blended clock: right after a top-up the slot may be
     * vested no further than the OLD capital's share of it. A 1,000-share slot held for
     * 30 days and topped up with 1,000,000 fresh shares is ~0.1% old capital.
     *
     * This failed against the first v2 draft: `_blendCreatedAt` averaged raw ages without
     * capping the old one at maturity, so 30 days of age on 0.1% of the shares was
     * ~2,589s -- past the 600s maturity -- and the slot was fully vested the instant the
     * fresh capital landed. Ages are now capped at maturity before the blend.
     */
    function test_theMaturePositionCannotBeUsedAsAVehicle() public {
        uint256 id = _addTo(0, 1_000);
        vm.warp(block.timestamp + 30 days);
        _topUp(id, 0, 1_000_000);

        IBandPool.BandView memory v = _view(id);
        uint256 oldWeight = (uint256(1_000) * DENOM) / 1_001_000;
        // One second of blending rounding, on top of the old capital's weight.
        assertLe(v.vestedNum, oldWeight + DENOM / 600, "fresh capital borrowed the old capital's vesting");
    }

    /**
     * The same hole end to end: a small aged position, a JIT top-up just before a swap,
     * a full exit right after. The JIT fees should forfeit almost entirely to the band's
     * honest LP. Nothing forfeited under the first v2 draft; see above.
     */
    function test_aJitTopUpOfAnAgedSlotForfeitsItsFees() public {
        uint256 honest = _addTo(0, 1_000e18);
        uint256 vehicle = _addTo(0, 1e18);
        vm.warp(block.timestamp + 30 days);

        _topUp(vehicle, 0, 1_000e18); // JIT, right before the flow
        _swap(100e18);
        (uint256 jitFees,) = _accrued(vehicle);
        uint256 honestBefore = _rawOwedBase(honest);

        vm.recordLogs();
        _decrease(vehicle, 10_000, address(this));
        uint256 forfeited = _forfeitBaseFromLogs();

        assertGt(jitFees, 0);
        // ~0.1% of the slot is aged capital; allow it 1% of the fees and no more.
        assertGe(forfeited, (jitFees * 99) / 100, "the JIT capital walked off with fully vested fees");
        assertGe(_rawOwedBase(honest) - honestBefore, (jitFees * 99) / 100);
    }

    function _forfeitBaseFromLogs() internal returns (uint256 forfeitBase) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == IBandPool.DecreaseLiquidity.selector) {
                (,,,, uint256 fb,,) =
                    abi.decode(logs[i].data, (uint8[], uint128[], uint256, uint256, uint256, uint256, bool));
                forfeitBase += fb;
            }
        }
    }
}

/// The formula itself, isolated from the pool.
contract PoolTopUpBlendTest is Test {
    PositionsHarness h;

    function setUp() public {
        h = new PositionsHarness();
    }

    function test_blendIsExactlyTheShareWeightedMean() public view {
        uint256 c = 1_000_000;
        uint256 t = c + 30 days;
        assertEq(h.blend(uint64(c), 1_000, t, 1_000_000), (c * 1_000 + t * 1_000_000) / 1_001_000);
    }

    function test_aTopUpOfEqualSizeHalvesTheAge() public view {
        assertEq(h.blend(1_000_000, 500, 1_000_600, 500), 1_000_300);
    }
}
