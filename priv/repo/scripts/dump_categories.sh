#!/usr/bin/env bash
# Dump every chain's categories into priv/repo/scripts/categories/<chain>.txt.
# Driven by dump_categories.sql with :chain bound per iteration. After
# sqlite emits its blocks, a perl post-pass stamps each block's status
# line with an entry-id — the first 8 hex chars of md5(chain|slug) —
# so triage tools can address an entry by `<entry-id> [ ]` for clean
# bash sed replacement.

set -euo pipefail

cd "$(dirname "$0")/../../.."

DB="${DB:-priv/data/super_barato_dev.db}"
OUT="priv/repo/scripts/categories"
SQL="priv/repo/scripts/dump_categories.sql"

mkdir -p "$OUT"

for chain in jumbo santa_isabel lider tottus unimarc acuenta; do
  out="$OUT/$chain.txt"
  sqlite3 -cmd ".parameter set :chain '$chain'" "$DB" < "$SQL" \
  | perl -e '
      use Digest::MD5 qw(md5_hex);
      my $chain = shift;
      my @buf;
      while (my $line = <STDIN>) {
        chomp $line;
        if ($line eq "") {
          flush(\@buf, $chain);
          @buf = ();
        } else {
          push @buf, $line;
        }
      }
      flush(\@buf, $chain) if @buf;
      sub flush {
        my ($buf, $chain) = @_;
        return unless @$buf == 3;
        my ($status, $count_path, $slug) = @$buf;
        my $id = substr(md5_hex("$chain|$slug"), 0, 8);
        print "$id $status\n$count_path\n$slug\n\n";
      }
    ' "$chain" > "$out"

  printf '%s: %d rows\n' "$out" "$(wc -l < "$out")"
done
