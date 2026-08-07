#!/usr/bin/env bash
# deploy-exchange.sh — safe deployment script for MatchingLib + MatchingEngine
#
# Usage:
#   ./scripts/deploy-exchange.sh --chain <name> [--mode <mode>] [--dry-run]
#
# Modes:
#   full          Deploy MatchingLib first, then MatchingEngine (default for new chains)
#   lib-only      Deploy only MatchingLib and record its address
#   engine-only   Deploy only MatchingEngine using the already-saved MatchingLib address
#
# Chains:
#   base | fraxtal | rise | monad | somnia-mainnet | somnia-testnet |
#   megaeth | ink | story | ethereum
#
# Examples:
#   ./scripts/deploy-exchange.sh --chain base --mode full
#   ./scripts/deploy-exchange.sh --chain base --mode engine-only   # upgrade only
#   ./scripts/deploy-exchange.sh --chain base --mode full --dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOYMENTS_DIR="$SCRIPT_DIR/deployments"
LIB_PATH="src/exchange/libraries/MatchingLib.sol:MatchingLib"

mkdir -p "$DEPLOYMENTS_DIR"

# ── colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[info]${RESET}  $*"; }
success() { echo -e "${GREEN}[ok]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[warn]${RESET}  $*"; }
error()   { echo -e "${RED}[error]${RESET} $*" >&2; exit 1; }

# ── argument parsing ──────────────────────────────────────────────────────────
CHAIN=""
MODE="full"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chain)   CHAIN="$2";   shift 2 ;;
    --mode)    MODE="$2";    shift 2 ;;
    --dry-run) DRY_RUN=true; shift   ;;
    -h|--help)
      sed -n '/^# Usage:/,/^[^#]/p' "$0" | head -n -1 | sed 's/^# \?//'
      exit 0 ;;
    *) error "unknown argument: $1" ;;
  esac
done

[[ -z "$CHAIN" ]] && error "--chain is required. Run with --help for usage."

# ── chain config table ────────────────────────────────────────────────────────
# Format: SCRIPT_FILE:CONTRACT_NAME:RPC_ENV_VAR:DEPLOYER_KEY_ENV_VAR
declare -A CHAIN_CONFIG
CHAIN_CONFIG[base]="Base.s.sol:DeployExchangeMainnetContracts:BASE_RPC_URL:LINEA_TESTNET_DEPLOYER_KEY"
CHAIN_CONFIG[fraxtal]="Fraxtal.s.sol:DeployExchangeMainnetContracts:FRAXTAL_RPC_URL:LINEA_TESTNET_DEPLOYER_KEY"
CHAIN_CONFIG[rise]="RiseTestnet.s.sol:DeployExchangeMainnetContracts:RISE_RPC_URL:LINEA_TESTNET_DEPLOYER_KEY"
CHAIN_CONFIG[monad]="MonadTestnet.s.sol:DeployExchangeMainnetContracts:MONAD_RPC_URL:LINEA_TESTNET_DEPLOYER_KEY"
CHAIN_CONFIG[somnia-mainnet]="SomniaMainnet.s.sol:DeployExchangeMainnetContracts:SOMNIA_MAINNET_RPC_URL:LINEA_TESTNET_DEPLOYER_KEY"
CHAIN_CONFIG[somnia-testnet]="SomniaTestnet.s.sol:DeployExchangeMainnetContracts:SOMNIA_TESTNET_RPC_URL:LINEA_TESTNET_DEPLOYER_KEY"
CHAIN_CONFIG[megaeth]="MegaETHTestnet.s.sol:DeployExchangeMainnetContracts:MEGAETH_RPC_URL:LINEA_TESTNET_DEPLOYER_KEY"
CHAIN_CONFIG[ink]="InkSepolia.s.sol:DeployExchangeMainnetContracts:INK_RPC_URL:LINEA_TESTNET_DEPLOYER_KEY"
CHAIN_CONFIG[story]="Story.s.sol:DeployExchangeMainnetContracts:STORY_RPC_URL:LINEA_TESTNET_DEPLOYER_KEY"
CHAIN_CONFIG[ethereum]="Ethereum.s.sol:DeployexchangeMainnetsrc:ETHEREUM_RPC_URL:OUTSOURCING_DEPLOYER_KEY"

[[ -z "${CHAIN_CONFIG[$CHAIN]+x}" ]] && error "unknown chain '$CHAIN'. Valid: ${!CHAIN_CONFIG[*]}"

IFS=':' read -r SCRIPT_FILE CONTRACT_NAME RPC_ENV DEPLOYER_KEY_ENV <<< "${CHAIN_CONFIG[$CHAIN]}"
FORGE_SCRIPT_PATH="script/exchange/$SCRIPT_FILE"
DEPLOYMENTS_FILE="$DEPLOYMENTS_DIR/$CHAIN.json"

# ── env / rpc validation ──────────────────────────────────────────────────────
check_env() {
  local var="$1"
  [[ -z "${!var:-}" ]] && error "env var $var is not set. Add it to your .env or export it."
}

if [[ "$DRY_RUN" == "false" ]]; then
  check_env "$RPC_ENV"
  check_env "$DEPLOYER_KEY_ENV"
fi

RPC_URL="${!RPC_ENV:-DRY_RUN_URL}"
DEPLOYER_KEY="${!DEPLOYER_KEY_ENV:-0x0000000000000000000000000000000000000000000000000000000000000001}"

# ── deployment state helpers ──────────────────────────────────────────────────
load_lib_address() {
  if [[ -f "$DEPLOYMENTS_FILE" ]]; then
    python3 -c "import json,sys; d=json.load(open('$DEPLOYMENTS_FILE')); print(d.get('matchingLib',''))" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

save_deployment() {
  local lib_addr="$1"
  local engine_addr="${2:-}"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Preserve existing values if not being updated
  local prev_lib="" prev_lib_ts="" prev_engine="" prev_engine_ts=""
  if [[ -f "$DEPLOYMENTS_FILE" ]]; then
    prev_lib=$(python3 -c "import json; d=json.load(open('$DEPLOYMENTS_FILE')); print(d.get('matchingLib',''))" 2>/dev/null || true)
    prev_lib_ts=$(python3 -c "import json; d=json.load(open('$DEPLOYMENTS_FILE')); print(d.get('matchingLibDeployedAt',''))" 2>/dev/null || true)
    prev_engine=$(python3 -c "import json; d=json.load(open('$DEPLOYMENTS_FILE')); print(d.get('matchingEngine',''))" 2>/dev/null || true)
    prev_engine_ts=$(python3 -c "import json; d=json.load(open('$DEPLOYMENTS_FILE')); print(d.get('matchingEngineDeployedAt',''))" 2>/dev/null || true)
  fi

  local final_lib="${lib_addr:-$prev_lib}"
  local final_lib_ts="${lib_addr:+$timestamp}"; final_lib_ts="${final_lib_ts:-$prev_lib_ts}"
  local final_engine="${engine_addr:-$prev_engine}"
  local final_engine_ts="${engine_addr:+$timestamp}"; final_engine_ts="${final_engine_ts:-$prev_engine_ts}"

  cat <<JSON
{
  "chain": "$CHAIN",
  "matchingLib": "$final_lib",
  "matchingLibDeployedAt": "$final_lib_ts",
  "matchingEngine": "$final_engine",
  "matchingEngineDeployedAt": "$final_engine_ts"
}
JSON
}

# ── forge output parser ───────────────────────────────────────────────────────
# Extracts the last "Contract Address: 0x..." from forge script output
parse_deployed_address() {
  grep -oE 'Contract Address: 0x[0-9a-fA-F]{40}' | tail -1 | awk '{print $3}'
}

# ── forge runner ─────────────────────────────────────────────────────────────
run_forge() {
  local label="$1"; shift
  local cmd=("$@")

  >&2 echo ""
  >&2 echo -e "${BOLD}━━━ $label ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  >&2 echo -e "${CYAN}CMD:${RESET} ${cmd[*]}"
  >&2 echo ""

  if [[ "$DRY_RUN" == "true" ]]; then
    >&2 warn "(dry-run) skipping actual execution"
    echo "0xDRYRUN000000000000000000000000000000000000"
    return 0
  fi

  local output
  output=$("${cmd[@]}" 2>&1 | tee /dev/stderr)
  echo "$output" | parse_deployed_address
}

# ── main workflow ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   MatchingEngine Deployment — $CHAIN$(printf '%*s' $((30 - ${#CHAIN})) '')║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
echo ""
info "Chain:   $CHAIN"
info "Mode:    $MODE"
info "Script:  $FORGE_SCRIPT_PATH:$CONTRACT_NAME"
info "RPC env: $RPC_ENV"
[[ "$DRY_RUN" == "true" ]] && warn "DRY RUN — no transactions will be broadcast"
echo ""

LIB_ADDRESS=$(load_lib_address)

# ── mode: lib-only or full ────────────────────────────────────────────────────
if [[ "$MODE" == "lib-only" || "$MODE" == "full" ]]; then
  if [[ -n "$LIB_ADDRESS" && "$MODE" == "full" ]]; then
    warn "MatchingLib already recorded at $LIB_ADDRESS for chain '$CHAIN'"
    warn "Skipping lib deployment. Use --mode lib-only to force a fresh deploy."
    warn "Continuing to engine deployment with existing lib address..."
  else
    info "Deploying MatchingLib..."
    LIB_ADDRESS=$(run_forge "Deploy MatchingLib" \
      forge script "$FORGE_SCRIPT_PATH:DeployMatchingLib" \
      --rpc-url "$RPC_URL" \
      --broadcast \
      --private-key "$DEPLOYER_KEY")

    if [[ -z "$LIB_ADDRESS" || "$LIB_ADDRESS" == "0xDRYRUN"* ]]; then
      [[ "$DRY_RUN" == "false" ]] && error "Failed to parse MatchingLib address from forge output"
      LIB_ADDRESS="0xDRYRUN_MATCHINGLIB_00000000000000000000"
    fi

    success "MatchingLib deployed at: $LIB_ADDRESS"

    # Persist immediately — engine deploy failure won't lose the lib address
    save_deployment "$LIB_ADDRESS" "" > "$DEPLOYMENTS_FILE"
    success "Saved lib address to $DEPLOYMENTS_FILE"
  fi

  [[ "$MODE" == "lib-only" ]] && { success "Done (lib-only mode)."; exit 0; }
fi

# ── mode: engine-only or full ─────────────────────────────────────────────────
if [[ "$MODE" == "engine-only" || "$MODE" == "full" ]]; then
  if [[ -z "$LIB_ADDRESS" ]]; then
    error "No MatchingLib address recorded for chain '$CHAIN'.\n       Run with --mode lib-only first, or --mode full for a fresh deploy."
  fi

  info "Deploying MatchingEngine (linked to MatchingLib @ $LIB_ADDRESS)..."

  ENGINE_ADDRESS=$(run_forge "Deploy MatchingEngine" \
    forge script "$FORGE_SCRIPT_PATH:$CONTRACT_NAME" \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --libraries "$LIB_PATH:$LIB_ADDRESS" \
    --private-key "$DEPLOYER_KEY")

  if [[ -z "$ENGINE_ADDRESS" || "$ENGINE_ADDRESS" == "0xDRYRUN"* ]]; then
    [[ "$DRY_RUN" == "false" ]] && warn "Could not parse MatchingEngine address from forge output (proxy deploy?)"
    ENGINE_ADDRESS="0xDRYRUN_MATCHINGENGINE_0000000000000000"
  fi

  success "MatchingEngine deployed at: $ENGINE_ADDRESS"

  save_deployment "$LIB_ADDRESS" "$ENGINE_ADDRESS" > "$DEPLOYMENTS_FILE"
  success "Saved addresses to $DEPLOYMENTS_FILE"
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ Deployment Summary ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  Chain:          ${BOLD}$CHAIN${RESET}"
echo -e "  MatchingLib:    ${GREEN}$LIB_ADDRESS${RESET}"
[[ "$MODE" != "lib-only" ]] && echo -e "  MatchingEngine: ${GREEN}$ENGINE_ADDRESS${RESET}"
echo -e "  Deployments:    $DEPLOYMENTS_FILE"
echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo -e "  • Verify on explorer: cast code \$ADDRESS --rpc-url \$$RPC_ENV"
echo -e "  • For proxy upgrade, pass: --libraries $LIB_PATH:\$LIB_ADDRESS"
echo ""
