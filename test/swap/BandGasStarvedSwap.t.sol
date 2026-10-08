pragma solidity >=0.8;

import {BandBaseSetup} from "./BandBaseSetup.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {BandSwapRouter} from "../../src/swap/BandSwapRouter.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * A swap that runs low on gas must settle what it filled, not revert.
 *
 * ## The exposure
 *
 * A swap's cost depends on how many BANDS it crosses -- ~115,000 warm for the first
 * and ~44,000 for each one after (GasProbe_OrderPaths, v2 ladder) -- and the taker
 * fixes the gas limit before knowing what it will meet. Pool state moves between
 * quoting and mining, so this is the same shape of failure the order book had: an
 * estimate taken against one pool, executed against another, dying out of gas with
 * empty revert data.
 *
 * ## Why the band walk is a BETTER fit for the guard than the book was
 *
 * `swap` settles with `safeTransferFrom(..., amountIn - remainingIn)` -- it only ever
 * pulls what it actually filled. So an early exit needs no refund path and strands
 * nothing: the taker is charged for the bands they got and the rest of their input
 * never leaves their wallet. "You sold less than you asked" is the whole semantics,
 * and it needs no resting-order design the way a truncated limit order does.
 *
 * ## What the guard does NOT remove
 *
 * `minAmountOut`. A truncated fill that delivers less than the taker agreed to still
 * reverts `SlippageExceeded` -- their own bound, named. That is correct: the guard is
 * here to remove the OPAQUE failure, not the taker's protection.
 */
contract BandGasStarvedSwapTest is BandBaseSetup {
    bytes32 constant HALT_TOPIC = keccak256("SwapHaltedForGas(address,uint256,uint256)");

    function _swapWithGas(address who, uint256 quoteIn, uint256 gasCap)
        internal
        returns (bool ok, uint256 spent)
    {
        vm.startPrank(who);
        token2.approve(address(router), type(uint256).max);
        uint256 before = token2.balanceOf(who);
        bytes memory call_ = abi.encodeCall(
            BandSwapRouter.swap, (address(pool), quoteIn, true, who, 0)
        );
        (ok,) = address(router).call{gas: gasCap}(call_);
        spent = before - token2.balanceOf(who);
        vm.stopPrank();
    }

    function _sawHalt(Vm.Log[] memory logs) internal pure returns (bool) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == HALT_TOPIC) return true;
        }
        return false;
    }

    /// Like `_swapWithGas`, but with a minimum and the revert data, and whether it halted.
    function _swapWithGasMin(uint256 quoteIn, uint256 gasCap, uint256 minOut)
        internal
        returns (bool ok, uint256 spent, bool halted, bytes memory ret)
    {
        vm.startPrank(trader1);
        token2.approve(address(router), type(uint256).max);
        uint256 before = token2.balanceOf(trader1);
        vm.recordLogs();
        (ok, ret) = address(router).call{gas: gasCap}(
            abi.encodeCall(BandSwapRouter.swap, (address(pool), quoteIn, true, trader1, minOut))
        );
        // Logs from a reverted call are recorded too, so a halt only counts on success.
        halted = ok && _sawHalt(vm.getRecordedLogs());
        spent = before - token2.balanceOf(trader1);
        vm.stopPrank();
    }

    /*
     * Measured in this fixture (BandBaseSetup, bandCount = 3, 20e18 base per band, so
     * ~2,002e18 of quote fills band 0), which is where the inputs below come from:
     *
     *   1600e18, one band, cold ............ ~250,000
     *   3000e18, two bands, cold ........... ~284,000
     *   5000e18, three bands, cold ......... ~317,000
     *
     * The 180,000 reserve is sized for the COLD settlement tail (pool transfers, the
     * router's refund and its report), so a 3000e18 swap halts after band 0 on any
     * budget from ~260,000 up past ~330,000 -- more than the full walk would cost. That
     * is the trade the constant states: too much reserve ends the walk a band early,
     * too little is the opaque revert. Below ~260,000 even band 0 cannot be settled,
     * and the swap reverts, taking nothing.
     */
    uint256 constant TWO_BAND_INPUT = 3000e18;

    /// Sweep for a budget at which the walk halts and settles, rather than hard-coding
    /// one: the window is wide, but where it sits moves with every compiler change.
    function _haltingBudget() internal returns (uint256) {
        for (uint256 cap = 400_000; cap >= 150_000; cap -= 5_000) {
            uint256 snap = vm.snapshotState();
            (bool ok, uint256 spent, bool halted,) = _swapWithGasMin(TWO_BAND_INPUT, cap, 0);
            vm.revertToState(snap);
            if (ok && halted && spent < TWO_BAND_INPUT) return cap;
        }
        revert("no budget halts the walk");
    }

    /**
     * The safety property, swept across the whole plausible budget range.
     *
     * Whatever the gas limit, a taker is never charged for input they did not receive:
     * either the swap settles and takes only what it filled, or it reverts and takes
     * nothing. This is what the `amountIn - remainingIn` settlement buys, and it is the
     * property the guard has to preserve rather than break.
     */
    function test_anyGasBudget_neverChargesForUnfilledInput() public {
        _seedBands(20e18);
        for (uint256 cap = 400_000; cap >= 150_000; cap -= 10_000) {
            uint256 snap = vm.snapshotState();
            (bool ok, uint256 spent) = _swapWithGas(trader1, TWO_BAND_INPUT, cap);
            if (ok) {
                assertGt(spent, 0, "a successful swap must have filled something");
                assertLe(spent, TWO_BAND_INPUT, "it can never take more than was offered");
            } else {
                assertEq(spent, 0, "a reverted swap must take nothing at all");
            }
            vm.revertToState(snap);
        }
    }

    /// With room to spare the walk completes and the guard stays out of the way.
    function test_ampleGas_completesAndNeverHalts() public {
        _seedBands(20e18);

        vm.recordLogs();
        (bool ok, uint256 spent) = _swapWithGas(trader1, TWO_BAND_INPUT, 30_000_000);

        assertTrue(ok, "a well-funded swap must succeed");
        assertFalse(_sawHalt(vm.getRecordedLogs()), "the reserve must not fire when gas is ample");
        assertEq(spent, TWO_BAND_INPUT, "it should have consumed the whole input");
    }

    /**
     * The partial fill itself, which v1's fixture could not reach: there a 1600e18 input
     * fit one band, so the walk had no band boundary at which to halt. 3000e18 crosses
     * one. The taker pays for band 0, receives band 0's base, and keeps the rest.
     */
    function test_lowGas_haltsAndSettlesWhatItFilled() public {
        _seedBands(20e18);
        uint256 cap = _haltingBudget();

        uint256 baseBefore = token1.balanceOf(trader1);
        uint256 poolQuoteBefore = token2.balanceOf(address(pool));
        (bool ok, uint256 spent, bool halted,) = _swapWithGasMin(TWO_BAND_INPUT, cap, 0);

        assertTrue(ok && halted, "halted and settled");
        assertGt(spent, 0, "it filled something");
        assertLt(spent, TWO_BAND_INPUT, "and not everything: the rest never left the taker");
        assertEq(token2.balanceOf(address(pool)) - poolQuoteBefore, spent, "the pool holds exactly what was spent");
        assertGt(token1.balanceOf(trader1), baseBefore, "and the taker got that part's base");
        assertEq(token2.balanceOf(address(router)), 0, "nothing stranded in the router");
    }

    /**
     * The taker's own slippage bound still applies to a truncated fill.
     *
     * v1 asked for this at a budget that simply ran out of gas, so the revert it saw was
     * the opaque one this guard exists to remove. Here the budget is one at which the
     * walk DOES halt and settle, and the minimum is one only a complete walk can meet --
     * so the refusal has to be the taker's named bound.
     */
    function test_lowGas_stillHonoursMinAmountOut() public {
        _seedBands(20e18);
        uint256 cap = _haltingBudget();

        // A full walk delivers ~29.9e18; halting after band 0 delivers ~20e18.
        uint256 before = token2.balanceOf(trader1);
        (bool ok,,, bytes memory ret) = _swapWithGasMin(TWO_BAND_INPUT, cap, 25e18);

        assertFalse(ok, "an under-delivering swap must still be refused");
        assertEq(bytes4(ret), BandPool.SlippageExceeded.selector, "by the taker's own bound, named");
        assertEq(token2.balanceOf(trader1), before, "a reverted swap must take nothing");
    }
}
