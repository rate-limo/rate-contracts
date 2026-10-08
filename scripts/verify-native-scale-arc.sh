#!/usr/bin/env bash
# Exercise the nativeScale path against the LIVE Arc deployment.
#
#   contracts/scripts/verify-native-scale-arc.sh
#
# ## Why this is a shell script and not a forge test
#
# It cannot be a forge test, and that is a property of Arc rather than a shortcut. Arc's
# USDC (0x3600…0000) delegates to an implementation that calls a chain-level precompile at
# 0x1800…, which no local EVM implements — Foundry returns StackUnderflow. `balanceOf`
# survives; `totalSupply()` does not, and `MatchingEngine.addPair` reads it while listing.
# A forge SCRIPT is no better: its body runs in forge's own EVM to record broadcasts, so it
# dies on the same call, and `--skip-simulation` does not help because that skips the
# on-chain pass, not the local execution of run(). `cast` estimates on the NODE, so it is
# the only thing that can drive these calls.
#
# `test/exchange/NativeERC20Arc.t.sol` pins the CHAIN facts this rests on (no deposit(),
# no withdraw(), balanceOf is the native balance floored to 6 decimals). This file covers
# what that one explicitly cannot: the ENGINE's behaviour against those facts.
#
# ## What it proves, and how
#
#   1. ERC-20 approve + transferFrom work through the engine, on the ordinary (non-WETH)
#      leg — a limit sell of EURC.
#   2. The native-in branch is taken. A bid spends quote = USDC = WETH(), so `_createOrder`
#      reaches `if (spend == WETH)`. Success alone proves the nativeScale branch ran: the
#      other branch calls IWETH.deposit(), which does not exist here and would revert.
#   3. `leftover -= amount * nativeScale` is arithmetically right. The order is sent with
#      DELIBERATE EXCESS native value; the refund is what the scale computes. A wrong scale
#      is off by twelve orders of magnitude and shows up immediately.
#   4. Settlement does not unwrap. The match pays USDC out through Orderbook._pay with
#      `unwrap == false`; had it taken the other branch it would call withdraw(), which
#      does not exist here, and the whole match would revert.
#
# Read-only checks abort before anything is broadcast. Every assertion is on a measured
# balance delta, not on the absence of an error.
set -euo pipefail
cd "$(dirname "$0")/.."

RPC="${ARC_RPC_URL:-https://rpc.testnet.arc.network}"
CHAIN_ID=5042002
USDC=0x3600000000000000000000000000000000000000

: "${DEPLOYER_KEY:?set DEPLOYER_KEY (contracts/.env)}"

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
note() { printf '\033[33m%s\033[0m\n' "$*"; }
FAILED=0
check() { # check <label> <actual> <expected>
  if [ "$2" = "$3" ]; then grn "  PASS  $1"; else red "  FAIL  $1"; red "        actual   $2"; red "        expected $3"; FAILED=1; fi
}
approx() { # approx <label> <actual> <expected> <tolerance>
  local d=$(( $2 > $3 ? $2 - $3 : $3 - $2 ))
  if [ "$d" -le "$4" ]; then grn "  PASS  $1"; else red "  FAIL  $1"; red "        actual   $2"; red "        expected $3 (±$4)"; FAILED=1; fi
}

# ── resolve from the registry, never hardcode ────────────────────────────────
reg() { node -e '
  const c = require("../packages/deployments/deployments.json").chains["'"$CHAIN_ID"'"].contracts;
  process.stdout.write(String(c["'"$1"'"].address));
'; }
ENGINE=$(reg matchingEngine)
DEP=$(cast wallet address --private-key "$DEPLOYER_KEY")

echo "engine   $ENGINE"
echo "account  $DEP"

# ── preflight: the chain must actually be what we think ──────────────────────
[ "$(cast chain-id --rpc-url "$RPC")" = "$CHAIN_ID" ] || { red "wrong chain"; exit 1; }
SCALE=$(cast call "$ENGINE" "nativeScale()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
WETH=$(cast call "$ENGINE" "WETH()(address)" --rpc-url "$RPC")
[ "$SCALE" != "0" ] || { red "nativeScale is 0 — this engine is not configured for a native ERC-20"; exit 1; }
echo "nativeScale $SCALE   WETH() $WETH"
[ "$(echo "$WETH" | tr 'A-Z' 'a-z')" = "$USDC" ] || { red "WETH() is not Arc USDC"; exit 1; }

# The pair to trade. Base is whatever the engine's factory listed first.
FACTORY=$(cast call "$ENGINE" "orderbookFactory()(address)" --rpc-url "$RPC" 2>/dev/null || reg orderbookFactory)
PAIR=$(cast call "$FACTORY" "allPairs(uint256)(address)" 0 --rpc-url "$RPC")
read -r BASE QUOTE <<<"$(cast call "$PAIR" "getBaseQuote()(address,address)" --rpc-url "$RPC" | tr '\n' ' ')"
echo "pair     $PAIR   base $BASE  quote $QUOTE"
[ "$(echo "$QUOTE" | tr 'A-Z' 'a-z')" = "$USDC" ] || { red "quote is not the native ERC-20; this script assumes it is"; exit 1; }

bal_native() { cast balance "$1" --rpc-url "$RPC"; }
bal_erc()    { cast call "$2" "balanceOf(address)(uint256)" "$1" --rpc-url "$RPC" | awk '{print $1}'; }
# gas actually paid by the last tx, in native wei
gas_cost() { node -e '
  const r = JSON.parse(process.argv[1]);
  process.stdout.write((BigInt(r.gasUsed) * BigInt(r.effectiveGasPrice)).toString());
' "$1"; }

PRICE=$(cast call "$PAIR" "lmp()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
echo "price    $PRICE (8dp)"
echo

# ═════ 1. ERC-20 approve + transferFrom, on the ordinary leg ═════════════════
echo "1. approve + transferFrom through the engine (limit sell of base)"
SELL_AMOUNT=2000000                      # 2.0 base at 6 decimals
cast send "$BASE" "approve(address,uint256)" "$ENGINE" "$SELL_AMOUNT" \
  --private-key "$DEPLOYER_KEY" --rpc-url "$RPC" >/dev/null
ALLOW=$(cast call "$BASE" "allowance(address,address)(uint256)" "$DEP" "$ENGINE" --rpc-url "$RPC" | awk '{print $1}')
check "approve set the allowance" "$ALLOW" "$SELL_AMOUNT"

BASE_BEFORE=$(bal_erc "$DEP" "$BASE")
cast send "$ENGINE" "limitSell((address,address,uint256,uint256,bool,uint32,address))" \
  "($BASE,$QUOTE,$PRICE,$SELL_AMOUNT,true,2,$DEP)" \
  --private-key "$DEPLOYER_KEY" --rpc-url "$RPC" >/dev/null
BASE_AFTER=$(bal_erc "$DEP" "$BASE")
check "transferFrom moved exactly the order amount" "$(( BASE_BEFORE - BASE_AFTER ))" "$SELL_AMOUNT"
ALLOW_AFTER=$(cast call "$BASE" "allowance(address,address)(uint256)" "$DEP" "$ENGINE" --rpc-url "$RPC" | awk '{print $1}')
check "allowance was consumed" "$ALLOW_AFTER" "0"
echo

# ═════ 2-3. the native-in branch and its arithmetic, on an order that RESTS ══
# The refund must be measured on a bid that does NOT cross. A crossing bid settles
# against the resting ask, and with one account on both sides -- and feeTo defaulting
# to the deployer -- the quote leaves and returns, netting to zero and asserting
# nothing. First attempt did exactly that.
echo "2. native-in bid that RESTS: spend == WETH() takes the nativeScale branch"
REST_PRICE=$(node -e 'process.stdout.write((BigInt(process.argv[1])*80n/100n).toString())' "$PRICE")
REST_AMOUNT=1080000                      # quote units, well clear of the dust floor
NEEDED=$(node -e 'process.stdout.write((BigInt(process.argv[1])*BigInt(process.argv[2])).toString())' "$REST_AMOUNT" "$SCALE")
EXCESS=500000000000000000                # 0.5 native, deliberately overpaid
VALUE=$(node -e 'process.stdout.write((BigInt(process.argv[1])+BigInt(process.argv[2])).toString())' "$NEEDED" "$EXCESS")
echo "   bid $REST_AMOUNT quote-units at $REST_PRICE (below the ask, so it rests)"
echo "   needs $NEEDED wei; sending $VALUE (excess $EXCESS)"

NAT_BEFORE=$(bal_native "$DEP")
RCPT=$(cast send "$ENGINE" "createOrder((address,address,bool,bool,uint32,uint256,uint256,uint32,address,bool,uint32,uint64))" \
  "($BASE,$QUOTE,true,true,0,$REST_PRICE,$REST_AMOUNT,3,$DEP,true,0,0)" \
  --value "$VALUE" --private-key "$DEPLOYER_KEY" --rpc-url "$RPC" --json)
STATUS=$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).status))' "$RCPT")
check "the order did NOT revert (so IWETH.deposit was never called)" "$STATUS" "0x1"

GAS=$(gas_cost "$RCPT")
NAT_AFTER=$(bal_native "$DEP")
SPENT=$(node -e 'process.stdout.write((BigInt(process.argv[1])-BigInt(process.argv[2])-BigInt(process.argv[3])).toString())' "$NAT_BEFORE" "$NAT_AFTER" "$GAS")
echo
echo "3. leftover -= amount * nativeScale  (the excess must come back)"
echo "   native delta net of gas: $SPENT"
approx "spent exactly amount x nativeScale, excess refunded" "$SPENT" "$NEEDED" 0
note "        a wrong scale is off by 1e12 here, not by a rounding step"
echo

# ═════ 4. settlement pays out without unwrapping ═════════════════════════════
echo "4. settlement paid out without unwrapping"
BUY_AMOUNT=$(node -e 'const a=BigInt(process.argv[1]),p=BigInt(process.argv[2]);process.stdout.write(((a*p)/100000000n).toString())' "$SELL_AMOUNT" "$PRICE")
XVALUE=$(node -e 'process.stdout.write((BigInt(process.argv[1])*BigInt(process.argv[2])).toString())' "$BUY_AMOUNT" "$SCALE")
BASE_BEFORE2=$(bal_erc "$DEP" "$BASE")
RCPT2=$(cast send "$ENGINE" "createOrder((address,address,bool,bool,uint32,uint256,uint256,uint32,address,bool,uint32,uint64))" \
  "($BASE,$QUOTE,true,true,0,$PRICE,$BUY_AMOUNT,3,$DEP,false,0,0)" \
  --value "$XVALUE" --private-key "$DEPLOYER_KEY" --rpc-url "$RPC" --json)
S2=$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).status))' "$RCPT2")
check "the crossing bid did NOT revert" "$S2" "0x1"
BASE_AFTER2=$(bal_erc "$DEP" "$BASE")
GOT=$(( BASE_AFTER2 - BASE_BEFORE2 ))
if [ "$GOT" -gt 0 ]; then
  grn "  PASS  the match settled and paid base out ($GOT units)"
  note "        settlement ran Orderbook._pay with unwrap == false; the other branch"
  note "        calls withdraw(), which does not exist here and would have reverted"
else
  red "  FAIL  nothing was filled -- cannot conclude anything about the settlement path"; FAILED=1
fi

echo
if [ "$FAILED" = "0" ]; then grn "all nativeScale checks passed against chain $CHAIN_ID"; else red "FAILURES above"; exit 1; fi
