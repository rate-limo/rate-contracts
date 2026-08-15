#!/usr/bin/env bash
# Creates disposable launch, pool, matched-trade, and auction fixtures on a testnet.
#
# This is deliberately not called by deploy-exchange.sh or any mainnet deploy
# flow. The Solidity script enforces ALLOW_TEST_FIXTURES=true and a matching
# TEST_FIXTURE_CHAIN_ID before it can broadcast.
#
# Required env: RPC_URL, DEPLOYER_KEY, TEST_FIXTURE_CHAIN_ID,
# ASSET_GENERATOR, PRESALE_LAUNCH, LAUNCH_QUOTE.
# Optional env: TEST_TRADE_BASE_AMOUNT, TEST_TRADE_QUOTE_AMOUNT.
set -euo pipefail

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

ALLOW_TEST_FIXTURES=true \
  forge script script/launch/SeedTestLaunches.s.sol:SeedTestLaunches \
    --rpc-url "$RPC_URL" \
    --via-ir \
    --broadcast \
    --private-key "$DEPLOYER_KEY"
