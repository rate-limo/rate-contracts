/// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BatchExecutor} from "../../src/wallet/BatchExecutor.sol";
import {MockToken} from "../../src/mock/MockToken.sol";

/**
 * @dev The `msg.sender == address(this)` guard is the whole authorization for a
 *      contract that runs AS a user's account, so most of this file is about
 *      that one line. The rest pins atomicity, which is the property that makes
 *      a fee-plus-withdrawal safe as one transaction.
 *
 *      `vm.etch` puts the executor's code at an EOA's address, which is exactly
 *      what an EIP-7702 delegation does — so these tests exercise the real
 *      shape rather than a contract calling a contract.
 */
contract BatchExecutorTest is Test {
    BatchExecutor internal impl;
    MockToken internal token;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal feeWallet = makeAddr("feeWallet");
    address internal attacker = makeAddr("attacker");

    /// The delegated account: alice's EOA, running the executor's code.
    BatchExecutor internal aliceAccount;

    function setUp() public {
        impl = new BatchExecutor();
        token = new MockToken("Test USD", "TUSD", 6);

        // The 7702 delegation, simulated: alice's address now carries the code.
        vm.etch(alice, address(impl).code);
        aliceAccount = BatchExecutor(payable(alice));

        vm.deal(alice, 100 ether);
        token.mint(alice, 1_000_000e6);
    }

    function _call(address to, uint256 value, bytes memory data)
        internal
        pure
        returns (BatchExecutor.Call memory)
    {
        return BatchExecutor.Call({to: to, value: value, data: data});
    }

    /* ─────────────────────────── the guard ─────────────────────────── */

    function test_execute_revertsWhenCallerIsNotTheAccount() public {
        // The entire security model. Anyone able to reach `execute` on a
        // delegated account spends that account's funds, so this must hold for
        // every caller that is not the account itself.
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](1);
        calls[0] = _call(attacker, 1 ether, "");

        vm.prank(attacker);
        vm.expectRevert(BatchExecutor.NotSelf.selector);
        aliceAccount.execute(calls);

        assertEq(attacker.balance, 0, "attacker must not have drained anything");
        assertEq(alice.balance, 100 ether, "the account must be untouched");
    }

    function test_execute_revertsForEveryOtherCaller() public {
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](1);
        calls[0] = _call(bob, 1 ether, "");

        // Including addresses a naive owner check might have blessed.
        address[3] memory callers = [bob, feeWallet, address(this)];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(BatchExecutor.NotSelf.selector);
            aliceAccount.execute(calls);
        }
    }

    function testFuzz_execute_revertsForAnyCallerButSelf(address caller) public {
        vm.assume(caller != alice);
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](1);
        calls[0] = _call(bob, 1 wei, "");

        vm.prank(caller);
        vm.expectRevert(BatchExecutor.NotSelf.selector);
        aliceAccount.execute(calls);
    }

    /* ────────────────────── the withdrawal + fee case ────────────────────── */

    function test_execute_splitsNativeBetweenDestinationAndFeeWallet() public {
        // 0.01% of 10 ether, computed off chain and arriving as two calls.
        uint256 amount = 10 ether;
        uint256 fee = amount / 10_000;
        uint256 rest = amount - fee;

        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](2);
        calls[0] = _call(bob, rest, "");
        calls[1] = _call(feeWallet, fee, "");

        vm.prank(alice);
        aliceAccount.execute{value: 0}(calls);

        assertEq(bob.balance, rest, "destination");
        assertEq(feeWallet.balance, fee, "fee wallet");
        assertEq(bob.balance + feeWallet.balance, amount, "conservation");
    }

    function test_execute_splitsErc20WithNoApproval() public {
        // The property that made this shape win over a splitter contract: the
        // account is the caller, so it moves its own balance and no allowance
        // exists anywhere.
        uint256 amount = 1_000e6;
        uint256 fee = amount / 10_000;
        uint256 rest = amount - fee;

        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](2);
        calls[0] = _call(address(token), 0, abi.encodeCall(token.transfer, (bob, rest)));
        calls[1] = _call(address(token), 0, abi.encodeCall(token.transfer, (feeWallet, fee)));

        vm.prank(alice);
        aliceAccount.execute(calls);

        assertEq(token.balanceOf(bob), rest);
        assertEq(token.balanceOf(feeWallet), fee);
        assertEq(token.allowance(alice, address(impl)), 0, "no allowance should exist");
    }

    /* ─────────────────── many recipients, mixed assets ─────────────────── */

    function test_execute_paysManyRecipientsDifferentAmounts() public {
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](3);
        calls[0] = _call(bob, 1 ether, "");
        calls[1] = _call(carol, 2.5 ether, "");
        calls[2] = _call(feeWallet, 0.0035 ether, "");

        vm.prank(alice);
        aliceAccount.execute(calls);

        assertEq(bob.balance, 1 ether);
        assertEq(carol.balance, 2.5 ether);
        assertEq(feeWallet.balance, 0.0035 ether);
    }

    function test_execute_mixesNativeAndErc20InOneBatch() public {
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](2);
        calls[0] = _call(bob, 1 ether, "");
        calls[1] = _call(address(token), 0, abi.encodeCall(token.transfer, (carol, 500e6)));

        vm.prank(alice);
        aliceAccount.execute(calls);

        assertEq(bob.balance, 1 ether);
        assertEq(token.balanceOf(carol), 500e6);
    }

    /* ──────────────────────────── atomicity ──────────────────────────── */

    function test_execute_revertsEntirelyWhenALegFails() public {
        // The reason this exists at all. As two transactions the fee lands and
        // the withdrawal reverts, leaving the user charged and unpaid.
        uint256 tooMuch = token.balanceOf(alice) + 1;

        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](2);
        calls[0] = _call(bob, 1 ether, "");
        calls[1] = _call(address(token), 0, abi.encodeCall(token.transfer, (feeWallet, tooMuch)));

        vm.prank(alice);
        vm.expectRevert();
        aliceAccount.execute(calls);

        assertEq(bob.balance, 0, "the first leg must be rolled back");
        assertEq(alice.balance, 100 ether, "the account must be whole");
    }

    function test_execute_namesWhichLegFailed() public {
        // A bare "batch failed" leaves a caller unable to tell an insufficient
        // balance from a bad recipient — and this account has no wallet popup.
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](3);
        calls[0] = _call(bob, 1 ether, "");
        calls[1] = _call(carol, 1 ether, "");
        calls[2] =
            _call(address(token), 0, abi.encodeCall(token.transfer, (bob, type(uint256).max)));

        vm.prank(alice);
        try aliceAccount.execute(calls) {
            revert("expected a revert");
        } catch (bytes memory err) {
            assertEq(bytes4(err), BatchExecutor.CallFailed.selector, "wrong error");
        }
    }

    function test_execute_revertsOnAnEmptyBatch() public {
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](0);
        vm.prank(alice);
        vm.expectRevert(BatchExecutor.EmptyBatch.selector);
        aliceAccount.execute(calls);
    }

    /* ──────────────────────────── statelessness ──────────────────────────── */

    function test_executorHoldsNothingOfItsOwn() public {
        // No storage and no balance is what keeps a PERSISTENT delegation
        // defensible: there is nothing here to corrupt or to strand.
        assertEq(address(impl).balance, 0);
        assertEq(token.balanceOf(address(impl)), 0);
        assertEq(vm.load(address(impl), bytes32(0)), bytes32(0));
    }
}
