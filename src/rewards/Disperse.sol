// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Disperse
 * @notice Pays a reward token to a batch of recipients, straight from the caller, in one
 * transaction.
 * @dev Every payout is `SafeERC20.safeTransferFrom(token, msg.sender, recipients[i],
 * amounts[i])` -- the caller's own balance and allowance fund every transfer directly, so
 * this contract never holds the token between calls and never needs a way to get it back
 * out. That is also the whole reentrancy story: there is no balance here for a reentrant
 * call to redirect and no shared mutable state for one to corrupt, so `ReentrancyGuard` is
 * omitted rather than applied defensively. A token whose transfer hook re-enters
 * {disperseToken} only spends ITS OWN caller's allowance on the reentrant call -- `from`
 * is read fresh as `msg.sender` on every call, so one call can never spend another's
 * approval.
 *
 * No owner, no admin, no upgrade path, no `receive`/`fallback`: this contract holds
 * nothing and configures nothing, so there is nothing here for a privileged role to do.
 * Season-close payout batches are expected to be run by whichever off-chain process
 * already computed the amounts (see `admin-service`); this contract's only job is making
 * the resulting transfers atomic and auditable from one receipt.
 *
 * @custom:security-contact security@iter.cx
 */
contract Disperse {
    using SafeERC20 for IERC20;

    /// @notice One payout landed.
    /// @param token The ERC-20 paid.
    /// @param from The caller who funded the payout.
    /// @param to The recipient.
    /// @param amount The amount requested for this recipient -- what `transferFrom` was
    /// asked to move, not necessarily what `to` received net of the token's own fee. See
    /// {disperseToken}'s NatSpec on fee-on-transfer tokens.
    event Dispersed(address indexed token, address indexed from, address indexed to, uint256 amount);

    /// @notice A whole batch landed. One event per call, so an indexer or admin-service
    /// can verify a payout by totaling `amount` across a receipt's `Dispersed` logs and
    /// checking it against `total` here, without tracking a balance this contract never
    /// holds.
    /// @param token The ERC-20 paid.
    /// @param from The caller who funded the batch.
    /// @param count Number of recipients paid.
    /// @param total Sum of every `amounts[i]` requested in the batch.
    event DispersedBatch(address indexed token, address indexed from, uint256 count, uint256 total);

    /// @notice `recipients` and `amounts` were not the same length.
    error LengthMismatch(uint256 recipientsLength, uint256 amountsLength);
    /// @notice The batch had no entries.
    error EmptyBatch();
    /// @notice `recipients[index]` was the zero address.
    error ZeroRecipient(uint256 index);
    /// @notice `amounts[index]` was zero.
    error ZeroAmount(uint256 index);

    /// @notice Pays `amounts[i]` of `token` to `recipients[i]` for every `i`, pulled
    /// directly from `msg.sender`.
    /// @dev Reverts the ENTIRE batch on the first problem -- a length mismatch, an empty
    /// batch, a zero recipient or amount, or `SafeERC20`'s own revert on insufficient
    /// allowance or balance -- so a payout is never partial; there is no partial-success
    /// state to reconcile after a failed call. The same is true of a revert this contract
    /// did not anticipate -- a blocklisted or paused recipient on `token`'s own side --
    /// except that error will not carry the failing index the way {ZeroRecipient} and
    /// {ZeroAmount} do; a caller that hits one has to bisect the batch to find it.
    ///
    /// Fee-on-transfer tokens are not specially handled: each transfer is a direct
    /// `transferFrom(msg.sender, recipients[i], amounts[i])`, so a token that burns or
    /// skims on transfer delivers `recipients[i]` less than `amounts[i]` -- exactly what a
    /// direct transfer from the caller would have delivered, and exactly what
    /// `Dispersed`/`DispersedBatch` report (the amount REQUESTED, not measured on
    /// arrival). This contract never custodies the token, so there is no balance here to
    /// diff before/after the way a contract receiving funds for itself would.
    /// @param token The ERC-20 to distribute.
    /// @param recipients Payees, in order. Must be the same length as `amounts`.
    /// @param amounts Amount to pay each recipient, in order, in `token`'s own units.
    function disperseToken(IERC20 token, address[] calldata recipients, uint256[] calldata amounts) external {
        uint256 length = recipients.length;
        if (length != amounts.length) revert LengthMismatch(length, amounts.length);
        if (length == 0) revert EmptyBatch();

        address from = msg.sender;
        uint256 total;
        for (uint256 i = 0; i < length; i++) {
            address to = recipients[i];
            uint256 amount = amounts[i];
            if (to == address(0)) revert ZeroRecipient(i);
            if (amount == 0) revert ZeroAmount(i);
            // Emitted before the transfer: this repo's convention is events-before-
            // interactions, and there is no state here a failed transfer could make this
            // log inconsistent with -- `safeTransferFrom` reverts the whole call (and so
            // this log) on failure, since Solidity discards logs from a reverted call.
            emit Dispersed(address(token), from, to, amount);
            token.safeTransferFrom(from, to, amount);
            total += amount;
        }
        emit DispersedBatch(address(token), from, length, total);
    }
}
