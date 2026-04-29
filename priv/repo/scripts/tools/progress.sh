#!/usr/bin/env bash
# Triage progress dashboard — per chain, count [ ] / [x] / [-] / [N]
# and total, plus an aggregate row and percent done.
#
#   tools/progress.sh

set -euo pipefail
cd "$(dirname "$0")/../../../.."

DIR="priv/repo/scripts/categories"
chains=(jumbo santa_isabel lider tottus unimarc acuenta)

printf '%-14s %5s %5s %5s %5s %5s %6s\n' chain total '[ ]' '[x]' '[-]' '[N]' done
printf '%s\n' "------------------------------------------------------------"

tot_t=0; tot_u=0; tot_x=0; tot_n=0; tot_N=0

for chain in "${chains[@]}"; do
  file="$DIR/$chain.txt"
  [ -s "$file" ] || { printf '%-14s %5d %5d %5d %5d %5d %5s\n' "$chain" 0 0 0 0 0 "0%"; continue; }

  u=$(grep -cE '^[0-9a-f]{8} \[ \]$' "$file" || true)
  x=$(grep -cE '^[0-9a-f]{8} \[x\] [0-9a-f]{8}$' "$file" || true)
  m=$(grep -cE '^[0-9a-f]{8} \[-\]$' "$file" || true)
  N=$(grep -cE '^[0-9a-f]{8} \[N\]$' "$file" || true)
  total=$((u + x + m + N))
  done=$((x + m + N))
  pct=0
  [ "$total" -gt 0 ] && pct=$(( 100 * done / total ))

  printf '%-14s %5d %5d %5d %5d %5d %5s\n' "$chain" "$total" "$u" "$x" "$m" "$N" "${pct}%"

  tot_t=$((tot_t + total))
  tot_u=$((tot_u + u))
  tot_x=$((tot_x + x))
  tot_n=$((tot_n + m))
  tot_N=$((tot_N + N))
done

printf '%s\n' "------------------------------------------------------------"
done=$((tot_x + tot_n + tot_N))
pct=0
[ "$tot_t" -gt 0 ] && pct=$(( 100 * done / tot_t ))
printf '%-14s %5d %5d %5d %5d %5d %5s\n' ALL "$tot_t" "$tot_u" "$tot_x" "$tot_n" "$tot_N" "${pct}%"
