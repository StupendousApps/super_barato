defmodule SuperBarato.Repo.Migrations.CreateChainListingCategories do
  use Ecto.Migration

  import Ecto.Query
  alias SuperBarato.Repo

  def up do
    create table(:chain_listing_categories) do
      add :chain_listing_id,
          references(:chain_listings, on_delete: :delete_all),
          null: false

      add :chain_category_id,
          references(:chain_categories, on_delete: :delete_all),
          null: false
    end

    create unique_index(:chain_listing_categories, [:chain_listing_id, :chain_category_id])
    create index(:chain_listing_categories, [:chain_category_id])

    flush()
    backfill_from_category_paths()
  end

  def down do
    drop table(:chain_listing_categories)
  end

  # Backfill strategy:
  #
  #   1. Build a small in-memory map (chain, slug) → chain_category_id
  #      from the chain_categories table. This is bounded — ~3.5k rows
  #      — and avoids one round-trip per listing to look up the FK.
  #
  #   2. Build the jumbo breadcrumb-name → slug salvage map (the
  #      paths field on jumbo's chain_listings stores breadcrumb names
  #      like "Carnes y Pescados > Vacuno > X", not slugs). Same
  #      walk as priv/repo/seeds/jumbo_breadcrumb_map.sql: exact match
  #      on the full ancestry-name path, falling back to the deepest
  #      prefix that does match.
  #
  #   3. Stream chain_listings one row at a time, decode the JSON
  #      array, translate each entry to a chain_category_id, and
  #      insert one join row per match. No bulk inserts, no eager
  #      loading of listings.
  defp backfill_from_category_paths do
    cat_id_by_chain_slug = build_chain_slug_to_id_map()
    jumbo_breadcrumb_map = build_jumbo_breadcrumb_map(cat_id_by_chain_slug)

    {:ok, _} =
      Repo.transaction(
        fn ->
          from(l in "chain_listings",
            select: %{id: l.id, chain: l.chain, category_paths: l.category_paths}
          )
          |> Repo.stream(max_rows: 200)
          |> Stream.each(&backfill_listing(&1, cat_id_by_chain_slug, jumbo_breadcrumb_map))
          |> Stream.run()
        end,
        timeout: :infinity
      )
  end

  defp backfill_listing(%{id: id, chain: chain, category_paths: paths_json}, cat_map, jumbo_map) do
    paths_json
    |> decode_paths()
    |> Enum.flat_map(&resolve_path(&1, chain, cat_map, jumbo_map))
    |> Enum.uniq()
    |> Enum.each(&insert_join(id, &1))
  end

  defp decode_paths(nil), do: []
  defp decode_paths([]), do: []
  defp decode_paths(json) when is_list(json), do: json

  defp decode_paths(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp resolve_path(value, "jumbo", _cat_map, jumbo_map) when is_binary(value) do
    case Map.get(jumbo_map, value) do
      nil -> []
      cat_id -> [cat_id]
    end
  end

  defp resolve_path(value, chain, cat_map, _jumbo_map) when is_binary(value) and is_binary(chain) do
    case Map.get(cat_map, {chain, value}) do
      nil -> []
      cat_id -> [cat_id]
    end
  end

  defp resolve_path(_, _, _, _), do: []

  defp insert_join(listing_id, cat_id) do
    Repo.insert_all(
      "chain_listing_categories",
      [%{chain_listing_id: listing_id, chain_category_id: cat_id}],
      on_conflict: :nothing
    )
  end

  defp build_chain_slug_to_id_map do
    from(c in "chain_categories", select: %{id: c.id, chain: c.chain, slug: c.slug})
    |> Repo.all()
    |> Map.new(fn %{id: id, chain: chain, slug: slug} -> {{chain, slug}, id} end)
  end

  # Mirror of priv/repo/seeds/jumbo_breadcrumb_map.sql: the values
  # stored in jumbo's chain_listings.category_paths are name-based
  # breadcrumbs, so we map each unique breadcrumb to a real
  # chain_category_id by walking the ancestry-name path. Returns a
  # map keyed by the breadcrumb string so backfill_listing/3 can do a
  # single hash lookup per stored path.
  defp build_jumbo_breadcrumb_map(cat_id_by_chain_slug) do
    breadcrumbs =
      Repo.query!("""
      WITH RECURSIVE ancestry(slug, parent_slug, path, depth) AS (
        SELECT slug, parent_slug, name, 0
          FROM chain_categories WHERE chain = 'jumbo'
        UNION ALL
        SELECT a.slug, p.parent_slug, p.name || ' > ' || a.path, a.depth + 1
          FROM ancestry a
          JOIN chain_categories p ON p.chain = 'jumbo' AND p.slug = a.parent_slug
          WHERE a.depth < 16
      )
      SELECT path, slug, depth FROM ancestry
      """).rows

    # Build (path → slug) split into exact (parent_slug=NULL i.e. full
    # path to root, captured as the deepest entry per slug) and
    # any-prefix (every intermediate path). For each unique stored
    # breadcrumb, exact wins; otherwise we take the deepest prefix
    # that matches.
    by_path = Enum.group_by(breadcrumbs, fn [path, _slug, _depth] -> path end)

    distinct_breadcrumbs =
      Repo.query!("""
      SELECT DISTINCT p.value FROM chain_listings cl, json_each(cl.category_paths) AS p
      WHERE cl.chain = 'jumbo'
      """).rows
      |> Enum.map(fn [v] -> v end)

    Enum.reduce(distinct_breadcrumbs, %{}, fn breadcrumb, acc ->
      case best_match(breadcrumb, by_path) do
        nil ->
          acc

        slug ->
          case Map.get(cat_id_by_chain_slug, {"jumbo", slug}) do
            nil -> acc
            cat_id -> Map.put(acc, breadcrumb, cat_id)
          end
      end
    end)
  end

  # Pick the slug whose ancestry path is either equal to the
  # breadcrumb or the deepest path the breadcrumb starts with
  # (matched on a full segment boundary).
  defp best_match(breadcrumb, by_path) do
    Enum.reduce(by_path, {nil, -1}, fn {path, [[_, slug, depth] | _]}, {best_slug, best_depth} = acc ->
      cond do
        path == breadcrumb ->
          {slug, depth}

        String.starts_with?(breadcrumb, path <> " > ") and depth > best_depth ->
          {slug, depth}

        true ->
          acc
      end
    end)
    |> case do
      {nil, _} -> nil
      {slug, _} -> slug
    end
  end
end
