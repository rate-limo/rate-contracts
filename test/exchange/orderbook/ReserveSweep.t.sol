pragma solidity >=0.8;

import {MatchingEngine} from "../../../src/exchange/MatchingEngine.sol";
import {MatchingLib} from "../../../src/exchange/libraries/MatchingLib.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";
import {BaseSetup} from "../OrderbookBaseSetup.sol";

/**
 * `MATCH_GAS_RESERVE` must hold at EVERY gas limit, not at one calibrated number.
 *
 * ## Why this exists rather than a second fixed-cap test
 *
 * `GasStarvedMatching.t.sol` asserts the outcome at one cap. That is the right shape for
 * "a starved order rests rather than reverting", and it is not enough to size the
 * reserve, because the amount of gas actually left when the guard fires is a RANGE, not
 * a number: the check passes at >= RESERVE, one more unit of work runs, and the next
 * check sees anywhere in `[RESERVE - oneUnit, RESERVE)`. A cap that lands in the low end
 * of that band leaves less for the tail than the reserve implies. So the failure is
 * PERIODIC in the caller's gas limit -- a hole roughly every `oneUnit` of gas -- and a
 * single cap either sits in a hole or it does not, for reasons that have nothing to do
 * with whether the reserve is correct.
 *
 * That is exactly how the defect shipped. The one fixed cap (700,000) sat outside a hole
 * under Foundry's old `isolate = false` default and inside one under `isolate = true`,
 * so a real contract bug read as a toolchain difference. Measured at the time, with the
 * guard checked per price level and a 300,000 reserve: 23 of 116 sampled caps reverted
 * on a one-ask-per-level ladder, and 57 of 116 against a level holding six asks.
 *
 * ## Read these as transactions, not as a stress test
 *
 * Every case runs under `isolate`, which is the only regime that prices a real
 * transaction: a fresh access list, so every slot is cold. Warm numbers understate the
 * tail by about 60,000 gas and are what produced the original 300,000. See the
 * `MATCH_GAS_RESERVE` docstring.
 *
 * `deepLevel` is the case a per-level guard cannot see and is therefore the point of the
 * file: a single price holds many orders, and `matchAt` chews through all of them inside
 * ONE iteration of `limitOrder`'s loop. `test_depthIndependence` is the property that
 * makes a bounded constant legitimate -- if the reserve had to grow with the depth of a
 * level, no constant would be correct and the guard would belong somewhere else.
 */
contract ReserveSweepTest is BaseSetup {
    uint32 constant LEVELS = 8;

    /// Coarse on purpose. A 1,000-gas step over this range is ~3.5B gas, past
    /// `gas_limit`; run one by hand when changing the reserve.
    uint256 constant CAP_LO = 450_000;
    uint256 constant CAP_HI = 1_600_000;
    uint256 constant CAP_STEP = 10_000;

    function _pair() internal {
        matchingEngine.addPair(
            address(token1), address(token2), 300000000, 0, address(token1),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
    }

    function _ask(uint256 price) internal {
        vm.prank(trader1);
        matchingEngine.limitSell(IMatchingEngine.LimitOrderInput({
            base: address(token1), quote: address(token2), price: price,
            amount: 1e18, isMaker: true, n: 1, recipient: trader1
        }));
    }

    /// One ask per level: one iteration of the outer loop is one match.
    function _ladder() internal {
        _pair();
        for (uint32 i = 0; i < LEVELS; i++) _ask(300000000 + i * 1000000);
    }

    /// `deep` asks at ONE price, then the rest of the ladder.
    function _deep(uint32 deep) internal {
        _pair();
        for (uint32 i = 0; i < deep; i++) _ask(300000000);
        for (uint32 i = 1; i < LEVELS; i++) _ask(300000000 + i * 1000000);
    }

    /// A bid above every ask and sized to take them all, so the only reason to stop
    /// early is the reserve. `isMaker` decides whether the remainder rests or is
    /// refunded -- two different tails, both of which the reserve must cover.
    ///
    /// `ok` also accepts `InsufficientGasToMatch`: an order starved before its FIRST match
    /// now reverts on purpose and by name (see MatchingLib). What this file hunts is the
    /// other kind of revert -- out of gas mid-write, with empty revert data -- and that
    /// still fails here, because it carries no selector.
    function _sweep(uint256 cap, bool isMaker) internal returns (bool ok) {
        bytes memory call_ = abi.encodeCall(MatchingEngine.limitBuy, (
            IMatchingEngine.LimitOrderInput({
                base: address(token1), quote: address(token2), price: 400000000,
                amount: 100e18, isMaker: isMaker, n: LEVELS, recipient: trader2
            })
        ));
        vm.prank(trader2);
        bytes memory ret;
        (ok, ret) = address(matchingEngine).call{gas: cap}(call_);
        if (!ok) ok = ret.length == 4 && bytes4(ret) == MatchingLib.InsufficientGasToMatch.selector;
    }

    /// Fresh book per cap, since a successful rest mutates it.
    function _assertNoHole(bool deepLevel, bool isMaker, string memory label) internal {
        for (uint256 cap = CAP_LO; cap <= CAP_HI; cap += CAP_STEP) {
            uint256 snap = vm.snapshotState();
            if (deepLevel) _deep(6); else _ladder();
            bool ok = _sweep(cap, isMaker);
            vm.revertToState(snap);
            assertTrue(
                ok,
                string.concat(
                    label, ": a gas-starved order reverted at cap ", vm.toString(cap),
                    ". MATCH_GAS_RESERVE is too small for one unit of work plus the tail."
                )
            );
        }
    }

    function test_ladder_maker_neverReverts() public { _assertNoHole(false, true, "ladder/maker"); }
    function test_ladder_taker_neverReverts() public { _assertNoHole(false, false, "ladder/taker"); }
    function test_deepLevel_maker_neverReverts() public { _assertNoHole(true, true, "deepLevel/maker"); }
    function test_deepLevel_taker_neverReverts() public { _assertNoHole(true, false, "deepLevel/taker"); }

    /**
     * The reserve must NOT have to grow with how many orders sit at one price.
     *
     * This is the claim that justifies a constant at all. `maxMatches` defaults to 20
     * and `setMaxMatches` has no upper bound, so a reserve that scaled with level depth
     * could never be written down as a number.
     */
    function test_depthIndependence() public {
        for (uint32 deep = 2; deep <= 20; deep += 2) {
            for (uint256 cap = CAP_LO; cap <= CAP_HI; cap += 50_000) {
                uint256 snap = vm.snapshotState();
                _deep(deep);
                bool ok = _sweep(cap, true);
                vm.revertToState(snap);
                assertTrue(ok, string.concat(
                    "reverted with ", vm.toString(deep), " orders at one price, cap ",
                    vm.toString(cap)
                ));
            }
        }
    }

    /// The reserve has to clear the floor the docstring derives: one order (~105,000)
    /// plus the tail (~353,000). Pinned so lowering it needs a deliberate re-measure.
    function test_reserveClearsItsDerivedFloor() public {
        assertGe(MatchingLib.matchGasReserve(), 458_000, "reserve below one order + tail");
    }
}
