# Dump every chain_categories row to priv/repo/source/chain_categories.jsonl —
# one record per line, stable ordering. The seed script
# (priv/repo/seeds/chain_categories.exs) reads this file to populate
# a fresh database.
#
# Re-run after each prod reset that captures new categories (notably
# the upcoming reset that finally pulls Santa Isabel's tree):
#
#   mix run priv/repo/scripts/dump_chain_categories.exs
#
# Output is sorted (chain, slug) so diffs between snapshots are
# minimal — drop-in replacement, easy code review.

import Ecto.Query

alias SuperBarato.Catalog.ChainCategory
alias SuperBarato.Repo

out_path = Path.expand("../source/chain_categories.jsonl", __DIR__)

rows =
  Repo.all(
    from c in ChainCategory,
      order_by: [asc: c.chain, asc: c.slug],
      select: %{
        chain: c.chain,
        slug: c.slug,
        name: c.name,
        parent_slug: c.parent_slug,
        external_id: c.external_id,
        level: c.level,
        is_leaf: c.is_leaf,
        active: c.active
      }
  )

body =
  rows
  |> Enum.map(&Jason.encode!/1)
  |> Enum.join("\n")
  |> Kernel.<>("\n")

File.mkdir_p!(Path.dirname(out_path))
File.write!(out_path, body)

per_chain =
  rows
  |> Enum.frequencies_by(& &1.chain)
  |> Enum.sort()
  |> Enum.map_join(", ", fn {c, n} -> "#{c}=#{n}" end)

IO.puts("Wrote #{out_path}: #{length(rows)} rows (#{per_chain})")
