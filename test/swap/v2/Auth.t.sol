// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {V2Base} from "./V2Base.sol";
import {BandPool} from "../../../src/swap/BandPool.sol";
import {IBandPositionManager} from "../../../src/swap/interfaces/IBandPositionManager.sol";

/**
 * Who may act on a position.
 *
 * Every mutation except `mint`/`mintSingleSided` is holder-or-approved-for-all, and the
 * holder is whoever holds the token NOW: ERC-1155 has no per-id owner, so the manager
 * tracks one, and these pin that it follows transfers and nothing else. The pool side is
 * `onlyPositionManager`, so the manager's check is the only one between a stranger and
 * somebody else's capital.
 */
contract V2AuthTest is V2Base {
    address internal operator = address(0x09E7A70);
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = _mintBase(alice, _b(0, 1), 1_000e18);
        token1.mint(operator, 1_000e18);
        token2.mint(operator, 1_000e18);
        token1.mint(stranger, 1_000e18);
        token2.mint(stranger, 1_000e18);
        _approveManager(operator);
        _approveManager(stranger);
    }

    function _notAllowed(address who) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IBandPositionManager.NotOwnerOrApproved.selector, who, uint256(1));
    }

    function _redistributeParams() internal view returns (IBandPositionManager.RedistributeParams memory) {
        return IBandPositionManager.RedistributeParams({
            tokenId: id,
            bands: _b(0, 1),
            targetBps: _bps2(7000, 3000),
            minSharesAfter: _mins(2),
            refundTo: alice,
            deadline: block.timestamp
        });
    }

    function _bps2(uint16 a, uint16 c) internal pure returns (uint16[] memory) {
        return _bps(a, c);
    }

    /// Every gated entry point, called as `who`. Each must revert NotOwnerOrApproved(who).
    function _expectAllRefused(address who) internal {
        vm.startPrank(who);
        vm.expectRevert(_notAllowed(who));
        positionManager.increaseLiquidity(id, _b(0), _u(1e18), _u(0), _mins(1), block.timestamp);
        vm.expectRevert(_notAllowed(who));
        positionManager.decreaseLiquidity(id, 10_000, 0, 0, who, block.timestamp);
        vm.expectRevert(_notAllowed(who));
        positionManager.decreaseBand(id, 0, type(uint128).max, 0, 0, who, block.timestamp);
        vm.expectRevert(_notAllowed(who));
        positionManager.moveLiquidity(id, 0, 1, 1e18, 0, who, block.timestamp);
        IBandPositionManager.RedistributeParams memory rp = _redistributeParams();
        rp.refundTo = who;
        vm.expectRevert(_notAllowed(who));
        positionManager.redistribute(rp);
        vm.expectRevert(_notAllowed(who));
        positionManager.collect(id, who);
        vm.expectRevert(_notAllowed(who));
        positionManager.burn(id);
        vm.stopPrank();
    }

    function test_id_isOne() public view {
        // The helpers below name token 1 in their expected errors.
        assertEq(id, 1);
    }

    function test_aStrangerIsRefusedEveryMutation() public {
        bytes32 before = keccak256(abi.encode(_held(id)));
        _expectAllRefused(stranger);
        assertEq(keccak256(abi.encode(_held(id))), before, "nothing moved");
    }

    function test_theHolderMayDoEach() public {
        vm.startPrank(alice);
        positionManager.increaseLiquidity(id, _b(0), _u(1e18), _u(0), _mins(1), block.timestamp);
        positionManager.moveLiquidity(id, 0, 1, 1e18, 0, alice, block.timestamp);
        positionManager.redistribute(_redistributeParams());
        positionManager.collect(id, alice);
        positionManager.decreaseBand(id, 0, 1e18, 0, 0, alice, block.timestamp);
        positionManager.decreaseLiquidity(id, 10_000, 0, 0, alice, block.timestamp);
        positionManager.burn(id);
        vm.stopPrank();
        assertEq(positionManager.balanceOf(alice, id), 0);
    }

    function test_anApprovedForAllOperatorMayDoEach() public {
        vm.prank(alice);
        positionManager.setApprovalForAll(operator, true);

        vm.startPrank(operator);
        positionManager.increaseLiquidity(id, _b(0), _u(1e18), _u(0), _mins(1), block.timestamp);
        positionManager.moveLiquidity(id, 0, 1, 1e18, 0, operator, block.timestamp);
        IBandPositionManager.RedistributeParams memory rp = _redistributeParams();
        rp.refundTo = operator;
        positionManager.redistribute(rp);
        positionManager.collect(id, operator);
        positionManager.decreaseBand(id, 0, 1e18, 0, 0, operator, block.timestamp);
        uint256 before = token1.balanceOf(operator);
        positionManager.decreaseLiquidity(id, 10_000, 0, 0, operator, block.timestamp);
        assertGt(token1.balanceOf(operator), before, "the operator chose the recipient");
        positionManager.burn(id);
        vm.stopPrank();
        // The burn takes the token from the HOLDER, not from the operator who called it.
        assertEq(positionManager.balanceOf(alice, id), 0);
    }

    function test_revokingTheOperatorRevokesItsPowers() public {
        vm.prank(alice);
        positionManager.setApprovalForAll(operator, true);
        vm.prank(alice);
        positionManager.setApprovalForAll(operator, false);
        _expectAllRefused(operator);
    }

    function test_theRightFollowsTheTokenAcrossATransfer() public {
        vm.prank(alice);
        positionManager.safeTransferFrom(alice, bob, id, 1, "");
        assertEq(positionManager.holderOf(id), bob, "holderOf follows the transfer");

        _expectAllRefused(alice);

        uint256 before = token1.balanceOf(bob);
        _decreaseAll(bob, id, 10_000);
        assertGt(token1.balanceOf(bob), before, "the new holder withdrew");
    }

    function test_holderOfFollowsABatchTransferAndABurn() public {
        uint256 other = _mintBase(alice, _b(2), 10e18);
        uint256[] memory ids = new uint256[](2);
        uint256[] memory ones = new uint256[](2);
        ids[0] = id;
        ids[1] = other;
        ones[0] = 1;
        ones[1] = 1;
        vm.prank(alice);
        positionManager.safeBatchTransferFrom(alice, bob, ids, ones, "");
        assertEq(positionManager.holderOf(id), bob);
        assertEq(positionManager.holderOf(other), bob);

        _decreaseAll(bob, other, 10_000);
        vm.prank(bob);
        positionManager.burn(other);
        assertEq(positionManager.holderOf(other), address(0), "a burnt token has no holder");
    }

    /// The pool trusts the manager and nobody else, for every position call.
    function test_thePoolRefusesEveryPositionCallFromAnyoneButTheManager() public {
        bytes memory err =
            abi.encodeWithSelector(BandPool.OnlyPositionManager.selector, stranger, address(positionManager));
        vm.startPrank(stranger);
        vm.expectRevert(err);
        pool.increase(id, _b(0), _u(1e18), _u(0));
        vm.expectRevert(err);
        pool.decrease(id, 10_000, stranger);
        vm.expectRevert(err);
        pool.decreaseBand(id, 0, 1, stranger);
        vm.expectRevert(err);
        pool.move(id, 0, 1, 1, stranger);
        vm.expectRevert(err);
        pool.collect(id, stranger);
        vm.stopPrank();
    }

    /**
     * FAILS against the current manager -- see the report.
     *
     * ERC-1155 lets anyone transfer ZERO of any id from themselves: the approval check
     * passes (from == sender) and the balance check passes (0 >= 0). The manager's
     * `_update` then writes `_holder[id] = to` for every id in the transfer, whatever the
     * value, so a zero-value self-transfer makes the caller the position's holder, and the
     * holder may withdraw everything to itself. The real owner keeps balance 1 and is
     * locked out.
     */
    function test_aZeroValueTransferDoesNotMakeTheSenderTheHolder() public {
        vm.prank(stranger);
        positionManager.safeTransferFrom(stranger, stranger, id, 0, "");

        assertEq(positionManager.holderOf(id), alice, "a zero-value transfer moved the holder");
        vm.prank(stranger);
        vm.expectRevert(_notAllowed(stranger));
        positionManager.decreaseLiquidity(id, 10_000, 0, 0, stranger, block.timestamp);
    }

    /// The batch form of the same transfer, for the same reason.
    function test_aZeroValueBatchTransferDoesNotMakeTheSenderTheHolder() public {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory zero = new uint256[](1);
        ids[0] = id;
        vm.prank(stranger);
        positionManager.safeBatchTransferFrom(stranger, stranger, ids, zero, "");
        assertEq(positionManager.holderOf(id), alice, "a zero-value batch transfer moved the holder");
    }
}
