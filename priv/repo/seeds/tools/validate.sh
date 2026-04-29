#!/usr/bin/env bash
# Validate every [x] in priv/repo/seeds/categories/*.txt — confirm
# each `[x] <id>` references a real id in priv/repo/seeds/categories.jsonl.
# Exits 1 on the first mismatch (so this can hook into CI later).
#
#   tools/validate.sh

set -euo pipefail
cd "$(dirname "$0")/../../../.."

DIR="priv/repo/seeds/categories"
JSONL="priv/repo/seeds/categories.jsonl"

valid_ids=$(jq -r 'select(.kind == "subcategory") | .id' "$JSONL" | sort -u)

bad=0
for file in "$DIR"/*.txt; do
  [ -s "$file" ] || continue
  chain=$(basename "$file" .txt)

  while IFS= read -r line; do
    # Match `<entry-id> [x] <unified-id>`
    if [[ "$line" =~ ^([0-9a-f]{8})\ \[x\]\ ([0-9a-f]{8})$ ]]; then
      eid="${BASH_REMATCH[1]}"
      uid="${BASH_REMATCH[2]}"
      if ! grep -q "^${uid}$" <<<"$valid_ids"; then
        echo "[$chain] $eid -> $uid : id not found in JSONL" >&2
        bad=$((bad + 1))
      fi
    fi
  done < "$file"
done

if [ "$bad" -gt 0 ]; then
  echo "FAIL — $bad invalid mapping(s)" >&2
  exit 1
fi

echo "OK — all [x] mappings resolve to a real subcategory id."
