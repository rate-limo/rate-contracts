// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandBaseSetup} from "./BandBaseSetup.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {IBandPool} from "../../src/swap/interfaces/IBandPool.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";

/**
 * Who is allowed to call `BandPool.collect`?
 *
 * It used to be everyone. v1's `collect` was `public` because `removeLiquidity` called
 * it internally, and public made it externally reachable with a caller-supplied
 * `recipient` -- so any address could claim any position's vested fees to itself. The
 * manager's own `collect` checked `onlyOwnerOrApproved`, but that gates the intended
 * path, and an intended path is not an access control: pools are discoverable through
 * `poolFactory.getPool` and every pool event carries the position's id, so sweeping
 * every position in every pool was a loop.
 *
 * v2 makes every position call on the pool `onlyPositionManager`. These run against the
 * real stack rather than a stub, because the claim they make is about who `msg.sender`
 * is at a real contract boundary.
 */
contract BandCollectAuthTest is BandBaseSetup {
    address internal attacker = address(0xBADBAD);

    function setUp() public override {
        super.setUp();
        // The real engine ships poolFeeShare = 0, so no LP fee accrues until an
        // operator sets it. Half to the LPs, which is what makes these tests about
        // authorisation rather than about the fee policy.
        matchingEngine.setPoolFeeShare(50000000);
    }

    function _mint(uint8[] memory bands) internal returns (uint256 tokenId) {
        vm.startPrank(lp1);
        token1.approve(address(positionManager), type(uint256).max);
        token2.approve(address(positionManager), type(uint256).max);
        uint256[] memory base = new uint256[](bands.length);
        for (uint256 i = 0; i < bands.length; i++) {
            base[i] = 1_000e18;
        }
        (tokenId,) = positionManager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: base,
                quoteAmounts: new uint256[](bands.length),
                minShares: new uint128[](bands.length),
                recipient: lp1,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    /// What `collect` would pay: owed plus every band's vested pending.
    function _claimable(uint256 tokenId) internal view returns (uint256 cb, uint256 cq) {
        (IBandPool.BandView[] memory held, uint256 ob, uint256 oq) = pool.positionView(tokenId);
        cb = ob;
        cq = oq;
        for (uint256 i = 0; i < held.length; i++) {
            cb += held[i].vestedBase;
            cq += held[i].vestedQuote;
        }
    }

    /// Deposit through the manager, trade against the band, walk past maturity so the
    /// vesting ramp is not what limits the payout.
    function _accruedPosition() internal returns (uint256 tokenId) {
        uint8[] memory bands = new uint8[](1);
        tokenId = _mint(bands);
        _buy(trader1, 10_000e18);
        vm.warp(block.timestamp + 365 days);
        assertEq(positionManager.poolOf(tokenId), address(pool), "token maps to this pool");
    }

    function test_collectRevertsForAnyoneButThePositionManager() public {
        uint256 tokenId = _accruedPosition();

        (uint256 owedBase, uint256 owedQuote) = _claimable(tokenId);
        assertTrue(owedBase > 0 || owedQuote > 0, "the position accrued something worth stealing");
        assertEq(positionManager.balanceOf(attacker, tokenId), 0, "attacker owns no receipt");
        (IBandPool.BandView[] memory before,,) = pool.positionView(tokenId);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(BandPool.OnlyPositionManager.selector, attacker, address(positionManager))
        );
        pool.collect(tokenId, attacker);

        // Not merely blocked -- nothing moved. A revert that still advanced the
        // position's checkpoints would zero the LP out just as effectively.
        (uint256 stillBase, uint256 stillQuote) = _claimable(tokenId);
        assertEq(stillBase, owedBase, "the LP's base entitlement is untouched");
        assertEq(stillQuote, owedQuote, "the LP's quote entitlement is untouched");
        (IBandPool.BandView[] memory afterwards,,) = pool.positionView(tokenId);
        assertEq(keccak256(abi.encode(afterwards)), keccak256(abi.encode(before)));
    }

    /// The gate must not have closed the front door with it: the owner still claims.
    function test_theOwnerStillClaimsThroughTheManager() public {
        uint256 tokenId = _accruedPosition();
        (uint256 owedBase, uint256 owedQuote) = _claimable(tokenId);

        uint256 beforeBase = token1.balanceOf(lp1);
        uint256 beforeQuote = token2.balanceOf(lp1);

        vm.prank(lp1);
        positionManager.collect(tokenId, lp1);

        assertEq(token1.balanceOf(lp1) - beforeBase, owedBase, "owner received the base fees");
        assertEq(token2.balanceOf(lp1) - beforeQuote, owedQuote, "owner received the quote fees");
    }

    /// v1's batch path (`collectMany` over one token per band) is, in v2, one collect of a
    /// token holding both bands. It must pay both.
    function test_oneCollectClaimsEveryBandForItsOwner() public {
        uint8[] memory bands = new uint8[](2);
        bands[1] = 1;
        uint256 tokenId = _mint(bands);

        // Large enough to exhaust band 0 and walk into band 1: bands fill
        // tightest-first, so a swap sized for one band leaves the next with nothing
        // accrued and the collect has only one real leg to prove.
        _buy(trader1, 300_000e18);
        vm.warp(block.timestamp + 365 days);

        (IBandPool.BandView[] memory held,,) = pool.positionView(tokenId);
        assertGt(held[0].vestedBase, 0, "band 0 accrued");
        assertGt(held[1].vestedBase, 0, "band 1 accrued");

        uint256 beforeBase = token1.balanceOf(lp1);
        vm.prank(lp1);
        positionManager.collect(tokenId, lp1);

        assertEq(
            token1.balanceOf(lp1) - beforeBase, held[0].vestedBase + held[1].vestedBase, "both bands paid in one call"
        );
        (uint256 left,) = _claimable(tokenId);
        assertEq(left, 0, "everything is claimed");
    }

    /// A stranger cannot claim someone else's position through the manager either.
    function test_theManagerRejectsANonOwner() public {
        uint256 tokenId = _accruedPosition();
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IBandPositionManager.NotOwnerOrApproved.selector, attacker, tokenId)
        );
        positionManager.collect(tokenId, attacker);
    }
}
