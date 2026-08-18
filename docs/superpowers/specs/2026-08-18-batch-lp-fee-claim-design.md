# Batch LP fee claim

**Date:** 2026-08-18
**Status:** Implemented
**Component:** `src/swap/PositionManager.sol`

## Problem

`PositionManager.collect(tokenId, recipient)` claims accrued fees for exactly one
position. An LP quoting N price ranges holds N ERC-1155 position tokens and must
send N transactions — N wallet prompts, N signatures — to collect what is
economically a single action.

## Goal

One transaction claims fees across many positions the caller already controls.

Explicitly out of scope: batching `removeLiquidity`, batching `adjustPosition`,
claiming on behalf of other holders, and any keeper/auto-compounder entry point.

## Interface

```solidity
uint256 private constant MAX_CLAIM_BATCH = 30;

error TooManyPositions(uint256 count);

function collectBatch(uint256[] calldata tokenIds, address recipient)
    external
    returns (uint256[] memory baseFees, uint256[] memory quoteFees);
```

`baseFees[i]` and `quoteFees[i]` correspond to `tokenIds[i]`. Skipped entries
report `0, 0`.

## Behaviour

Per id, in order:

1. Reject unless `_isOwnerOrApproved(msg.sender, tokenId)`.
2. Read the position via `IPool.getPosition`.
3. Skip if the position is retired (`!active`) or owes nothing on both sides.
4. Otherwise `IPool.collect(positionId, recipient)` and record the amounts.

### Why fees are not summed

Positions in one batch may live in different pools, and each pool has its own
`base`/`quote` token addresses. A `(totalBase, totalQuote)` return would add
unrelated tokens together and report a meaningless figure. Per-id arrays keep
the mapping to `tokenIds[i]` explicit; the caller already knows which pool each
id belongs to.

### Why retired positions are skipped rather than reverting

`Pool._deactivateIfDead` retires a position once principal and fees are both
zero, but the ERC-1155 token id survives until the holder calls `burn`
separately. So "claim everything I hold" routinely includes ids whose
`Pool.collect` would revert `PositionDoesNotExist`. Reverting the batch would
make the common case fail and force offchain filtering.

Skipping is narrow by design: only "nothing to claim" is tolerated. An id the
caller does not control still reverts the whole transaction.

### Why the batch is capped

Out-of-gas returns **zero bytes** of revert data. A frontend receives nothing to
decode and can only report a generic gas error — it cannot tell the user that a
smaller batch would succeed. This repo has already demonstrated the failure mode
in `test/swap/PoC_EstimateGasOnly.t.sol`, which asserts
`ret.length == 0, "revert data must be empty (out-of-gas), i.e. nothing to decode"`.

`TooManyPositions(count)` converts that silence into a decodable error. The
precedent is `MatchingEngine.maxMatches`, which reverts `TooManyMatches(n)`
rather than clamping.

The array length is chosen by the caller, not grown by an attacker, so the cap
is ergonomic rather than a security boundary. It is a hard constant, not an
owner-settable value: no admin knob, no extra storage slot.

## Error handling

| Case | Result |
|---|---|
| Caller lacks ownership/approval for any id | `NotOwnerOrApproved(tokenId, caller)`; whole batch reverts |
| Position retired (`!active`) | Skipped, reports `0, 0` |
| Position live, zero fees owed | Skipped, reports `0, 0` |
| `tokenIds.length > MAX_CLAIM_BATCH` | `TooManyPositions(len)`, before any work |
| Burned or unknown token id | Caught by the auth check (`_holder` is `address(0)`), so it reverts decodably rather than calling a codeless address |
| Duplicate id within one call | Second occurrence sees zero fees and is skipped |
| `recipient == address(0)` | Not validated, matching the existing single `collect`. See Open questions. |

No new event. `Pool.collect` already emits `FeeCollected(positionId, baseFee,
quoteFee)` per position, giving indexers per-id detail.

Reverts use plain `revert Error(...)`, matching `PositionManager`'s existing
style rather than the `selector.revertWith()` pattern used in `src/exchange`.

## Cost

Measured after implementation, via
`test_collectBatch_fullBatchFitsWalletGasBudget`:

| Figure | Value |
|---|---|
| Full batch of 30, all in one pool | 412,996 gas |
| Per position, warm | 13,766 gas |
| Single standalone `collect`, cold | 47,923 gas |

The per-position cost inside a batch is far below the standalone figure because
storage slots and token contracts are already warm after the first iteration.
13,766 is therefore a best case: every position in that measurement shares one
pool.

The constant holds at both bounds. Pessimistically, assuming every position sits
in a different cold pool and costs the full standalone 47,923, a 30-id batch is
1,437,690 gas — still inside the 2,000,000 that `PoC_EstimateGasOnly` treats as a
realistic wallet offer. So 30 is safe regardless of how the batch is distributed,
and there is room to raise it later on evidence.

`PositionManager` runtime size went from 10,952 to 11,762 bytes — `collectBatch`
costs ~810 bytes, leaving 12,814 of EIP-170 headroom. Unlike `MatchingEngine`
(166 bytes spare), size is not a constraint here.

## Testing

New file `test/swap/CollectBatch.t.sol`:

1. Claims across several positions, paying the recipient and returning per-id amounts.
2. Skips a retired position without reverting; live ids in the same call still pay.
3. Skips a live position owing zero fees, reporting `0, 0`.
4. Reverts `NotOwnerOrApproved` when any id is not the caller's, leaving no partial claim.
5. Reverts `TooManyPositions` at `MAX_CLAIM_BATCH + 1`; succeeds at exactly `MAX_CLAIM_BATCH`.
6. An operator approved via `setApprovalForAll` can batch on the holder's behalf.
7. Cross-pool batch over two pools with different token pairs: per-id amounts are
   correct and no cross-token summing occurs.
8. Duplicate id in one call is a no-op on its second occurrence.
9. Empty array returns empty arrays without reverting.
10. Gas: measure a full `MAX_CLAIM_BATCH` batch and assert it stays under
    2,000,000 gas, in the style of `PoC_UnboundedOrderQueue.t.sol`. This test is
    what justifies the constant. It logs the per-position cost so the figure is
    visible in CI rather than buried in this document.

All 12 tests pass; the full repo suite is 480 passing, 0 failing.

## Open questions

- **`recipient == address(0)`.** Unvalidated here to stay consistent with the
  existing single `collect`. Adding a guard to only the batch would be
  inconsistent; adding it to both changes existing behaviour. Deferred.
- **The value 30.** Resolved. Measurement shows a full batch costs 412,996 gas,
  and even the pessimistic all-cold-pools bound is 1.44M — both inside the 2M
  budget. 30 stands, with headroom to raise it if LPs ask for larger batches.
