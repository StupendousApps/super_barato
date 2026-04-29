#!/usr/bin/env bash
# AND-grep priv/repo/source/categories.jsonl by keyword, format output.
#
#   tools/search.sh yogur            # one keyword
#   tools/search.sh leche soya       # AND across both
#
# The JSONL ships a `search` field (lowercase + accent-stripped
# concatenation of name/path/keywords/cat_name), so input keywords
# are normalized via iconv before matching.

set -euo pipefail
cd "$(dirname "$0")/../../../.."

JSONL="priv/repo/source/categories.jsonl"

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <keyword> [<keyword>...]" >&2
  exit 2
fi

result=$(cat "$JSONL")
for kw in "$@"; do
  needle=$(echo "$kw" | tr '[:upper:]' '[:lower:]' | iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null || echo "$kw")
  result=$(echo "$result" | grep -i -- "$needle" || true)
done

if [ -z "$result" ]; then
  exit 0
fi

echo "$result" | jq -r '"\(.id)  \(.kind)  \(.path)  [\(.keywords // [] | join(", "))]"'
