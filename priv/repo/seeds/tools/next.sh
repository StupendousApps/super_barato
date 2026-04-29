#!/usr/bin/env bash
# Print the first [ ] block in priv/repo/seeds/categories/<chain>.txt.
# Output is the three-line block as-is (entry-id + status, count + path,
# slug). Empty output + exit 0 means the chain is fully triaged.
#
#   tools/next.sh jumbo

set -euo pipefail
cd "$(dirname "$0")/../../../.."

chain=${1:?"usage: $0 <chain>"}
file="priv/repo/seeds/categories/$chain.txt"

[ -s "$file" ] || exit 0

# Match lines like "<8 hex> [ ]". -A 2 grabs the count+path and slug
# lines that follow. head -3 stops after the first match.
grep -A 2 -m 1 -E '^[0-9a-f]{8} \[ \]$' "$file" || true
