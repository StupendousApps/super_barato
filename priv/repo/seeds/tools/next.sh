#!/usr/bin/env bash
# Show everything needed to triage the next [ ] entry:
#
#   CHAIN       which chain we're working on
#   TARGET      the 3-line entry block (entry-id + status / count + path / slug)
#   LISTINGS    7 sample products from chain_listings tagged at that slug
#   CATEGORIES  candidate unified subcategories — search.sh seeded
#               with the path's leaf segment
#
# Without an argument, walks all chains in priority order and shows
# the first with [ ] entries left. Pass a chain name to pin to it.
#
#   tools/next.sh           # auto-advance through chains
#   tools/next.sh acuenta   # stick to acuenta

set -euo pipefail
cd "$(dirname "$0")/../../../.."

db="priv/data/super_barato_dev.db"
samples_sql="priv/repo/seeds/sample_listings.sql"
tools_dir="priv/repo/seeds/tools"

# Resolve which chain + entry to show. With an argument, pin to that
# chain (its first [ ] block, which is its highest-count since the
# file is sorted count-desc). Without one, ask every
# priv/repo/seeds/categories/*.txt for its top [ ], then sort across
# them by count and pick the global max.
if [ "$#" -ge 1 ]; then
  candidates=("$1")
else
  candidates=()
  for f in priv/repo/seeds/categories/*.txt; do
    candidates+=("$(basename "$f" .txt)")
  done
fi

# Per-chain max → tab-separated `<count>\t<chain>` list.
per_chain=$(
  for c in "${candidates[@]}"; do
    f="priv/repo/seeds/categories/$c.txt"
    [ -s "$f" ] || continue
    b=$(grep -A 2 -m 1 -E '^[0-9a-f]{8} \[ \]$' "$f" || true)
    [ -n "$b" ] || continue
    count=$(printf '%s\n' "$b" | awk 'NR==2 { print $1; exit }')
    printf '%s\t%s\n' "$count" "$c"
  done
)

chain=""
block=""

if [ -n "$per_chain" ]; then
  chain=$(printf '%s\n' "$per_chain" | sort -t$'\t' -k1,1 -rn | head -1 | cut -f2)
  block=$(grep -A 2 -m 1 -E '^[0-9a-f]{8} \[ \]$' "priv/repo/seeds/categories/$chain.txt")
fi

if [ -z "$chain" ]; then
  if [ "$#" -ge 1 ]; then
    echo "DONE — no [ ] entries in $1"
  else
    echo "DONE — every chain is fully triaged"
  fi
  exit 0
fi

file="priv/repo/seeds/categories/$chain.txt"

path=$(printf '%s\n' "$block" | awk 'NR==2 { sub(/^ *[0-9]+ +/, ""); print }')
slug=$(printf '%s\n' "$block" | awk 'NR==3 { print }')
leaf=$(printf '%s\n' "$path" | awk -F' / ' '{ print $NF }')

echo "CHAIN:  $chain"
echo
echo "TARGET:"
printf '%s\n' "$block" | sed 's/^/  /'

echo
echo "LISTINGS:"
sqlite3 -cmd ".parameter set :chain '$chain'" \
        -cmd ".parameter set :slug '$slug'" \
        "$db" \
        < "$samples_sql" \
   | sed 's/^/  /'

echo
echo "CATEGORIES (search: \"$leaf\"):"
"$tools_dir/search.sh" "$leaf" | sed 's/^/  /'
