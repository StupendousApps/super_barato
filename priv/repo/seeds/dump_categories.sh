#!/usr/bin/env bash
# Dump every chain's categories into priv/repo/seeds/categories/<chain>.txt.
# Driven by dump_categories.sql with :chain bound per iteration.

set -euo pipefail

cd "$(dirname "$0")/../../.."

DB="${DB:-priv/data/super_barato_dev.db}"
OUT="priv/repo/seeds/categories"
SQL="priv/repo/seeds/dump_categories.sql"

mkdir -p "$OUT"

for chain in jumbo santa_isabel lider tottus unimarc acuenta; do
  out="$OUT/$chain.txt"
  sqlite3 -cmd ".parameter set :chain '$chain'" "$DB" < "$SQL" > "$out"
  printf '%s: %d rows\n' "$out" "$(wc -l < "$out")"
done
