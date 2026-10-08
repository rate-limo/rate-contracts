#!/usr/bin/env bash
# Tempo's launch contracts are COPIES: src/tempo/TempoAssetGenerator.sol and
# src/tempo/TempoAssetLaunchLib.sol duplicate src/asset/AssetGenerator.sol and
# src/asset/libraries/AssetLaunchLib.sol so that the chain-specific launch fee never
# touches the contracts every other chain runs. A copy that falls behind its original is
# a silent fork, so this compares each copy's body (from the contract's doc comment to
# the end, Tempo names mapped back) with the original's and requires the difference to
# be EXACTLY src/tempo/copies.expected.diff -- the `TEMPO:` hunks and nothing else.
#
#   scripts/check-tempo-copies.sh            check (CI)
#   scripts/check-tempo-copies.sh --update   rewrite the expected diff after a deliberate
#                                            change to a TEMPO hunk; review it like code
set -euo pipefail
cd "$(dirname "$0")/.."
expected=src/tempo/copies.expected.diff

actual=$(python3 - <<'PY'
import difflib, re
PAIRS = [
    ("src/asset/AssetGenerator.sol", "src/tempo/TempoAssetGenerator.sol", "contract AssetGenerator is"),
    ("src/asset/libraries/AssetLaunchLib.sol", "src/tempo/TempoAssetLaunchLib.sol", "library AssetLaunchLib"),
]
def body(text, decl):
    i = text.index(decl)
    return text[text.rindex("/**", 0, i):].splitlines()
for orig, copy, decl in PAIRS:
    c = open(copy).read()
    c = re.sub(r"\bTempoAssetLaunchLib\b", "AssetLaunchLib", c)
    c = re.sub(r"\bTempoAssetGenerator\b", "AssetGenerator", c)
    lines = difflib.unified_diff(body(open(orig).read(), decl), body(c, decl), orig, copy, n=1, lineterm="")
    for line in lines:
        # Hunk positions move whenever the original grows; only the content is pinned.
        print("@@" if line.startswith("@@") else line)
PY
)

if [[ "${1:-}" == --update ]]; then
  printf '%s\n' "$actual" > "$expected"
  echo "wrote $expected"
  exit 0
fi

if ! diff -u "$expected" <(printf '%s\n' "$actual"); then
  cat >&2 <<'MSG'

The Tempo copies no longer differ from their originals by exactly the TEMPO hunks.
  * An original changed: make the same change in src/tempo/ (Tempo* names).
  * A TEMPO hunk changed on purpose: run scripts/check-tempo-copies.sh --update and
    commit the new expected diff with it.
MSG
  exit 1
fi
echo "tempo copies in step with their originals"
