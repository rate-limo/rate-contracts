// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {BandPoolFactory} from "../../src/swap/BandPoolFactory.sol";
import {BandPositionManager} from "../../src/swap/BandPositionManager.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";
import {RTok, RBook, REngine} from "./BandRampProbe.t.sol";

/**
 * The lesser-ratio rule mints on min(byBase, byQuote). Crediting BOTH requested
 * amounts to the reserves while minting on the smaller one hands the excess of the
 * larger side to everybody already in the band, and the depositor cannot get it back
 * because they hold no shares against it.
 *
 * Measured before the fix: a two-sided deposit at ten times the band's ratio put in
 * 2,000 quote and got back 363.6. No revert, no warning. These tests exist because
 * nothing else in the suite deposits at a ratio the band does not already hold.
 */
contract BandDepositSkewTest is Test {
    BandPoolFactory factory;
    BandPositionManager manager;
    BandPool pool;
    RTok baseTok;
    RTok quoteTok;
    RBook book;
    REngine eng;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        baseTok = new RTok();
        quoteTok = new RTok();
        book = new RBook();
        eng = new REngine();
        manager = new BandPositionManager();
        manager.initialize("");
        factory = new BandPoolFactory();
        factory.initialize(address(eng), address(manager), address(new BandPool()), address(0xC0FFEE));
        manager.setPoolFactory(address(factory));
        vm.prank(address(eng));
        pool = BandPool(factory.createPool(address(baseTok), address(quoteTok), address(book), address(0)));
        pool.syncLimit();
        vm.warp(1_000_000);
    }

    function _mint(address who, uint256 baseAmt, uint256 quoteAmt) internal returns (uint256 tokenId) {
        baseTok.mint(who, baseAmt);
        quoteTok.mint(who, quoteAmt);
        vm.startPrank(who);
        baseTok.approve(address(manager), type(uint256).max);
        quoteTok.approve(address(manager), type(uint256).max);
        uint8[] memory bands = new uint8[](1);
        uint256[] memory ba = new uint256[](1);
        uint256[] memory qa = new uint256[](1);
        ba[0] = baseAmt;
        qa[0] = quoteAmt;
        (tokenId,) = manager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: ba,
                quoteAmounts: qa,
                minShares: new uint128[](1),
                recipient: who,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    function _exit(address who, uint256 tokenId) internal returns (uint256 baseOut, uint256 quoteOut) {
        vm.prank(who);
        return manager.decreaseLiquidity(tokenId, 10_000, 0, 0, who, block.timestamp);
    }

    /// A deposit at the band's own ratio gets back what it put in. The control.
    function test_aProportionalDepositIsNotHaircut() public {
        _mint(alice, 1_000e18, 2_000e18);
        uint256 id = _mint(bob, 100e18, 200e18);

        vm.warp(block.timestamp + 601);
        (uint256 baseOut, uint256 quoteOut) = _exit(bob, id);
        assertApproxEqRel(baseOut, 100e18, 1e12, "base back");
        assertApproxEqRel(quoteOut, 200e18, 1e12, "quote back");
    }

    /// Ten times too much quote for the shares it buys. The excess never leaves him.
    function test_aSkewedDepositRefundsWhatTheSharesDidNotBuy() public {
        _mint(alice, 1_000e18, 2_000e18);
        uint256 id = _mint(bob, 100e18, 2_000e18); // ratio 1:20, the band holds 1:2

        // 1,800 of the 2,000 bought nothing, so it was handed straight back.
        assertEq(quoteTok.balanceOf(bob), 1_800e18, "refunded at deposit");

        vm.warp(block.timestamp + 601);
        (uint256 baseOut, uint256 quoteOut) = _exit(bob, id);
        assertEq(baseOut, 100e18);
        assertEq(quoteOut, 200e18);
        // Whole: nothing was silently donated to the band.
        assertEq(quoteTok.balanceOf(bob), 2_000e18, "every unit accounted for");
        assertEq(baseTok.balanceOf(bob), 100e18);
    }

    /// A skewed deposit must not enrich the LPs already there at the depositor's cost.
    function test_theExistingLpIsNoBetterOffForSomebodyElsesBadRatio() public {
        uint256 aliceId = _mint(alice, 1_000e18, 2_000e18);
        _mint(bob, 100e18, 2_000e18);

        vm.warp(block.timestamp + 601);
        (uint256 baseOut, uint256 quoteOut) = _exit(alice, aliceId);
        assertApproxEqRel(baseOut, 1_000e18, 1e12, "alice gets her own deposit back");
        assertApproxEqRel(quoteOut, 2_000e18, 1e12, "and not a share of bob's excess");
    }

    /// The manager must not leave the pool approved for the part it did not spend.
    function test_noStaleApprovalSurvivesARefund() public {
        _mint(alice, 1_000e18, 2_000e18);
        _mint(bob, 100e18, 2_000e18);
        assertEq(quoteTok.allowance(address(manager), address(pool)), 0, "approval cleared with the refund");
    }

    /**
     * Withdrawing twice must not look like two withdrawals to anything downstream.
     *
     * FAILS against v2: `decrease` on a position holding no band still reaches
     * `_settleRemoval` and emits `DecreaseLiquidity` with empty arrays and zero amounts
     * (src/swap/BandPool.sol:259 -> :329).
     */
    function test_aSecondWithdrawalIsNotAPhantomEvent() public {
        _mint(alice, 1_000e18, 2_000e18);
        uint256 id = _mint(bob, 100e18, 200e18);
        vm.warp(block.timestamp + 601);
        _exit(bob, id);
        vm.recordLogs();
        _exit(bob, id);
        assertEq(vm.getRecordedLogs().length, 0, "an empty position emits nothing on a repeat exit");
    }

    /// Withdrawing repeatedly must stay a no-op. The token survives an exit until it is
    /// burned, so a repeat is reachable by ordinary use.
    function test_repeatedWithdrawalStaysANoOp() public {
        _mint(alice, 1_000e18, 2_000e18);
        uint256 id = _mint(bob, 100e18, 200e18);
        vm.warp(block.timestamp + 601);
        _exit(bob, id);
        (uint256 b2, uint256 q2) = _exit(bob, id);
        (uint256 b3, uint256 q3) = _exit(bob, id);
        assertEq(b2 + q2 + b3 + q3, 0, "nothing comes out twice");
    }

    /**
     * v1 minted a fresh position id for every deposit, and pinned that the ids rose
     * monotonically. The pool has no ids of its own in v2; the manager's token id is the
     * position, a mint is the only thing that takes a new one, and a top-up does not.
     */
    function test_mintsTakeMonotonicIdsAndATopUpTakesNone() public {
        uint256 a = _mint(alice, 1_000e18, 2_000e18);
        uint256 b = _mint(bob, 100e18, 200e18);
        assertEq(a, 1);
        assertEq(b, 2);
        assertEq(manager.nextTokenId(), 3, "the id the next mint will take");

        baseTok.mint(alice, 100e18);
        quoteTok.mint(alice, 200e18);
        uint8[] memory bands = new uint8[](1);
        uint256[] memory ba = new uint256[](1);
        uint256[] memory qa = new uint256[](1);
        ba[0] = 100e18;
        qa[0] = 200e18;
        vm.prank(alice);
        manager.increaseLiquidity(a, bands, ba, qa, new uint128[](1), block.timestamp);
        assertEq(manager.nextTokenId(), 3, "a top-up is the same token");
        assertEq(manager.balanceOf(alice, a), 1);
    }
}
