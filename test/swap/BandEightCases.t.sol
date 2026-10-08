// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandBaseSetup} from "./BandBaseSetup.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {IMatchingEngine} from "../../src/exchange/interfaces/IMatchingEngine.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * The eight outcomes of MatchingLib.reportSwapPrice, enumerated one by one against
 * the REAL engine, orderbook and oracle -- with the bands as fractions of the pair's
 * limit, on the factory's shipped ladder (20 / 60 / 100%), so band 2 sits ON the rail.
 *
 * The claim being checked is that tying the bands to the spread changed nothing about
 * how a swap's price is reported. That is structurally true (the pool reads the limit
 * in `syncLimit`, the clamp is in MatchingLib reached through the router) but
 * structural arguments are what this whole area keeps getting wrong, so each branch
 * gets its own case here. What DID change is how a clamp is reached: a band can no
 * longer quote past the rail at a steady anchor, so cases 4 and 5 drive the pool's
 * TWAP anchor away from the block open first -- the only way a v2 pool prints past it.
 *
 * Two of the eight are UNREACHABLE through the real stack, and that is worth pinning
 * as much as the six that fire: `Orderbook.setLmp` rejects zero and `addPair` demands
 * a listing price, so `lmp` is never 0 and neither is the block-open anchor derived
 * from it. They are defensive branches, and they should stay defensive.
 */
contract BandEightCasesTest is BandBaseSetup {
    uint32 constant DENOM = 100000000;
    uint32 constant TIGHT = 100000; // 0.1%, the production market spread

    function setUp() public override {
        super.setUp();
        pool.configureBands(poolFactory.defaultSpreadFracs(), poolFactory.defaultFeeMultipliers());
        vm.warp(block.timestamp + 600);
        // Out of the listing block, whose setLmp opened it from zero: until the next
        // block the rail would anchor on the live lmp rather than a block open.
        vm.roll(block.number + 1);
        _seedBands(1_000e18);
    }

    /**
     * Move the BOOK to `price` with one ordinary match, leaving the pool's TWAP behind
     * it. Nothing of the taker's reaches the pool: every band bound is above `price`,
     * so the fallback's own limit-price bound refuses the remainder.
     */
    function _bookTradesAt(uint256 price) internal {
        vm.startPrank(trader2);
        token1.approve(address(matchingEngine), type(uint256).max);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1), quote: address(token2), price: price,
                amount: 1e18, isMaker: true, n: 2, recipient: trader2
            })
        );
        vm.stopPrank();
        vm.recordLogs();
        vm.startPrank(trader1);
        token2.approve(address(matchingEngine), type(uint256).max);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1), quote: address(token2), price: price,
                amount: (price * 1e18) / 1e8, isMaker: false, n: 1, recipient: trader1
            })
        );
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 routed = keccak256("RemainderRoutedToPool(address,address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != routed, "the pool took no part");
        }
        assertEq(_lmp(), price, "the book printed the match");
    }

    function _spread(uint32 buy, uint32 sell) internal {
        matchingEngine.setSpread(address(token1), address(token2), buy, sell, true);
    }

    function _sell(address who, uint256 baseIn) internal returns (uint256) {
        vm.startPrank(who);
        token1.approve(address(router), type(uint256).max);
        uint256 out = router.swap(address(pool), baseIn, false, who, 0);
        vm.stopPrank();
        return out;
    }

    // ---- 1. lmp == 0 ---------------------------------------------------------

    /**
     * Unreachable, and pinned as such. A pair cannot exist with a zero lmp: addPair
     * sets the listing price and setLmp refuses zero outright, so the branch guards
     * against a state the engine will not produce.
     */
    function test_case1_lmpIsNeverZeroSoTheBranchStaysDefensive() public {
        assertGt(_lmp(), 0, "listed with a price");
        vm.expectRevert();
        book.setLmp(0);
        assertGt(_lmp(), 0, "and it cannot be driven to zero");
    }

    // ---- 2. matchedPrice == 0 ------------------------------------------------

    /// Dust: the pool's own gate zeroes matchedPrice, so nothing is reported.
    function test_case2_dustReportsNothing() public {
        _spread(TIGHT, TIGHT);
        uint256 before_ = _lmp();
        _buy(trader1, 210);
        assertEq(_lmp(), before_, "a fill below the report threshold prints nothing");
    }

    /// And a swap that fills nothing never reaches the report at all.
    function test_case2_aSwapThatFillsNothingCannotReport() public {
        _spread(TIGHT, TIGHT);
        _buy(trader1, 8_000_000e18); // sweep every band's base
        uint256 before_ = _lmp();

        vm.startPrank(trader1);
        token2.approve(address(router), type(uint256).max);
        vm.expectRevert(BandPool.NoLiquidity.selector);
        router.swap(address(pool), 1e18, true, trader1, 0);
        vm.stopPrank();
        assertEq(_lmp(), before_);
    }

    // ---- 3. down >= denom collapses the floor to zero -------------------------

    /**
     * A 100% sell spread means "no lower bound". Taking `denom - down` there would
     * underflow and revert a settled trade, which a rail must never do -- so the floor
     * becomes 0 instead and the swap goes through.
     */
    function test_case3_aHundredPercentSellSpreadDoesNotUnderflow() public {
        _buy(trader1, 500_000e18); // give the bands quote to pay a seller with
        _spread(TIGHT, DENOM);     // sell side at exactly 100%

        token1.mint(trader2, 100e18);
        uint256 out = _sell(trader2, 100e18);
        assertGt(out, 0, "the trade settles rather than reverting on the rail");
    }

    // ---- 4 & 5. the clamps ---------------------------------------------------

    /**
     * A buy that trades past the ceiling records the ceiling.
     *
     * At a steady anchor band 2 IS the ceiling, so the book has to move first: it trades
     * 1% down, the next block opens there, and the pool's 300s TWAP still sits near the
     * listing. Band 2 then quotes a full spread above THAT, well past the new ceiling.
     */
    function test_case4_aBuyAboveTheCeilingIsClampedDown() public {
        _spread(TIGHT, TIGHT);
        _bookTradesAt(99e8);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);

        uint256 ceiling = (_lmp() * (DENOM + TIGHT)) / DENOM;
        uint256 bandTwoBound = (pool.anchorPrice() * (DENOM + TIGHT)) / DENOM;
        assertGt(bandTwoBound, ceiling, "the lagging anchor puts band 2 past the rail");

        _buy(trader1, 500_000e18); // deep enough to reach the widest band
        assertEq(_lmp(), ceiling, "clamped to the block-open ceiling");
    }

    /**
     * And the sell side is symmetric, clamped up to the floor. The buy leaves lmp on the
     * ceiling; next block opens there while the TWAP has barely moved off the listing,
     * so band 2's sell bound -- a full spread below the anchor -- is under the floor.
     */
    function test_case5_aSellBelowTheFloorIsClampedUp() public {
        _spread(TIGHT, TIGHT); // without this the fixture's 10% spread never binds
        _buy(trader1, 500_000e18);
        vm.roll(block.number + 1); // fresh cap, so the sell is not fighting the buy's
        vm.warp(block.timestamp + 12);
        uint256 openPrice = _lmp();
        uint256 floor_ = (openPrice * (DENOM - TIGHT)) / DENOM;
        assertLt((pool.anchorPrice() * (DENOM - TIGHT)) / DENOM, floor_, "band 2 sells below the floor");

        token1.mint(trader2, 5_000e18);
        _sell(trader2, 5_000e18);
        assertEq(_lmp(), floor_, "clamped to the block-open floor");
    }

    // ---- 6. the clamped result is zero ---------------------------------------

    /**
     * Also unreachable. The clamp is anchored to `lmpAtBlockOpen`, which is derived
     * from an lmp that case 1 shows can never be zero -- so a zero ceiling would need
     * a 100% BUY spread AND a zero anchor, and the second cannot happen.
     */
    function test_case6_theClampedResultCannotBeZero() public {
        _spread(DENOM, DENOM); // both sides at 100%: floor is 0, ceiling is 2x
        _buy(trader1, 500_000e18);
        assertGt(_lmp(), 0, "a report can never drive the reference to zero");
    }

    // ---- 7. the clamped result equals the current lmp ------------------------

    /**
     * A zero spread pins ceiling and floor to the block open: nothing can move.
     *
     * Two halves in v2. The pool's limit IS the spread, so at zero every band idles and
     * no pool trade can reach the rail at all. The rail's own branch is then reached the
     * one way that remains -- a report from the router, whatever price it carries.
     */
    function test_case7_aZeroSpreadFreezesTheReference() public {
        _spread(0, 0);
        uint256 before_ = _lmp();
        assertEq(pool.pairLimit(true), 0, "the pool synced to the zero spread");

        vm.startPrank(trader1);
        token2.approve(address(router), type(uint256).max);
        vm.expectRevert(BandPool.NoLiquidity.selector);
        router.swap(address(pool), 500_000e18, true, trader1, 0);
        vm.stopPrank();

        vm.prank(address(router));
        matchingEngine.reportSwap(address(token1), address(token2), true, 2 * LISTING);
        assertEq(_lmp(), before_, "ceiling == floor == anchor, so the write is a no-op");
    }

    /// A second swap in the same block also no-ops: the anchor cannot move inside a block,
    /// so the same band prints the same bound and the write equals the current lmp.
    function test_case7_aSecondSwapInTheSameBlockAddsNothing() public {
        _spread(TIGHT, TIGHT);
        // Sized so the pool is not swept: a second swap needs base left to buy.
        _buy(trader1, 50_000e18);
        uint256 atCeiling = _lmp();
        _buy(trader1, 50_000e18); // same block
        assertEq(_lmp(), atCeiling, "the cap is spent for this block");
    }

    // ---- 8. the write -------------------------------------------------------

    function test_case8_anOrdinarySwapWritesAndTheCapReArms() public {
        _spread(TIGHT, TIGHT);
        assertEq(_lmp(), LISTING);

        _buy(trader1, 50_000e18);
        uint256 first = _lmp();
        assertGt(first, LISTING, "case 8: it wrote");

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        _buy(trader1, 50_000e18);
        assertGt(_lmp(), first, "and next block earns another step");
    }
}
