# Seed `chain_categories` from priv/repo/source/chain_categories.jsonl.
# That file is a frozen snapshot of a real, freshly-crawled production
# database — see priv/repo/scripts/dump_chain_categories.exs to
# regenerate it after the next reset.
#
# Idempotent: rows are upserted by the (chain, slug) unique key.
#
# Run as part of the orchestrator (preferred) or directly:
#   mix run priv/repo/seed_chain_categories.exs
#
# Source file shape — one JSON object per line, fields verbatim from
# the chain_categories table (chain, slug, name, parent_slug,
# external_id, level, is_leaf, active).

alias SuperBarato.Catalog.ChainCategory
alias SuperBarato.Repo

source_path = Path.expand("source/chain_categories.jsonl", __DIR__)

now = DateTime.utc_now() |> DateTime.truncate(:second)

rows =
  source_path
  |> File.stream!()
  |> Stream.map(&String.trim/1)
  |> Stream.reject(&(&1 == ""))
  |> Stream.map(&Jason.decode!/1)
  |> Stream.map(fn r ->
    %{
      chain: r["chain"],
      slug: r["slug"],
      name: r["name"],
      parent_slug: r["parent_slug"],
      external_id: r["external_id"],
      level: r["level"],
      is_leaf: r["is_leaf"],
      active: Map.get(r, "active", true),
      # `first_seen_at` / `last_seen_at` are NOT NULL on the schema.
      # The crawler stamps them on real discovery; for the seed they
      # default to "now" — meaning "this row was first observed when
      # we seeded the DB". The crawler's discovery upsert refreshes
      # last_seen_at on every subsequent run, so this seed value is
      # only the visible value until the first crawl.
      first_seen_at: now,
      last_seen_at: now,
      inserted_at: now,
      updated_at: now
    }
  end)
  |> Enum.to_list()

# SQLite caps `INSERT … VALUES (…)` at 999 placeholders; the row has
# 12 columns, so 80 rows per batch (= 960) keeps us under the cap.
batch_size = 80

n =
  rows
  |> Enum.chunk_every(batch_size)
  |> Enum.reduce(0, fn batch, acc ->
    {count, _} =
      Repo.insert_all(
        ChainCategory,
        batch,
        on_conflict:
          {:replace, [:name, :parent_slug, :external_id, :level, :is_leaf, :active, :updated_at]},
        conflict_target: [:chain, :slug]
      )

    acc + count
  end)

per_chain =
  rows
  |> Enum.frequencies_by(& &1.chain)
  |> Enum.sort()
  |> Enum.map_join(", ", fn {c, n} -> "#{c}=#{n}" end)

IO.puts("Seeded chain_categories: #{n} rows (#{per_chain})")
