#!/usr/bin/env bash
# Rewrite the status of one entry in priv/repo/seeds/categories/<chain>.txt.
# Located by its entry-id (8 hex chars, the first token on the entry's
# status line). Status arg is one of:
#
#   <id>  — 8 hex chars, becomes "[x] <id>"
#   -     — becomes "[-]"
#   N     — becomes "[N]"
#   _     — becomes "[ ]"   (back to unchecked)
#
# Examples:
#
#   tools/mark.sh jumbo abe1474f 8134061f
#   tools/mark.sh lider 4f3a2b1c -
#   tools/mark.sh tottus c0ffee01 N

set -euo pipefail
cd "$(dirname "$0")/../../../.."

chain=${1:?"usage: $0 <chain> <entry-id> <id|-|N|_>"}
entry_id=${2:?"usage: $0 <chain> <entry-id> <id|-|N|_>"}
status=${3:?"usage: $0 <chain> <entry-id> <id|-|N|_>"}

file="priv/repo/seeds/categories/$chain.txt"

[ -f "$file" ] || { echo "no such checklist: $file" >&2; exit 1; }

# Validate entry_id format.
[[ "$entry_id" =~ ^[0-9a-f]{8}$ ]] || {
  echo "entry-id must be 8 hex chars, got: $entry_id" >&2
  exit 2
}

# Translate status arg into the line payload.
case "$status" in
  -)  payload="[-]" ;;
  N)  payload="[N]" ;;
  _)  payload="[ ]" ;;
  *)
    [[ "$status" =~ ^[0-9a-f]{8}$ ]] || {
      echo "status must be 8 hex chars, '-', 'N', or '_'; got: $status" >&2
      exit 2
    }
    payload="[x] $status"
    ;;
esac

# Match a status line for this entry-id and replace it. Anchored
# regex ([0-9a-f]+) matches both unchecked `[ ]` and any prior
# `[x]/[-]/[N]` payload. macOS sed needs the empty -i argument.
sed -i.bak -E "s|^${entry_id} \[.*\$|${entry_id} ${payload}|" "$file"
rm -f "$file.bak"

# Confirm the line is what we expect now.
grep -E "^${entry_id} " "$file" | head -1
