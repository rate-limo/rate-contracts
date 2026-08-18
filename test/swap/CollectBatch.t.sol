// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {PositionManager} from "../../src/swap/PositionManager.sol";
import {IPositionManager} from "../../src/swap/interfaces/IPositionManager.sol";
import {IPool} from "../../src/swap/interfaces/IPool.sol";
import {Pool} from "../../src/swap/Pool.sol";
import {MockBase} from "../../src/mock/MockBase.sol";
import {MockQuote} from "../../src/mock/MockQuote.sol";

/// Batch fee claim across positions the caller already controls.
/// See docs/superpowers/specs/2026-08-18-batch-lp-fee-claim-design.md
contract CollectBatchTest is PoolBaseSetup {
    PositionManager pm;

    // Pool A -- token3/token4
    Pool poolA;
    MockBase token3;
    MockQuote token4;

    // Pool B -- token5/token6, a genuinely different token pair so the
    // cross-pool test can prove nothing is summed across tokens.
    Pool poolB;
    MockBase token5;
    MockQuote token6;

    uint256 constant MAX_CLAIM_BATCH = 30;

    function setUp() public override {
        super.setUp();

        pm = new PositionManager();
        pm.initialize("ipfs://iter-swap-positions/{id}.json");
        pm.setPoolFactory(address(poolFactory));
        poolFactory.setPositionManager(address(pm));

        (token3, token4, poolA) = _listPair("Base3", "BASE3", "Quote4", "QUOTE4");
        (token5, token6, poolB) = _listPair("Base5", "BASE5", "Quote6", "QUOTE6");
    }

    // ---- helpers -------------------------------------------------------

    function _listPair(string memory bn, string memory bs, string memory qn, string memory qs)
        internal
        returns (MockBase b, MockQuote q, Pool p)
    {
        b = new MockBase(bn, bs);
        q = new MockQuote(qn, qs);
        b.mint(lp1, 100000e18);
        q.mint(lp1, 100000e18);
        b.mint(lp2, 100000e18);
        q.mint(lp2, 100000e18);

        matchingEngine.addPair(
            address(b), address(q), 100e8, 1, address(b), ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        p = Pool(poolFactory.getPool(address(b), address(q)));

        vm.startPrank(lp1);
        b.approve(address(p), type(uint256).max);
        q.approve(address(p), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(lp2);
        b.approve(address(p), type(uint256).max);
        q.approve(address(p), type(uint256).max);
        vm.stopPrank();
    }

    function _mint(Pool p, address who, uint256 amount) internal returns (uint256 tokenId) {
        vm.prank(who);
        tokenId = pm.addLiquidity(address(p), 80e8, 120e8, 1000000, amount, amount);
    }

    /// Credit `amount` of quote-side fee to the pool position behind `tokenId`.
    /// creditFee is self-only-callable, so impersonate the pool exactly as
    /// Collect.t.sol does.
    function _creditQuoteFee(uint256 tokenId, uint256 amount) internal {
        (address pool, uint256 positionId) = pm.tokenPosition(tokenId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = positionId;
        uint256[] memory shares = new uint256[](1);
        shares[0] = 1;
        vm.prank(pool);
        Pool(pool).creditFee(ids, shares, false, amount);
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = a;
        out[1] = b;
    }

    function _ids(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory out) {
        out = new uint256[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    // ---- 1. happy path -------------------------------------------------

    function test_collectBatch_paysAllPositionsAndReturnsPerIdAmounts() public {
        uint256 t1 = _mint(poolA, lp1, 500e18);
        uint256 t2 = _mint(poolA, lp1, 500e18);
        _creditQuoteFee(t1, 10e18);
        _creditQuoteFee(t2, 25e18);

        uint256 before = token4.balanceOf(lp1);

        vm.prank(lp1);
        (uint256[] memory baseFees, uint256[] memory quoteFees) = pm.collectBatch(_ids(t1, t2), lp1);

        assertEq(quoteFees[0], 10e18, "id0 quote fee");
        assertEq(quoteFees[1], 25e18, "id1 quote fee");
        assertEq(baseFees[0], 0, "id0 base fee");
        assertEq(baseFees[1], 0, "id1 base fee");
        assertEq(token4.balanceOf(lp1) - before, 35e18, "recipient paid the sum");
    }

    function test_collectBatch_paysArbitraryRecipient() public {
        uint256 t1 = _mint(poolA, lp1, 500e18);
        _creditQuoteFee(t1, 7e18);

        uint256 before = token4.balanceOf(booker);

        vm.prank(lp1);
        pm.collectBatch(_ids(t1), booker);

        assertEq(token4.balanceOf(booker) - before, 7e18, "named recipient paid");
    }

    // ---- 2/3. skipping -------------------------------------------------

    function test_collectBatch_skipsRetiredPositionAndStillPaysLiveOnes() public {
        uint256 retired = _mint(poolA, lp1, 500e18);
        uint256 live = _mint(poolA, lp1, 500e18);

        // Drain principal; with zero fees owed the position retires itself.
        vm.prank(lp1);
        pm.removeLiquidity(retired, 500e18, 500e18, lp1);
        (address pool, uint256 pid) = pm.tokenPosition(retired);
        assertFalse(IPool(pool).getPosition(pid).active, "precondition: position retired");

        _creditQuoteFee(live, 12e18);

        vm.prank(lp1);
        (, uint256[] memory quoteFees) = pm.collectBatch(_ids(retired, live), lp1);

        assertEq(quoteFees[0], 0, "retired id reports zero");
        assertEq(quoteFees[1], 12e18, "live id still paid");
    }

    function test_collectBatch_skipsLivePositionOwingNothing() public {
        uint256 t1 = _mint(poolA, lp1, 500e18);

        vm.prank(lp1);
        (uint256[] memory baseFees, uint256[] memory quoteFees) = pm.collectBatch(_ids(t1), lp1);

        assertEq(baseFees[0], 0);
        assertEq(quoteFees[0], 0);
    }

    // ---- 4. auth -------------------------------------------------------

    function test_collectBatch_revertsWhenAnyIdIsNotCallers() public {
        uint256 mine = _mint(poolA, lp1, 500e18);
        uint256 theirs = _mint(poolA, lp2, 500e18);
        _creditQuoteFee(mine, 10e18);
        _creditQuoteFee(theirs, 10e18);

        uint256 before = token4.balanceOf(lp1);

        vm.prank(lp1);
        vm.expectRevert(
            abi.encodeWithSelector(IPositionManager.NotOwnerOrApproved.selector, theirs, lp1)
        );
        pm.collectBatch(_ids(mine, theirs), lp1);

        assertEq(token4.balanceOf(lp1), before, "no partial claim survives the revert");
    }

    function test_collectBatch_approvedOperatorCanClaimForHolder() public {
        uint256 t1 = _mint(poolA, lp1, 500e18);
        _creditQuoteFee(t1, 9e18);

        vm.prank(lp1);
        pm.setApprovalForAll(booker, true);

        uint256 before = token4.balanceOf(lp1);

        vm.prank(booker);
        pm.collectBatch(_ids(t1), lp1);

        assertEq(token4.balanceOf(lp1) - before, 9e18, "operator claimed to holder");
    }

    // ---- 5. the cap ----------------------------------------------------

    function test_collectBatch_revertsAboveMaxBatch() public {
        uint256[] memory ids = new uint256[](MAX_CLAIM_BATCH + 1);
        for (uint256 i = 0; i < ids.length; i++) {
            ids[i] = _mint(poolA, lp1, 1e18);
        }

        vm.prank(lp1);
        vm.expectRevert(
            abi.encodeWithSelector(IPositionManager.TooManyPositions.selector, MAX_CLAIM_BATCH + 1)
        );
        pm.collectBatch(ids, lp1);
    }

    function test_collectBatch_succeedsAtExactlyMaxBatch() public {
        uint256[] memory ids = new uint256[](MAX_CLAIM_BATCH);
        for (uint256 i = 0; i < ids.length; i++) {
            ids[i] = _mint(poolA, lp1, 1e18);
            _creditQuoteFee(ids[i], 1e18);
        }

        uint256 before = token4.balanceOf(lp1);

        vm.prank(lp1);
        pm.collectBatch(ids, lp1);

        assertEq(token4.balanceOf(lp1) - before, MAX_CLAIM_BATCH * 1e18, "all paid at the cap");
    }

    // ---- 7. cross-pool -------------------------------------------------

    function test_collectBatch_acrossPoolsWithDifferentTokensDoesNotMixThem() public {
        uint256 inA = _mint(poolA, lp1, 500e18);
        uint256 inB = _mint(poolB, lp1, 500e18);
        _creditQuoteFee(inA, 10e18);
        _creditQuoteFee(inB, 3e18);

        uint256 beforeA = token4.balanceOf(lp1);
        uint256 beforeB = token6.balanceOf(lp1);

        vm.prank(lp1);
        (, uint256[] memory quoteFees) = pm.collectBatch(_ids(inA, inB), lp1);

        assertEq(quoteFees[0], 10e18, "pool A amount");
        assertEq(quoteFees[1], 3e18, "pool B amount");
        assertEq(token4.balanceOf(lp1) - beforeA, 10e18, "pool A token paid exactly its own fee");
        assertEq(token6.balanceOf(lp1) - beforeB, 3e18, "pool B token paid exactly its own fee");
    }

    // ---- 8/9. edge cases -----------------------------------------------

    function test_collectBatch_duplicateIdIsNoOpOnSecondOccurrence() public {
        uint256 t1 = _mint(poolA, lp1, 500e18);
        _creditQuoteFee(t1, 10e18);

        uint256 before = token4.balanceOf(lp1);

        vm.prank(lp1);
        (, uint256[] memory quoteFees) = pm.collectBatch(_ids(t1, t1), lp1);

        assertEq(quoteFees[0], 10e18, "first occurrence claims");
        assertEq(quoteFees[1], 0, "second occurrence claims nothing");
        assertEq(token4.balanceOf(lp1) - before, 10e18, "paid exactly once");
    }

    function test_collectBatch_emptyArrayReturnsEmptyAndDoesNotRevert() public {
        uint256[] memory none = new uint256[](0);

        vm.prank(lp1);
        (uint256[] memory baseFees, uint256[] memory quoteFees) = pm.collectBatch(none, lp1);

        assertEq(baseFees.length, 0);
        assertEq(quoteFees.length, 0);
    }

    // ---- 10. the constant is measured, not asserted ---------------------

    /// The cap exists so an over-large batch fails with TooManyPositions rather
    /// than as an out-of-gas carrying zero return data (see
    /// test/swap/PoC_EstimateGasOnly.t.sol). That is only true if a full batch
    /// actually fits a wallet-realistic budget -- which this measures.
    function test_collectBatch_fullBatchFitsWalletGasBudget() public {
        uint256[] memory ids = new uint256[](MAX_CLAIM_BATCH);
        for (uint256 i = 0; i < ids.length; i++) {
            ids[i] = _mint(poolA, lp1, 1e18);
            _creditQuoteFee(ids[i], 1e18);
        }

        vm.prank(lp1);
        uint256 g0 = gasleft();
        pm.collectBatch(ids, lp1);
        uint256 used = g0 - gasleft();

        emit log_named_uint("collectBatch gas at MAX_CLAIM_BATCH", used);
        emit log_named_uint("gas per position", used / MAX_CLAIM_BATCH);

        assertLt(used, 2_000_000, "a full batch must fit the budget a wallet will offer");
    }
}
