// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Disperse} from "../../src/rewards/Disperse.sol";
import {MockToken} from "../../src/mock/MockToken.sol";

/// A token that keeps a slice of every transfer for itself, so a payout's recipient
/// receives less than the amount `transferFrom` was asked to move. Fee is paid by the
/// SENDER's balance (the realistic case): `from` drops by the full requested amount,
/// `to` gains only the net, and the difference is burned rather than routed anywhere,
/// which is enough to prove {Disperse} does not silently "fix" the shortfall.
contract FeeOnTransferMock is ERC20 {
    uint256 public constant FEE_BPS = 500; // 5%

    constructor() ERC20("FeeToken", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * FEE_BPS) / 10_000;
        // Two internal updates so `from` still drops by the FULL requested value --
        // the fee leaves the sender's balance, the recipient gets what remains.
        super._update(from, address(0xdEaD), fee);
        super._update(from, to, value - fee);
    }
}

contract DisperseTest is Test {
    Disperse internal disperse;
    MockToken internal token;

    address internal payer = address(0xA11CE);

    function setUp() public {
        disperse = new Disperse();
        token = new MockToken("Reward", "ITER", 18);
        token.mint(payer, 1_000_000e18);
        vm.prank(payer);
        token.approve(address(disperse), type(uint256).max);
    }

    /// keccak-derived, not `0x1000 + i`: sequential low addresses are mostly zero
    /// bytes, which undercounts calldata gas relative to real wallets.
    function _recipients(uint256 n) internal pure returns (address[] memory out) {
        out = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = address(uint160(uint256(keccak256(abi.encodePacked("recipient", i)))));
        }
    }

    function _flatAmounts(uint256 n, uint256 each) internal pure returns (uint256[] memory out) {
        out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = each;
        }
    }

    // ---------------------------------------------------------------- happy path ----

    function test_disperseToken_happyPath_paysEveryRecipient() public {
        address[] memory recipients = _recipients(3);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1e18;
        amounts[1] = 2e18;
        amounts[2] = 3e18;

        uint256 payerBefore = token.balanceOf(payer);

        vm.prank(payer);
        disperse.disperseToken(IERC20(address(token)), recipients, amounts);

        assertEq(token.balanceOf(recipients[0]), 1e18);
        assertEq(token.balanceOf(recipients[1]), 2e18);
        assertEq(token.balanceOf(recipients[2]), 3e18);
        assertEq(payerBefore - token.balanceOf(payer), 6e18, "payer funded every transfer directly");
    }

    function test_disperseToken_emitsOnePayoutEventPerRecipientAndOneBatchEvent() public {
        address[] memory recipients = _recipients(2);
        uint256[] memory amounts = _flatAmounts(2, 5e18);

        vm.expectEmit(true, true, true, true, address(disperse));
        emit Disperse.Dispersed(address(token), payer, recipients[0], 5e18);
        vm.expectEmit(true, true, true, true, address(disperse));
        emit Disperse.Dispersed(address(token), payer, recipients[1], 5e18);
        vm.expectEmit(true, true, false, true, address(disperse));
        emit Disperse.DispersedBatch(address(token), payer, 2, 10e18);

        vm.prank(payer);
        disperse.disperseToken(IERC20(address(token)), recipients, amounts);
    }

    // ---------------------------------------------------------------------- gas ----

    /// 200 recipients, one flat amount each. Logged rather than asserted against a
    /// constant -- the number to size a season-close batch against, not a snapshot to
    /// pin. `forge test --match-test test_disperseToken_gasFor200Recipients -vv` prints
    /// it.
    function test_disperseToken_gasFor200Recipients() public {
        uint256 n = 200;
        address[] memory recipients = _recipients(n);
        uint256[] memory amounts = _flatAmounts(n, 1e18);

        vm.prank(payer);
        uint256 g = gasleft();
        disperse.disperseToken(IERC20(address(token)), recipients, amounts);
        uint256 used = g - gasleft();

        console.log("total gas, 200 recipients:", used);
        console.log("gas per recipient:        ", used / n);

        assertEq(token.balanceOf(recipients[n - 1]), 1e18, "the last recipient was actually paid");
        // A sanity ceiling, not a snapshot: this is execution gas only (`gasleft()` inside
        // an already-running call), not the intrinsic + calldata cost a real transaction
        // also pays -- see the report for the transaction-level number and the batch-size
        // margin it implies. What this assertion actually catches is a regression that
        // would make 200 recipients cost multiples of today's per-recipient gas, not a
        // literal block-gas-limit check: no chain this repo targets has a 30M block limit
        // (RISE's is 1.5B), so this is deliberately loose.
        assertLt(used, 30_000_000, "200 recipients should not cost multiples of today's per-recipient gas");
    }

    // ------------------------------------------------------------------- reverts ----

    function test_disperseToken_revertsOnLengthMismatch() public {
        address[] memory recipients = _recipients(2);
        uint256[] memory amounts = _flatAmounts(3, 1e18);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(Disperse.LengthMismatch.selector, 2, 3));
        disperse.disperseToken(IERC20(address(token)), recipients, amounts);
    }

    function test_disperseToken_revertsOnEmptyBatch() public {
        address[] memory recipients = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        vm.prank(payer);
        vm.expectRevert(Disperse.EmptyBatch.selector);
        disperse.disperseToken(IERC20(address(token)), recipients, amounts);
    }

    function test_disperseToken_revertsOnZeroRecipient() public {
        address[] memory recipients = _recipients(2);
        recipients[1] = address(0);
        uint256[] memory amounts = _flatAmounts(2, 1e18);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(Disperse.ZeroRecipient.selector, 1));
        disperse.disperseToken(IERC20(address(token)), recipients, amounts);
    }

    function test_disperseToken_revertsOnZeroAmount() public {
        address[] memory recipients = _recipients(2);
        uint256[] memory amounts = _flatAmounts(2, 1e18);
        amounts[1] = 0;

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(Disperse.ZeroAmount.selector, 1));
        disperse.disperseToken(IERC20(address(token)), recipients, amounts);
    }

    /// The third transfer cannot be funded; the whole batch -- including the two that
    /// COULD have succeeded -- must revert, atomically, with no partial payout left
    /// behind for admin-service to reconcile.
    function test_disperseToken_revertsAtomicallyOnInsufficientAllowance() public {
        address underfunded = address(0xB0B);
        token.mint(underfunded, 1e18);
        vm.prank(underfunded);
        token.approve(address(disperse), 1e18); // exactly enough for one, not three

        address[] memory recipients = _recipients(3);
        uint256[] memory amounts = _flatAmounts(3, 1e18);

        vm.prank(underfunded);
        // Pinned to the SECOND transfer's exact revert (the 1e18 allowance covers only
        // the first of three), not a bare expectRevert(): this is what proves the first
        // transfer -- which alone would have fit the allowance -- was rolled back rather
        // than simply never attempted for an unrelated reason.
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(disperse), 0, 1e18)
        );
        disperse.disperseToken(IERC20(address(token)), recipients, amounts);

        // Nothing moved -- not even the first transfer, which alone would have fit
        // the allowance.
        assertEq(token.balanceOf(recipients[0]), 0, "no partial payout");
        assertEq(token.balanceOf(underfunded), 1e18, "payer's balance is untouched");
    }

    function test_disperseToken_revertsAtomicallyOnInsufficientBalance() public {
        address broke = address(0xC0DE);
        vm.prank(broke);
        token.approve(address(disperse), type(uint256).max);

        address[] memory recipients = _recipients(2);
        uint256[] memory amounts = _flatAmounts(2, 1e18);

        vm.prank(broke);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, broke, 0, 1e18)
        );
        disperse.disperseToken(IERC20(address(token)), recipients, amounts);
    }

    // ------------------------------------------------------------ fee-on-transfer ----

    /// Documents, rather than "fixes", the fee-on-transfer interaction: the recipient
    /// receives less than requested, the sender still pays the full requested amount
    /// (the fee comes out of THEIR balance, not out of thin air), and the event still
    /// reports the amount REQUESTED -- this contract never measures what arrived,
    /// because it never held the balance to measure against.
    function test_disperseToken_feeOnTransferToken_recipientReceivesLessThanRequested() public {
        FeeOnTransferMock feeToken = new FeeOnTransferMock();
        feeToken.mint(payer, 1_000e18);
        vm.prank(payer);
        feeToken.approve(address(disperse), type(uint256).max);

        address[] memory recipients = _recipients(1);
        uint256[] memory amounts = _flatAmounts(1, 100e18);

        uint256 payerBefore = feeToken.balanceOf(payer);

        vm.expectEmit(true, true, true, true, address(disperse));
        emit Disperse.Dispersed(address(feeToken), payer, recipients[0], 100e18);

        vm.prank(payer);
        disperse.disperseToken(IERC20(address(feeToken)), recipients, amounts);

        // The sender paid the full requested amount...
        assertEq(payerBefore - feeToken.balanceOf(payer), 100e18, "sender pays the full requested amount");
        // ...but the recipient received less than that, net of the token's own fee.
        assertEq(feeToken.balanceOf(recipients[0]), 95e18, "recipient nets 100e18 less the token's 5% fee");
        assertLt(feeToken.balanceOf(recipients[0]), amounts[0], "delivered less than requested, undocumented by design");
    }
}
