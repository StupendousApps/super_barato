defmodule SuperBarato.Catalog do
  @moduledoc """
  Persistence for the crawler.

    * Categories → `upsert_category/1` writes `%Category{}` structs.
    * Products   → `upsert_listing/1` writes `%Listing{}` structs
      (identity + current prices + image + metadata).
    * Refresh    → `record_product_info/2` updates a `ChainListing`
      with the fresh `current_*` price columns. Price history is
      append-only in file logs (`SuperBarato.PriceLog`), not the DB.
  """

  import Ecto.Query

  alias SuperBarato.Catalog.{Category, ChainListing, Product, ProductIdentifier}
  alias SuperBarato.Search.Q
  alias SuperBarato.Crawler.Category, as: CrawlerCategory
  alias SuperBarato.Crawler.Listing
  alias SuperBarato.Repo

  # Categories

  @doc """
  Upserts a discovered category by (chain, slug). Sets `first_seen_at` on
  insert, refreshes `last_seen_at` on both paths, and reactivates the
  row if it had been soft-deleted.
  """
  def upsert_category(%CrawlerCategory{} = cat) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      chain: to_string(cat.chain),
      external_id: cat.external_id,
      slug: cat.slug,
      name: cat.name,
      parent_slug: cat.parent_slug,
      level: cat.level,
      is_leaf: cat.is_leaf,
      active: true,
      first_seen_at: now,
      last_seen_at: now
    }

    %Category{}
    |> Category.discovery_changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :external_id,
           :name,
           :parent_slug,
           :level,
           :is_leaf,
           :active,
           :last_seen_at,
           :updated_at
         ]},
      conflict_target: [:chain, :slug],
      returning: true
    )
  end

  @doc "All leaf categories for a chain (used as stage-2 seeds)."
  def leaf_categories(chain) do
    Repo.all(leaf_categories_query(chain))
  end

  @doc """
  Ecto query for leaf categories of a chain. Used by the
  `ProductProducer` with `Repo.stream/2` for bounded-memory traversal.
  """
  def leaf_categories_query(chain) do
    Category
    |> where([c], c.chain == ^to_string(chain) and c.is_leaf == true and c.active == true)
  end

  @doc """
  Ecto query for non-null values of the chain's refresh identifier
  (`:ean` or `:chain_sku`). Used by the `ProductProducer` for stage-3
  batching. Selects just the identifier value to stream.
  """
  def active_identifiers_query(chain, field) when field in [:ean, :chain_sku] do
    ChainListing
    |> where([l], l.chain == ^to_string(chain) and l.active == true)
    |> where([l], not is_nil(field(l, ^field)))
    |> select([l], field(l, ^field))
  end

  # Listings

  @doc """
  Upserts a listing by (chain, chain_sku). Sets `first_seen_at` on
  insert, refreshes `last_discovered_at`, and updates price/display
  fields with whatever the adapter returned.
  """
  def upsert_listing(%Listing{} = listing) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    incoming_paths = listing_incoming_paths(listing)

    base_attrs = %{
      chain: to_string(listing.chain),
      chain_sku: listing.chain_sku,
      chain_product_id: listing.chain_product_id,
      identifiers_key: listing.identifiers_key,
      ean: listing.ean,
      name: listing.name,
      brand: listing.brand,
      image_url: listing.image_url,
      pdp_url: listing.pdp_url,
      raw: listing.raw || %{},
      current_regular_price: listing.regular_price,
      current_promo_price: listing.promo_price,
      current_promotions: listing.promotions || %{},
      first_seen_at: now,
      last_discovered_at: now,
      last_priced_at: now,
      active: true
    }

    # `category_paths` accumulates surfaces — set to `incoming_paths`
    # on insert, merged with the existing array on conflict-update.
    # The REPLACE form below can't express a per-row union, so we
    # wrap insert + path-merge in a single transaction. SQLite WAL
    # serializes writers within a chain so the read-then-write is
    # safe in our single-Worker-per-chain pipeline.
    Repo.transaction(fn ->
      attrs = Map.put(base_attrs, :category_paths, incoming_paths)

      result =
        %ChainListing{}
        |> ChainListing.discovery_changeset(attrs)
        |> Repo.insert(
          on_conflict:
            {:replace,
             [
               :chain_product_id,
               :ean,
               :name,
               :brand,
               :image_url,
               :pdp_url,
               :raw,
               :current_regular_price,
               :current_promo_price,
               :current_promotions,
               :last_discovered_at,
               :last_priced_at,
               :active,
               :updated_at
             ]},
          # Identity is `(chain, identifiers_key)`. `category_paths`
          # is intentionally NOT in the replace list — the merge
          # happens below.
          conflict_target: [:chain, :identifiers_key],
          returning: true
        )

      case result do
        {:ok, row} ->
          merged = merge_category_paths(row.category_paths, incoming_paths)
          row =
            if merged == row.category_paths do
              row
            else
              {:ok, updated} =
                row
                |> Ecto.Changeset.change(category_paths: merged)
                |> Repo.update()

              updated
            end

          {upsert_action(row), row}

        {:error, cs} ->
          Repo.rollback(cs)
      end
    end)
    |> case do
      {:ok, {action, row}} -> {:ok, action, row}
      {:error, _} = err -> err
    end
  end

  defp listing_incoming_paths(%Listing{category_path: nil}), do: []
  defp listing_incoming_paths(%Listing{category_path: ""}), do: []
  defp listing_incoming_paths(%Listing{category_path: p}) when is_binary(p), do: [p]

  defp merge_category_paths(nil, incoming), do: incoming
  defp merge_category_paths(existing, []) when is_list(existing), do: existing

  defp merge_category_paths(existing, incoming) when is_list(existing) and is_list(incoming) do
    Enum.uniq(existing ++ incoming)
  end

  # Did the upsert insert or update? Ecto's on_conflict is opaque to
  # this, so we infer from the returned row: on insert, both timestamps
  # are set to the same `now`; on conflict-update, `inserted_at` is
  # preserved from the original row and only `updated_at` advances.
  # The DateTime equality is exact at second resolution, so this is
  # robust as long as `now` is truncated the same way for both fields.
  defp upsert_action(%ChainListing{inserted_at: t, updated_at: t}), do: :inserted
  defp upsert_action(%ChainListing{}), do: :updated

  @doc """
  Refreshes a listing's current price columns. Price history is
  appended to the file-backed log by `Chain.Results` separately
  (`SuperBarato.PriceLog`), so this function only updates the DB
  "current" snapshot.
  """
  def record_product_info(%ChainListing{} = existing, %Listing{} = fresh) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    regular = fresh.regular_price || existing.current_regular_price

    existing
    |> ChainListing.price_changeset(%{
      current_regular_price: regular,
      current_promo_price: fresh.promo_price,
      current_promotions: fresh.promotions || %{},
      last_priced_at: now
    })
    |> Repo.update()
  end

  @doc "Active listings for a chain — used for stage-3 refresh inputs."
  def active_listings(chain) do
    ChainListing
    |> where([l], l.chain == ^to_string(chain) and l.active == true)
    |> Repo.all()
  end

  @doc """
  Active listings for a chain, filtered to rows with a non-null value in
  the chain's refresh-identifier column (`:ean` or `:chain_sku`). Used as
  stage-3 input.
  """
  def active_listings_for_refresh(chain, field) when field in [:ean, :chain_sku] do
    ChainListing
    |> where([l], l.chain == ^to_string(chain) and l.active == true)
    |> where([l], not is_nil(field(l, ^field)))
    |> Repo.all()
  end

  def get_listing(chain, chain_sku) do
    Repo.get_by(ChainListing, chain: to_string(chain), chain_sku: chain_sku)
  end

  ## Admin-facing paginated queries

  @default_per_page 25

  @sortable %{
    "name" => :name,
    "brand" => :brand,
    "chain" => :chain,
    "current_regular_price" => :current_regular_price,
    "last_priced_at" => :last_priced_at,
    "last_discovered_at" => :last_discovered_at
  }

  @doc """
  Paginated listings for the admin table. Returns
  `%{items:, page:, per_page:, total_entries:, total_pages:}`.

  ## Options

    * `:chain`    — atom or string chain id; filters by `chain =`.
    * `:q`        — string; case-insensitive `name LIKE %q%`.
    * `:sort`     — `"name"` / `"-last_priced_at"` etc. (see `@sortable`).
    * `:page`     — 1-indexed page (default 1).
    * `:per_page` — default #{@default_per_page}, capped at 200.
  """
  def list_listings_page(opts \\ []) do
    page = max(1, opts[:page] || 1)
    per_page = opts[:per_page] |> clamp_per_page()

    query =
      ChainListing
      |> apply_chain_filter(opts[:chain])
      |> apply_q_filter(opts[:q])
      |> apply_ean_filter(opts[:ean])
      |> apply_category_filter(opts[:category])

    total_entries = Repo.aggregate(query, :count)

    items =
      query
      |> apply_sort(opts[:sort] || "-last_priced_at")
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    %{
      items: items,
      page: page,
      per_page: per_page,
      total_entries: total_entries,
      total_pages: max(1, div(total_entries + per_page - 1, per_page))
    }
  end

  defp clamp_per_page(nil), do: @default_per_page
  defp clamp_per_page(n) when is_integer(n) and n > 0, do: min(n, 200)
  defp clamp_per_page(_), do: @default_per_page

  defp apply_chain_filter(query, nil), do: query
  defp apply_chain_filter(query, ""), do: query

  defp apply_chain_filter(query, chain) when is_atom(chain),
    do: where(query, [l], l.chain == ^Atom.to_string(chain))

  defp apply_chain_filter(query, chain) when is_binary(chain),
    do: where(query, [l], l.chain == ^chain)

  defp apply_q_filter(query, q), do: Q.filter(query, q, [:name, :brand])

  # EAN filter — prefix-match so users can paste a partial EAN. SQLite
  # LIKE is case-insensitive for ASCII, fine here since EANs are digits.
  defp apply_ean_filter(query, nil), do: query
  defp apply_ean_filter(query, ""), do: query

  defp apply_ean_filter(query, ean) when is_binary(ean) do
    like = String.replace(ean, "%", "\\%") <> "%"
    where(query, [l], like(l.ean, ^like))
  end

  # `category_paths` is the JSON array of surfaces this listing has
  # been discovered through. Filter accepts either an exact slug or
  # any descendant — passing the L1 slug `CATG27055/Despensa` matches
  # every listing one of whose paths lives under it.
  defp apply_category_filter(query, nil), do: query
  defp apply_category_filter(query, ""), do: query

  defp apply_category_filter(query, slug) when is_binary(slug) do
    like = String.replace(slug, "%", "\\%") <> "/%"

    where(
      query,
      [l],
      fragment(
        "EXISTS (SELECT 1 FROM json_each(?) WHERE value = ? OR value LIKE ?)",
        l.category_paths,
        ^slug,
        ^like
      )
    )
  end

  defp apply_sort(query, "-" <> field), do: apply_sort_dir(query, field, :desc)
  defp apply_sort(query, field), do: apply_sort_dir(query, field, :asc)

  defp apply_sort_dir(query, field, dir) do
    case Map.fetch(@sortable, field) do
      {:ok, atom} -> order_by(query, [l], [{^dir, field(l, ^atom)}])
      :error -> order_by(query, [l], desc: l.last_priced_at)
    end
  end

  @category_sortable %{
    "name" => :name,
    "chain" => :chain,
    "slug" => :slug,
    "level" => :level,
    "last_seen_at" => :last_seen_at
  }

  @doc """
  Flat list of every category for a chain, returned as
  `[{slug, "Parent / Child / Grandchild"}, ...]` and sorted by the
  full ancestry-chain label. Ready for a `<select>` dropdown.
  """
  def categories_for_chain(nil), do: []
  def categories_for_chain(""), do: []

  def categories_for_chain(chain) when is_binary(chain) or is_atom(chain) do
    chain_str = if is_atom(chain), do: Atom.to_string(chain), else: chain

    cats =
      Repo.all(
        from c in Category,
          where: c.chain == ^chain_str,
          select: %{slug: c.slug, name: c.name, parent_slug: c.parent_slug}
      )

    by_slug = Map.new(cats, &{&1.slug, &1})

    cats
    |> Enum.map(fn cat -> {cat.slug, ancestry_label(cat, by_slug)} end)
    |> Enum.sort_by(fn {_slug, label} -> String.downcase(label) end)
  end

  # Walks `parent_slug` to compose `Root / … / Leaf`. Stops on a nil
  # parent or a missing entry (e.g. orphaned subtree).
  defp ancestry_label(cat, by_slug, seen \\ MapSet.new()) do
    cond do
      MapSet.member?(seen, cat.slug) ->
        cat.name

      is_binary(cat.parent_slug) and Map.has_key?(by_slug, cat.parent_slug) ->
        parent = Map.fetch!(by_slug, cat.parent_slug)
        ancestry_label(parent, by_slug, MapSet.put(seen, cat.slug)) <> " / " <> cat.name

      true ->
        cat.name
    end
  end

  @doc """
  Paginated categories for the admin table. Same result shape as
  `list_listings_page/1`.

  Options: `:chain`, `:q` (LIKE on name / slug), `:type` (`:leaf` /
  `:parent` / `:all`), `:sort`, `:page`, `:per_page`.
  """
  def list_categories_page(opts \\ []) do
    page = max(1, opts[:page] || 1)
    per_page = opts[:per_page] |> clamp_per_page()

    query =
      Category
      |> apply_cat_chain_filter(opts[:chain])
      |> apply_cat_q_filter(opts[:q])
      |> apply_cat_type_filter(opts[:type])

    total_entries = Repo.aggregate(query, :count)

    items =
      query
      |> apply_cat_sort(opts[:sort] || "-last_seen_at")
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    %{
      items: items,
      page: page,
      per_page: per_page,
      total_entries: total_entries,
      total_pages: max(1, div(total_entries + per_page - 1, per_page))
    }
  end

  defp apply_cat_chain_filter(query, nil), do: query
  defp apply_cat_chain_filter(query, ""), do: query

  defp apply_cat_chain_filter(query, chain) when is_atom(chain),
    do: where(query, [c], c.chain == ^Atom.to_string(chain))

  defp apply_cat_chain_filter(query, chain) when is_binary(chain),
    do: where(query, [c], c.chain == ^chain)

  defp apply_cat_q_filter(query, q), do: Q.filter(query, q, [:name, :slug])

  defp apply_cat_type_filter(query, :leaf), do: where(query, [c], c.is_leaf == true)
  defp apply_cat_type_filter(query, :parent), do: where(query, [c], c.is_leaf == false)
  defp apply_cat_type_filter(query, _), do: query

  defp apply_cat_sort(query, "-" <> field), do: apply_cat_sort_dir(query, field, :desc)
  defp apply_cat_sort(query, field), do: apply_cat_sort_dir(query, field, :asc)

  defp apply_cat_sort_dir(query, field, dir) do
    case Map.fetch(@category_sortable, field) do
      {:ok, atom} -> order_by(query, [c], [{^dir, field(c, ^atom)}])
      :error -> order_by(query, [c], desc: c.last_seen_at)
    end
  end

  # Products

  @product_sortable %{
    "canonical_name" => :canonical_name,
    "brand" => :brand,
    "inserted_at" => :inserted_at,
    "updated_at" => :updated_at
  }

  @doc """
  Paginated products for the admin table. Same result shape as
  `list_listings_page/1`.

  Options: `:q` (LIKE on canonical_name / brand), `:ean` (prefix
  match — joins `product_identifiers` on EAN kinds), `:sort`,
  `:page`, `:per_page`.
  """
  def list_products_page(opts \\ []) do
    page = max(1, opts[:page] || 1)
    per_page = opts[:per_page] |> clamp_per_page()

    query =
      Product
      |> apply_product_q_filter(opts[:q])
      |> apply_product_ean_filter(opts[:ean])

    total_entries = Repo.aggregate(query, :count)

    items =
      query
      |> apply_product_sort(opts[:sort] || "-updated_at")
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    %{
      items: items,
      page: page,
      per_page: per_page,
      total_entries: total_entries,
      total_pages: max(1, div(total_entries + per_page - 1, per_page))
    }
  end

  defp apply_product_q_filter(query, q), do: Q.filter(query, q, [:canonical_name, :brand])

  # Product-side EAN filter — join product_identifiers and prefix-match
  # against EAN-kind rows. Distinct so a multi-EAN product isn't
  # returned twice.
  defp apply_product_ean_filter(query, nil), do: query
  defp apply_product_ean_filter(query, ""), do: query

  defp apply_product_ean_filter(query, ean) when is_binary(ean) do
    like = String.replace(ean, "%", "\\%") <> "%"

    from p in query,
      join: pi in ProductIdentifier,
      on: pi.product_id == p.id,
      where: pi.kind in ["ean_13", "ean_8"] and like(pi.value, ^like),
      distinct: true
  end

  @doc """
  Look up the Product anchored on `(kind, value)` in `product_identifiers`.
  Used by the linker to find-or-create.
  """
  def get_product_by_identifier(kind, value) when is_binary(kind) and is_binary(value) do
    case Repo.get_by(ProductIdentifier, kind: kind, value: value) do
      nil -> nil
      %ProductIdentifier{product_id: pid} -> Repo.get(Product, pid)
    end
  end

  @doc """
  Look up the Product anchored on a GS1 EAN (GTIN-13 or EAN-8).
  Convenience over `get_product_by_identifier/2` — checks both kinds.
  """
  def get_product_by_ean(ean) when is_binary(ean) do
    get_product_by_identifier("ean_13", ean) || get_product_by_identifier("ean_8", ean)
  end

  @doc "Returns every EAN attached to `product_id`, oldest-first."
  def eans_for_product(product_id) do
    Repo.all(
      from pi in ProductIdentifier,
        where: pi.product_id == ^product_id and pi.kind in ["ean_13", "ean_8"],
        order_by: pi.inserted_at,
        select: pi.value
    )
  end

  @doc """
  Bulk lookup: `%{product_id => [ean, ...]}` for the given product
  ids. Used by the products index to render an "N EANs" / "first EAN"
  cell in one query.
  """
  def eans_by_product_ids(product_ids) when is_list(product_ids) do
    from(pi in ProductIdentifier,
      where: pi.product_id in ^product_ids and pi.kind in ["ean_13", "ean_8"],
      order_by: pi.inserted_at,
      select: {pi.product_id, pi.value}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {pid, ean}, acc ->
      Map.update(acc, pid, [ean], &(&1 ++ [ean]))
    end)
  end

  @doc """
  Returns every typed identifier attached to `product_id`,
  oldest-first as `[{kind, value}, ...]`.
  """
  def identifiers_for_product(product_id) do
    Repo.all(
      from pi in ProductIdentifier,
        where: pi.product_id == ^product_id,
        order_by: pi.inserted_at,
        select: {pi.kind, pi.value}
    )
  end

  defp apply_product_sort(query, "-" <> field), do: apply_product_sort_dir(query, field, :desc)
  defp apply_product_sort(query, field), do: apply_product_sort_dir(query, field, :asc)

  defp apply_product_sort_dir(query, field, dir) do
    case Map.fetch(@product_sortable, field) do
      {:ok, atom} -> order_by(query, [p], [{^dir, field(p, ^atom)}])
      :error -> order_by(query, [p], desc: p.updated_at)
    end
  end
end
