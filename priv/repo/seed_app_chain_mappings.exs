# Seed `category_mappings` from the chains: blocks under each
# subcategory in priv/repo/source/categories.yaml. Each entry is a
# `chain_categories.slug`; the seed resolves it against the
# chain_categories + app_subcategories tables and writes the join
# row.
#
# Depends on seed_chain_categories.exs and seed_app_categories.exs
# having already populated their tables — the orchestrator runs the
# three in order.
#
# Run as part of the orchestrator (preferred) or directly:
#   mix run priv/repo/seed_app_chain_mappings.exs
#
# Idempotent: the table's unique index on chain_category_id absorbs
# `INSERT OR IGNORE` re-runs cleanly.

import Ecto.Query

alias SuperBarato.Catalog.{AppSubcategory, CategoryMapping, ChainCategory}
alias SuperBarato.Repo

yaml_path = Path.expand("source/categories.yaml", __DIR__)

# Hand-rolled parser — matches the well-known shape of categories.yaml.
# Returns [{chain, chain_slug, app_cat_slug, app_sub_slug}, ...].
parse_yaml = fn path ->
  lines =
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(fn line ->
      stripped = String.trim_leading(line)
      stripped == "" or String.starts_with?(stripped, "#")
    end)

  initial_state = %{cat_slug: nil, sub_slug: nil, chain: nil}

  reduce_line = fn line, {acc, state} ->
    cond do
      String.starts_with?(line, "- name: ") ->
        {acc, %{state | cat_slug: nil, sub_slug: nil, chain: nil}}

      String.starts_with?(line, "  slug: ") ->
        slug = String.trim_trailing(String.replace_prefix(line, "  slug: ", ""))
        {acc, %{state | cat_slug: slug, sub_slug: nil, chain: nil}}

      String.starts_with?(line, "    - name: ") ->
        {acc, %{state | sub_slug: nil, chain: nil}}

      String.starts_with?(line, "      slug: ") ->
        slug = String.trim_trailing(String.replace_prefix(line, "      slug: ", ""))
        {acc, %{state | sub_slug: slug, chain: nil}}

      String.starts_with?(line, "        ") and String.ends_with?(line, ":") ->
        chain = line |> String.trim() |> String.trim_trailing(":")
        {acc, %{state | chain: chain}}

      String.starts_with?(line, "          - ") and not is_nil(state.chain) ->
        chain_slug = String.trim_trailing(String.replace_prefix(line, "          - ", ""))
        {[{state.chain, chain_slug, state.cat_slug, state.sub_slug} | acc], state}

      true ->
        {acc, state}
    end
  end

  {acc, _state} = Enum.reduce(lines, {[], initial_state}, reduce_line)
  Enum.reverse(acc)
end

mappings = parse_yaml.(yaml_path)

chain_cat_ids =
  Repo.all(from c in ChainCategory, select: {{c.chain, c.slug}, c.id})
  |> Map.new()

app_sub_ids =
  Repo.all(
    from s in AppSubcategory,
      join: c in assoc(s, :app_category),
      select: {{c.slug, s.slug}, s.id}
  )
  |> Map.new()

now = DateTime.utc_now() |> DateTime.truncate(:second)

{rows, missing_chain, missing_app} =
  Enum.reduce(mappings, {[], 0, 0}, fn {chain, chain_slug, cat_slug, sub_slug},
                                       {rows, mc, ma} ->
    chain_cat_id = Map.get(chain_cat_ids, {chain, chain_slug})
    app_sub_id = Map.get(app_sub_ids, {cat_slug, sub_slug})

    cond do
      is_nil(chain_cat_id) ->
        {rows, mc + 1, ma}

      is_nil(app_sub_id) ->
        {rows, mc, ma + 1}

      true ->
        row = %{
          chain_category_id: chain_cat_id,
          app_subcategory_id: app_sub_id,
          inserted_at: now,
          updated_at: now
        }

        {[row | rows], mc, ma}
    end
  end)

# Same SQLite placeholder math as seed_chain_categories: 4 columns
# per row, 200 rows per batch is comfortably under the 999 limit.
batch_size = 200

inserted =
  rows
  |> Enum.chunk_every(batch_size)
  |> Enum.reduce(0, fn batch, acc ->
    {count, _} =
      Repo.insert_all(
        CategoryMapping,
        batch,
        on_conflict: {:replace, [:app_subcategory_id, :updated_at]},
        conflict_target: [:chain_category_id]
      )

    acc + count
  end)

IO.puts(
  "Seeded category_mappings: inserted=#{inserted} " <>
    "missing_chain_category=#{missing_chain} " <>
    "missing_app_subcategory=#{missing_app}"
)
