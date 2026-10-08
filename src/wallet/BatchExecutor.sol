/// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/**
 * @title BatchExecutor
 * @notice The code an EOA delegates to under EIP-7702 so it can execute several
 *         calls in ONE transaction.
 *
 * @dev ## What this is for
 *
 * An EOA does one call per transaction. That is the EVM, and it is why a
 * withdrawal that also pays a fee is two transactions today — with a window in
 * between where the first can land and the second revert, leaving the user
 * charged and unpaid.
 *
 * Under EIP-7702 (live since Pectra; both RISE and Arc report `requestsHash` on
 * their latest blocks) an EOA signs an authorization naming this contract, and
 * its code slot then points here. `execute` runs the list atomically: every call
 * lands or the transaction reverts.
 *
 * ## The authorization model IS the `msg.sender` check
 *
 * Once an EOA delegates here, this code runs AS that account — `address(this)`
 * is the EOA, and every call it makes spends the EOA's own funds. So the only
 * thing standing between a batch and anyone on the internet draining the
 * account is the guard on line one of `execute`:
 *
 *     if (msg.sender != address(this)) revert NotSelf();
 *
 * That is satisfied only when the EOA itself is the transaction's sender — i.e.
 * the holder of the key signed it. There is no owner variable, no role, no
 * allowlist, because there is nothing else that could be correct: the account's
 * key is the authority, exactly as it was before delegating.
 *
 * **Do not add a path that skips this check.** A sponsored-execution or
 * meta-transaction entry point is the obvious next request and it would need a
 * signature scheme of its own; bolting one onto this guard is how a delegate
 * becomes a drain.
 *
 * ## Deliberately minimal, immutable, and stateless
 *
 * A 7702 delegation PERSISTS: the code slot keeps pointing here until the
 * account authorizes something else. So a bug here is a permanent liability on
 * every account that ever delegated, with no further user action required.
 *
 * Everything follows from that. No storage — nothing to corrupt, and no
 * collision with whatever the account might delegate to next. No owner, no
 * upgrade path, no pause: each is a key that can be lost or stolen, protecting
 * a contract that holds nothing. No `receive`/`fallback` beyond what an EOA
 * already does. The whole surface is one external function.
 *
 * ## Multiple recipients, different amounts, mixed assets
 *
 * A `Call` is `{to, value, data}`, so one batch expresses:
 *   - native transfers — `{to: recipient, value: amount, data: ""}`
 *   - ERC-20 transfers — `{to: token, value: 0, data: transfer(recipient, amt)}`
 *   - any mix of the two, to any number of recipients, each its own amount.
 *
 * ERC-20 needs **no approval**: the EOA is the caller, moving its own balance.
 * That is the property a splitter contract cannot have, and the reason this
 * shape was chosen over one.
 *
 * ## What it does not do
 *
 * Enforce a fee. The split is computed off-chain (apps/web
 * `lib/wallet/withdrawSplit.ts`) and arrives as two calls. Putting the rate on
 * chain would mean a configurable recipient and rate — storage, an owner, an
 * upgrade path — every one of which is surface this contract exists to avoid.
 * Nothing here is trusted to be fair; it is trusted to do exactly what the key
 * holder signed.
 */
contract BatchExecutor {
    /// @notice One call in a batch.
    /// @param to The address to call. For an ERC-20 leg this is the TOKEN.
    /// @param value Native value to send with the call, in wei.
    /// @param data Calldata. Empty for a plain native transfer.
    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    /// @notice Emitted once per batch, not per call: the transaction hash already
    ///         identifies the batch, and an event per leg would cost gas to
    ///         restate what the token's own Transfer events say.
    event BatchExecuted(uint256 calls);

    /// @notice The caller is not the account this code is delegated to.
    error NotSelf();
    /// @notice An empty batch. Almost always a caller bug, and it would cost gas
    ///         to accomplish nothing.
    error EmptyBatch();
    /// @notice A call reverted. `index` is which one, `data` the raw revert.
    error CallFailed(uint256 index, bytes data);

    /**
     * @notice Execute every call, or revert.
     * @dev Atomicity is the whole point: a partial batch is the failure mode
     *      that makes a fee-plus-withdrawal unsafe as two transactions.
     *
     *      The revert reason of the failing leg is bubbled with its index. A
     *      bare "batch failed" would leave a caller unable to tell a token's
     *      insufficient-balance from a bad recipient, and this runs on an
     *      account with no wallet popup to surface either.
     * @param calls The calls to run, in order.
     */
    function execute(Call[] calldata calls) external payable {
        // The entire authorization. See the note above before touching it.
        if (msg.sender != address(this)) revert NotSelf();
        if (calls.length == 0) revert EmptyBatch();

        uint256 length = calls.length;
        for (uint256 i = 0; i < length;) {
            // No CEI ordering to preserve — this contract holds no state and no
            // balance of its own. Reentrancy reaches an account that is already
            // the caller, so a reentrant batch is just another batch the key
            // holder authorized; it can spend nothing extra.
            (bool ok, bytes memory ret) = calls[i].to.call{value: calls[i].value}(calls[i].data);
            if (!ok) revert CallFailed(i, ret);

            // Bounded by `calls.length`, which cannot overflow a uint256.
            unchecked {
                ++i;
            }
        }

        emit BatchExecuted(length);
    }
}
