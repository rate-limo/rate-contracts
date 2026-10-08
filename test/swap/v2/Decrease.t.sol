// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {V2Base} from "./V2Base.sol";
import {IBandPool} from "../../../src/swap/interfaces/IBandPool.sol";
import {IBandPositionManager} from "../../../src/swap/interfaces/IBandPositionManager.sol";

/**
 * A withdrawal takes `bps` of EVERY band in one transaction, or one band through
 * `decreaseBand`. It is the only thing that forfeits: the unvested fee attached to the
 * shares that leave, pro-rata and rounded up, to the band's other shares.
 */
contract V2DecreaseTest is V2Base {
    bytes32 internal constant DECREASED =
        keccak256("DecreaseLiquidity(uint256,uint8[],uint128[],uint256,uint256,uint256,uint256,bool)");

    function test_bpsComesOutOfEveryBandInOneTransaction() public {
        uint256 id = _mintBase(alice, _b(0, 1, 2), 333e18 + 1);
        uint128[3] memory before;
        for (uint8 i = 0; i < 3; i++) {
            before[i] = _sharesIn(id, i);
        }
        uint256 bal = token1.balanceOf(alice);

        vm.recordLogs();
        (uint256 baseOut,) = _decreaseAll(alice, id, 5_000);
        (uint256 count, Vm.Log memory log) = _poolLog(vm.getRecordedLogs(), DECREASED);

        assertEq(count, 1, "one event for the whole ladder");
        (uint8[] memory bands, uint128[] memory removed,,,,,) =
            abi.decode(log.data, (uint8[], uint128[], uint256, uint256, uint256, uint256, bool));
        assertEq(bands.length, 3);
        for (uint8 i = 0; i < 3; i++) {
            uint128 out = uint128((uint256(before[i]) * 5_000) / 10_000);
            assertEq(removed[i], out, "half of each band, rounded down");
            assertEq(_sharesIn(id, i), before[i] - out);
        }
        assertEq(token1.balanceOf(alice) - bal, baseOut);
        uint256 perBand = 333e18 + 1;
        assertEq(baseOut, 3 * (perBand / 2));
    }

    function test_bpsMustBeBetweenOneAndTenThousand() public {
        uint256 id = _mintBase(alice, _b(0), 1e18);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBandPositionManager.BadBps.selector, uint16(0)));
        positionManager.decreaseLiquidity(id, 0, 0, 0, alice, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IBandPositionManager.BadBps.selector, uint16(10_001)));
        positionManager.decreaseLiquidity(id, 10_001, 0, 0, alice, block.timestamp);
        positionManager.decreaseLiquidity(id, 1, 0, 0, alice, block.timestamp);
        vm.stopPrank();
    }

    function test_minBaseAndMinQuoteGuardTheWithdrawal() public {
        uint256 id = _mintBase(alice, _b(0, 1), 1_000e18);
        _buy(trader1, 50_000e18); // leaves quote in the bands
        uint256 snap = vm.snapshotState();
        (uint256 b, uint256 q) = _decreaseAll(alice, id, 4_000);
        vm.revertToState(snap);
        assertGt(b, 0);
        assertGt(q, 0, "two-sided, so both floors mean something");

        vm.startPrank(alice);
        bytes memory err = abi.encodeWithSelector(IBandPositionManager.AmountBelowMinimum.selector, b, q);
        vm.expectRevert(err);
        positionManager.decreaseLiquidity(id, 4_000, b + 1, 0, alice, block.timestamp);
        vm.expectRevert(err);
        positionManager.decreaseLiquidity(id, 4_000, 0, q + 1, alice, block.timestamp);
        (uint256 b2, uint256 q2) = positionManager.decreaseLiquidity(id, 4_000, b, q, alice, block.timestamp);
        vm.stopPrank();
        assertEq(b2, b);
        assertEq(q2, q);
    }

    function test_decreaseBandTouchesOneBandAndClampsToWhatIsHeld() public {
        uint256 id = _mintBase(alice, _b(0, 1, 2), 100e18);
        vm.prank(alice);
        (uint256 b,) = positionManager.decreaseBand(id, 1, 40e18, 0, 0, alice, block.timestamp);
        assertEq(b, 40e18);
        assertEq(_sharesIn(id, 0), 100e18);
        assertEq(_sharesIn(id, 1), 60e18);
        assertEq(_sharesIn(id, 2), 100e18);

        vm.prank(alice);
        (b,) = positionManager.decreaseBand(id, 1, type(uint128).max, 0, 0, alice, block.timestamp);
        assertEq(b, 60e18, "clamped to the slot");
        assertEq(pool.bandMaskOf(id), 0x5, "the emptied band leaves the mask");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBandPositionManager.AmountBelowMinimum.selector, 10e18, 0));
        positionManager.decreaseBand(id, 0, 10e18, 10e18 + 1, 0, alice, block.timestamp);
    }

    function test_aFullExitClearsTheMaskButKeepsTheToken() public {
        uint256 id = _mintBase(alice, _b(0, 1, 2), 100e18);
        uint256 bal = token1.balanceOf(alice);
        _decreaseAll(alice, id, 10_000);
        assertEq(token1.balanceOf(alice) - bal, 300e18, "everything back");
        assertEq(pool.bandMaskOf(id), 0);
        assertEq(_held(id).length, 0);
        assertEq(positionManager.balanceOf(alice, id), 1, "the token survives until burnt");
        assertEq(positionManager.poolOf(id), address(pool));
    }

    // ---------------------------------------------------------------- forfeit

    function test_collectBeforeVestingForfeitsNothing() public {
        uint256 id = _mintBase(alice, _b(0), 1_000e18);
        _buy(trader1, 10_000e18);
        (uint256 accrued,) = _accrued(id);
        assertGt(accrued, 0);
        vm.prank(alice);
        (uint256 paid,) = positionManager.collect(id, alice);
        assertEq(paid, 0, "nothing vested at age zero");
        (uint256 still,) = _accrued(id);
        assertEq(still, accrued, "and nothing was lost");
    }

    function test_aPartialWithdrawalForfeitsProRataToTheOtherLps() public {
        uint256 a = _mintBase(alice, _b(0), 1_000e18);
        uint256 b = _mintBase(bob, _b(0), 1_000e18);
        _buy(trader1, 10_000e18);
        IBandPool.BandView memory va = _slot(a, 0);
        assertGt(va.pendingBase, 0);
        assertEq(va.vestedBase, 0, "age zero");
        (uint256 bobBefore,) = _accrued(b);

        vm.recordLogs();
        _decreaseAll(alice, a, 2_500);
        (, Vm.Log memory log) = _poolLog(vm.getRecordedLogs(), DECREASED);
        (,,,, uint256 forfeitBase,, bool toProtocol) =
            abi.decode(log.data, (uint8[], uint128[], uint256, uint256, uint256, uint256, bool));

        uint256 removed = uint256(va.shares) / 4;
        uint256 expected = (va.pendingBase * removed + va.shares - 1) / va.shares; // rounded UP
        assertEq(forfeitBase, expected, "unvested x removed / shares, rounded up");
        assertFalse(toProtocol);
        assertEq(_slot(a, 0).pendingBase, va.pendingBase - expected, "the rest keeps vesting");
        (uint256 bobAfter,) = _accrued(b);
        assertApproxEqAbs(bobAfter - bobBefore, expected, 1, "the other LP received it");
    }

    function test_theSoleLpsForfeitGoesToTheProtocol() public {
        uint256 id = _mintBase(alice, _b(0), 1_000e18);
        _buy(trader1, 10_000e18);
        (uint256 pending,) = _accrued(id);
        uint256 protocolBefore = pool.protocolFeesBase();

        vm.recordLogs();
        _decreaseAll(alice, id, 10_000);
        (, Vm.Log memory log) = _poolLog(vm.getRecordedLogs(), DECREASED);
        (,,,, uint256 forfeitBase,, bool toProtocol) =
            abi.decode(log.data, (uint8[], uint128[], uint256, uint256, uint256, uint256, bool));

        assertEq(forfeitBase, pending);
        assertTrue(toProtocol, "no other shares to receive it");
        assertEq(pool.protocolFeesBase() - protocolBefore, pending);
    }

    function test_halfVestedFullExitPaysTheVestedHalfAndForfeitsTheRest() public {
        uint256 a = _mintBase(alice, _b(0, 1), 1_000e18);
        _mintBase(bob, _b(0, 1), 1_000e18);
        _buy(trader1, 10_000e18);
        vm.warp(block.timestamp + 300);
        (uint256 vested,) = _claimable(a);
        (uint256 accrued,) = _accrued(a);
        assertGt(vested, 0);
        assertLt(vested, accrued);

        uint256 bal = token1.balanceOf(alice);
        (uint256 principal,) = _decreaseAll(alice, a, 10_000);
        assertEq(token1.balanceOf(alice) - bal, principal + vested, "principal plus the vested fees");
        (uint256 left,) = _accrued(a);
        assertEq(left, 0, "the unvested half forfeited, nothing lingers");
    }
}
