// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandBaseSetup} from "./BandBaseSetup.sol";
import {Vm} from "forge-std/Vm.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";

/**
 * A deposit and a withdrawal each report BOTH of their units, so a position's PnL is
 * derivable from the log alone.
 *
 * ## The gap this closes
 *
 * v1's add event carried only `shares` and its remove event only `baseOut`/`quoteOut`.
 * Neither is convertible into the other after the fact -- the reserve ratio moves with
 * every swap -- so an indexer could see what a position was WORTH when it closed and
 * never what it COST to open. A ledger built on that reports proceeds against no basis,
 * which is not a small error: it is the entire gain.
 *
 * v2's `IncreaseLiquidity` and `DecreaseLiquidity` carry per-band shares AND the amounts,
 * once per call for the whole ladder. This pins that the open and the close of one
 * position can be paired.
 */
contract BandPositionLedgerTest is BandBaseSetup {
    bytes32 constant ADDED = keccak256("IncreaseLiquidity(uint256,uint8[],uint128[],uint256,uint256)");
    bytes32 constant REMOVED =
        keccak256("DecreaseLiquidity(uint256,uint8[],uint128[],uint256,uint256,uint256,uint256,bool)");

    /// The pool's own event, which is the one carrying amounts and shares.
    function _find(Vm.Log[] memory logs, bytes32 topic) internal view returns (Vm.Log memory log) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic && logs[i].emitter == address(pool)) {
                return logs[i];
            }
        }
        revert("the pool did not emit the event");
    }

    function _sum(uint128[] memory a) internal pure returns (uint256 s) {
        for (uint256 i = 0; i < a.length; i++) {
            s += a[i];
        }
    }

    function _mint3() internal returns (uint256 tokenId) {
        uint8[] memory bands = new uint8[](3);
        uint256[] memory base = new uint256[](3);
        for (uint8 i = 0; i < 3; i++) {
            bands[i] = i;
            base[i] = 1000e18;
        }
        vm.startPrank(lp1);
        token1.approve(address(positionManager), type(uint256).max);
        token2.approve(address(positionManager), type(uint256).max);
        (tokenId,) = positionManager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: base,
                quoteAmounts: new uint256[](3),
                minShares: new uint128[](3),
                recipient: lp1,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    function test_aDepositReportsWhatItCostAndWhatItBought() public {
        vm.recordLogs();
        uint256 tokenId = _mint3();
        Vm.Log memory log = _find(vm.getRecordedLogs(), ADDED);
        assertEq(uint256(log.topics[1]), tokenId, "keyed by the manager's token id");
        (uint8[] memory bands, uint128[] memory shares, uint256 baseIn, uint256 quoteIn) =
            abi.decode(log.data, (uint8[], uint128[], uint256, uint256));

        assertEq(bands.length, 3, "one event names every band");
        assertGt(_sum(shares), 0, "a deposit mints shares");
        // The basis. Single-sided into base-only bands, so base is what was spent.
        assertGt(baseIn, 0, "and reports what it actually cost");
        assertLe(baseIn, 3000e18, "never more than was offered");
        assertEq(quoteIn, 0, "a single-sided deposit spends one leg");
    }

    function test_aWithdrawalReportsTheSharesItBurned() public {
        uint256 tokenId = _mint3();

        vm.recordLogs();
        vm.prank(lp1);
        positionManager.decreaseLiquidity(tokenId, 10_000, 0, 0, lp1, block.timestamp);

        Vm.Log memory log = _find(vm.getRecordedLogs(), REMOVED);
        (uint8[] memory bands, uint128[] memory shares, uint256 baseOut, uint256 quoteOut,,,) =
            abi.decode(log.data, (uint8[], uint128[], uint256, uint256, uint256, uint256, bool));

        // Without `shares` an indexer cannot tell a partial close from a full one, so it
        // marks the row inactive and keeps a stale share count.
        assertEq(bands.length, 3);
        assertGt(_sum(shares), 0, "the close reports the shares it burned");
        assertTrue(baseOut > 0 || quoteOut > 0, "and what came out");
    }

    /**
     * The pairing itself: the shares opened equal the shares closed, band by band, so the
     * two events describe one position rather than two unrelated facts.
     */
    function test_theOpenAndTheCloseAgreeOnShares() public {
        vm.recordLogs();
        uint256 tokenId = _mint3();
        (, uint128[] memory opened,,) =
            abi.decode(_find(vm.getRecordedLogs(), ADDED).data, (uint8[], uint128[], uint256, uint256));

        vm.recordLogs();
        vm.prank(lp1);
        positionManager.decreaseLiquidity(tokenId, 10_000, 0, 0, lp1, block.timestamp);
        (, uint128[] memory closed,,,,,) = abi.decode(
            _find(vm.getRecordedLogs(), REMOVED).data, (uint8[], uint128[], uint256, uint256, uint256, uint256, bool)
        );

        assertEq(closed.length, opened.length);
        for (uint256 i = 0; i < opened.length; i++) {
            assertEq(closed[i], opened[i], "the close burns exactly what the open minted");
        }
    }
}
