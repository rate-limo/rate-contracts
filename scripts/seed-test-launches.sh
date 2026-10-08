#!/usr/bin/env bash
# Creates disposable launch, pool, two-sided-trade, and auction fixtures on a testnet.
#
# This is deliberately not called by deploy-exchange.sh or any mainnet deploy
# flow. The Solidity script enforces ALLOW_TEST_FIXTURES=true and a matching
# TEST_FIXTURE_CHAIN_ID before it can broadcast.
#
# The pair it launches is traded BOTH WAYS, ten times by default: a buy-only
# fixture emits nothing but `isBid = false` matches, so the venue renders a coin
# that has only ever been bought.
#
# Required env: RPC_URL, DEPLOYER_KEY, TEST_FIXTURE_CHAIN_ID,
# ASSET_GENERATOR, PRESALE_LAUNCH, LAUNCH_QUOTE.
# Optional env: TEST_TRADES_PER_PAIR (default 10), TEST_TRADE_BASE_AMOUNT
# (one sell), TEST_TRADE_QUOTE_AMOUNT (one buy), TEST_BOOK_ASK_BASE_AMOUNT and
# TEST_BOOK_BID_QUOTE_AMOUNT (depth rested on each side).
set -euo pipefail

# Tempo fixtures need a Foundry that can execute TIP-20 (>= 1.8.5).
if [[ "${TEST_FIXTURE_CHAIN_ID:-}" == 42431 ]]; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/require-tempo-foundry.sh"
  require_tempo_foundry
fi

: "${RPC_URL:?set RPC_URL to a testnet RPC endpoint}"
: "${DEPLOYER_KEY:?set DEPLOYER_KEY to the testnet fixture creator key}"
: "${TEST_FIXTURE_CHAIN_ID:?set TEST_FIXTURE_CHAIN_ID to the target testnet chain id}"
: "${ASSET_GENERATOR:?set ASSET_GENERATOR to the deployed AssetGenerator}"
: "${PRESALE_LAUNCH:?set PRESALE_LAUNCH to the deployed PresaleLaunch}"
: "${LAUNCH_QUOTE:?set LAUNCH_QUOTE to an enabled testnet quote token}"

cd "$(dirname "$0")/.."

# ── registry check ────────────────────────────────────────────────────────────
# Fixtures seeded against a superseded generation are dead on arrival: the
# indexer watches the addresses in deployments.json, so a launch created on a
# replaced AssetGenerator is never picked up and the gas is simply spent. That
# failure is silent — the broadcast succeeds, the transactions land, and the UI
# stays empty — so it is worth a comparison here rather than a debugging session
# afterwards.
#
# Advisory when the registry has no entry for this chain (local anvil is a real
# case), refusal only on a genuine disagreement. SEED_SKIP_REGISTRY_CHECK=true
# is the deliberate override, for seeding a deployment on purpose before it has
# been synced.
registry_address() {
  node -e '
    const [file, chainId, key] = process.argv.slice(1);
    try {
      const c = require(file).chains?.[chainId]?.contracts?.[key];
      process.stdout.write(c?.address ?? "");
    } catch { process.stdout.write(""); }
  ' "$(pwd)/../packages/deployments/deployments.json" "$TEST_FIXTURE_CHAIN_ID" "$1" 2>/dev/null || true
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

check_against_registry() {
  local key="$1" given="$2" expected
  expected="$(registry_address "$key")"
  if [ -z "$expected" ]; then
    echo "note: deployments.json has no $key for chain $TEST_FIXTURE_CHAIN_ID — not checked" >&2
    return 0
  fi
  if [ "$(lower "$expected")" != "$(lower "$given")" ]; then
    echo "" >&2
    echo "refusing to seed: $key does not match the current deployment." >&2
    echo "  you passed : $given" >&2
    echo "  registry   : $expected" >&2
    echo "" >&2
    echo "Fixtures created against a superseded contract are never indexed." >&2
    echo "Run packages/deployments/scripts/sync-deployment.mjs after a redeploy," >&2
    echo "or set SEED_SKIP_REGISTRY_CHECK=true if this is deliberate." >&2
    return 1
  fi
}

if [ "${SEED_SKIP_REGISTRY_CHECK:-false}" != "true" ]; then
  check_against_registry assetGenerator "$ASSET_GENERATOR"
  check_against_registry presaleLaunch "$PRESALE_LAUNCH"
fi

# NO --via-ir. It was here from this script's first commit and stopped working:
# `forge build --via-ir` now fails project-wide with "Variable expr_mpos is 1 too
# deep in the stack" somewhere in MatchingLib, so the seed could not compile at
# all — which reads as a broken seed rather than a compiler pipeline this project
# does not otherwise use. Confirmed pre-existing on 2026-09-24 by reverting an
# unrelated change and rebuilding: identical error.
#
# The legacy pipeline is what foundry.toml configures, what CI runs and what every
# deployed contract was built with (contracts/CLAUDE.md: "via_ir is deliberately
# UNSET and must stay that way"), and this script compiles and broadcasts fine on
# it. If a future edit to the seed genuinely needs --via-ir for its own stack,
# fix the stack instead — turning the flag back on re-breaks the whole script the
# moment src/ drifts again.
# --gas-estimate-multiplier: NOT padding, and not optional against a fresh
# deployment. Every transaction of this script failed OutOfGas on RISE on
# 2026-09-27, inside `BandPool._anchor()`:
#
#   twap(300) [staticcall] -> [Revert] InsufficientHistory(uint32,uint32)
#                          -> [OutOfGas]
#
# That revert is CAUGHT -- a pair with no trades yet has no TWAP, so the anchor
# falls back to seedPrice. But forge estimates against a state where the TWAP
# answers cheaply, so the catch path and the fallback have no headroom and the
# transaction dies with a revert in the trace that is a red herring. The seed's
# whole job is the FIRST trades on a pair, so it is always in that state.
#
# SEED_EXTRA_FLAGS passes chain-specific forge flags. Tempo needs
# `--skip-simulation`: forge's local simulation prices storage like Ethereum
# (20k a slot, not Tempo's 250k), so only the node's own eth_estimateGas sizes
# a Tempo transaction correctly. Keep SEED_GAS_MULTIPLIER low there too -- the
# padded limit must stay under Tempo's 30M per-transaction cap.
#
# --slow sends one at a time and waits for each receipt. Arc rejects a whole
# batch outright (`txpool is full`) and the retry then aborts on a nonce that
# moved under it, leaving a broadcast record with hashes and no receipts.
ALLOW_TEST_FIXTURES=true \
  forge script script/launch/SeedTestLaunches.s.sol:SeedTestLaunches \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --slow \
    --gas-estimate-multiplier "${SEED_GAS_MULTIPLIER:-400}" \
    ${SEED_EXTRA_FLAGS:-} \
    --private-key "$DEPLOYER_KEY"
