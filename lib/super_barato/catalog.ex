defmodule SuperBarato.Catalog do
  @moduledoc """
  Persistence for the crawler.

    * Categories → `upsert_category/1` writes `%ChainCategory{}` structs.
    * Products   → `upsert_listing/1` writes `%Listing{}` structs
      (identity + current prices + image + metadata).
    * Refresh    → `record_product_info/2` updates a `ChainListing`
      with the fresh `current_*` price columns. Price history is
      append-only in file logs (`SuperBarato.PriceLog`), not the DB.
  """

  import Ecto.Query

  alias SuperBarato.Catalog.{
    AppCategory,
    AppSubcategory,
    CategoryMapping,
    ChainCategory,
    ChainListing,
    ChainListingCategory,
    Product,
    ProductIdentifier
  }

  alias SuperBarato.Linker.ProductListing
  alias SuperBarato.Search.Q
  alias SuperBarato.Crawler.ChainCategory, as: CrawlerCategory
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

    %ChainCategory{}
    |> ChainCategory.discovery_changeset(attrs)
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
    ChainCategory
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
    if is_integer(listing.regular_price) and listing.regular_price > 0 do
      # Hot path — most refreshes have a price. Single INSERT…ON
      # CONFLICT statement; no SELECT needed. The category_paths
      # merge happens inline via SQLite's `json_each`.
      do_priced_upsert(listing)
    else
      # Cold path — refresh observed no price. Update only if the row
      # already exists; refuse to create a no-price row from scratch.
      # The SELECT is necessary here because we need to differentiate
      # "exists → mark unavailable" from "doesn't exist → skip", and
      # ON CONFLICT can't express that without inserting first.
      case existing_listing(listing) do
        nil -> {:ok, :skipped, nil}
        %ChainListing{} = row -> mark_unavailable(row, listing)
      end
    end
  end

  # `identifiers_key` is required at validation time but the upsert's
  # existence lookup runs before changeset casting, so a malformed
  # caller (nil chain or nil key) shouldn't trigger Ecto's "comparison
  # with nil is forbidden" warning. Treat nil as "no existing row";
  # the changeset will fail loudly later.
  defp existing_listing(%Listing{chain: nil}), do: nil
  defp existing_listing(%Listing{identifiers_key: nil}), do: nil

  defp existing_listing(%Listing{} = listing) do
    Repo.get_by(ChainListing,
      chain: to_string(listing.chain),
      identifiers_key: listing.identifiers_key
    )
  end

  defp mark_unavailable(%ChainListing{} = row, %Listing{} = incoming) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    incoming_paths = listing_incoming_paths(incoming)
    merged_paths = merge_category_paths(row.category_paths, incoming_paths)

    # Update everything except the price columns and `last_priced_at`.
    # The shopper-facing price stays at its last-known value;
    # `has_price` is the signal that the chain isn't currently offering it.
    attrs =
      %{
        chain_product_id: incoming.chain_product_id,
        ean: incoming.ean,
        name: incoming.name,
        brand: incoming.brand,
        image_url: incoming.image_url,
        pdp_url: incoming.pdp_url,
        raw: incoming.raw || %{},
        category_paths: merged_paths,
        last_discovered_at: now,
        active: true,
        has_price: false
      }

    {:ok, updated} =
      row
      |> Ecto.Changeset.change(attrs)
      |> Repo.update()

    sync_listing_categories(updated)
    {:ok, :updated, updated}
  end

  # Single-statement INSERT…ON CONFLICT. The on_conflict :replace
  # list rewrites every field except `category_paths`, which is
  # merged inline below via a SQL fragment so we never lose surfaces
  # the row was previously discovered through.
  defp do_priced_upsert(%Listing{} = listing) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    incoming_paths = listing_incoming_paths(listing)

    attrs = %{
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
      category_paths: incoming_paths,
      current_regular_price: listing.regular_price,
      current_promo_price: listing.promo_price,
      current_promotions: listing.promotions || %{},
      first_seen_at: now,
      last_discovered_at: now,
      last_priced_at: now,
      active: true,
      has_price: true
    }

    # SQLite expression that unions the existing row's category_paths
    # with the inserted candidate's, dedupes, and returns a JSON
    # array. Runs inside the conflict-update so it can see both
    # `chain_listings.<col>` (existing) and `excluded.<col>`
    # (incoming).
    on_conflict =
      from(c in ChainListing,
        update: [
          set: [
            chain_product_id: fragment("excluded.chain_product_id"),
            ean: fragment("excluded.ean"),
            name: fragment("excluded.name"),
            brand: fragment("excluded.brand"),
            image_url: fragment("excluded.image_url"),
            pdp_url: fragment("excluded.pdp_url"),
            raw: fragment("excluded.raw"),
            current_regular_price: fragment("excluded.current_regular_price"),
            current_promo_price: fragment("excluded.current_promo_price"),
            current_promotions: fragment("excluded.current_promotions"),
            last_discovered_at: fragment("excluded.last_discovered_at"),
            last_priced_at: fragment("excluded.last_priced_at"),
            active: fragment("excluded.active"),
            has_price: fragment("excluded.has_price"),
            updated_at: fragment("excluded.updated_at"),
            # `category_paths` (unqualified) refers to the existing
            # row's value in SQLite's ON CONFLICT context;
            # `excluded.category_paths` is the incoming candidate.
            # Wrapped in COALESCE to handle the no-existing-paths
            # case (NULL → empty JSON array for json_each).
            category_paths:
              fragment("""
              (SELECT json_group_array(value) FROM (
                SELECT value FROM json_each(COALESCE(category_paths, '[]'))
                UNION
                SELECT value FROM json_each(COALESCE(excluded.category_paths, '[]'))
              ))
              """)
          ]
        ]
      )

    case %ChainListing{}
         |> ChainListing.discovery_changeset(attrs)
         |> Repo.insert(
           on_conflict: on_conflict,
           conflict_target: [:chain, :identifiers_key],
           returning: true
         ) do
      {:ok, row} ->
        sync_listing_categories(row)
        {:ok, :upserted, row}

      {:error, _} = err ->
        err
    end
  end

  defp listing_incoming_paths(%Listing{category_path: nil}), do: []
  defp listing_incoming_paths(%Listing{category_path: ""}), do: []
  defp listing_incoming_paths(%Listing{category_path: p}) when is_binary(p), do: [p]

  # Sync `chain_listing_categories` join rows for one ChainListing.
  # Each entry in `category_paths` is a `chain_categories.slug`; we
  # resolve them to ids in a single query and INSERT OR IGNORE the
  # joins (the unique index on (chain_listing_id, chain_category_id)
  # absorbs re-runs without complaint).
  #
  # Paths that don't resolve (chain renamed a category, breadcrumb
  # carried a slug we never crawled, …) are silently dropped — the
  # join is best-effort. The legacy `category_paths` array still
  # carries the raw value as a fallback.
  defp sync_listing_categories(%ChainListing{id: id, chain: chain, category_paths: paths})
       when is_list(paths) and paths != [] do
    cat_ids =
      Repo.all(
        from c in ChainCategory,
          where: c.chain == ^chain and c.slug in ^paths,
          select: c.id
      )

    rows = Enum.map(cat_ids, &%{chain_listing_id: id, chain_category_id: &1})

    if rows != [] do
      Repo.insert_all(ChainListingCategory, rows, on_conflict: :nothing)
    end

    :ok
  end

  defp sync_listing_categories(_), do: :ok

  defp merge_category_paths(nil, incoming), do: incoming
  defp merge_category_paths(existing, []) when is_list(existing), do: existing

  defp merge_category_paths(existing, incoming) when is_list(existing) and is_list(incoming) do
    Enum.uniq(existing ++ incoming)
  end

  @doc """
  Refreshes a listing's current price columns. Price history is
  appended to the file-backed log by `PersistenceServer` separately
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
        from c in ChainCategory,
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
      ChainCategory
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
    "updated_at" => :updated_at,
    "chain_count" => :chain_count
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
    fts_q = fts_query(opts[:q])

    query =
      Product
      |> apply_product_q_filter(opts[:q], fts_q)
      |> apply_product_ean_filter(opts[:ean])
      |> apply_product_app_category_filter(opts[:app_category])
      |> apply_product_app_subcategory_filter(opts[:app_subcategory])
      |> apply_product_uncategorized_filter(opts[:uncategorized])

    total_entries = Repo.aggregate(query, :count)

    items =
      query
      |> apply_product_sort(opts[:sort] || "-updated_at", fts_q)
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

  # FTS5 path: build a MATCH expression from the user's query and
  # constrain the products query to ids matching it. We fall back to
  # the legacy LIKE-based filter when the query reduces to an empty
  # FTS expression (so callers using EAN/operator forms still work).
  defp apply_product_q_filter(query, _q, fts_q) when is_binary(fts_q) and fts_q != "" do
    sub =
      from f in "products_fts",
        where: fragment("products_fts MATCH ?", ^fts_q),
        select: %{rowid: fragment("rowid")}

    from p in query, where: p.id in subquery(sub)
  end

  defp apply_product_q_filter(query, q, _fts_q),
    do: Q.filter(query, q, [:canonical_name, :brand])

  # Build an FTS5 MATCH expression from raw user input. Strips
  # special operators, splits on whitespace, and turns each token
  # into a prefix match so partial words still hit. Returns "" when
  # nothing meaningful is left.
  defp fts_query(nil), do: ""
  defp fts_query(""), do: ""

  defp fts_query(q) when is_binary(q) do
    q
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.map(&(&1 <> "*"))
    |> Enum.join(" ")
  end

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

  # App-taxonomy filters — only return products that have at least
  # one ChainListing whose ChainCategory has a CategoryMapping into
  # the requested AppSubcategory (or AppCategory). DISTINCT so the
  # 1-to-many fan-out doesn't multiply rows.
  defp apply_product_app_subcategory_filter(query, slug) when slug in [nil, ""], do: query

  defp apply_product_app_subcategory_filter(query, slug) when is_binary(slug) do
    from p in query,
      join: pl in ProductListing,
      on: pl.product_id == p.id,
      join: clc in ChainListingCategory,
      on: clc.chain_listing_id == pl.chain_listing_id,
      join: cm in CategoryMapping,
      on: cm.chain_category_id == clc.chain_category_id,
      join: s in AppSubcategory,
      on: s.id == cm.app_subcategory_id,
      where: s.slug == ^slug,
      distinct: true
  end

  # "Uncategorized" filter — products with no ChainListing whose
  # ChainCategory has a CategoryMapping. Useful for triaging the
  # long tail.
  defp apply_product_uncategorized_filter(query, true) do
    mapped =
      from pl in ProductListing,
        join: clc in ChainListingCategory,
        on: clc.chain_listing_id == pl.chain_listing_id,
        join: cm in CategoryMapping,
        on: cm.chain_category_id == clc.chain_category_id,
        select: pl.product_id

    from p in query, where: p.id not in subquery(mapped)
  end

  defp apply_product_uncategorized_filter(query, _), do: query

  defp apply_product_app_category_filter(query, slug) when slug in [nil, ""], do: query

  defp apply_product_app_category_filter(query, slug) when is_binary(slug) do
    from p in query,
      join: pl in ProductListing,
      on: pl.product_id == p.id,
      join: clc in ChainListingCategory,
      on: clc.chain_listing_id == pl.chain_listing_id,
      join: cm in CategoryMapping,
      on: cm.chain_category_id == clc.chain_category_id,
      join: s in AppSubcategory,
      on: s.id == cm.app_subcategory_id,
      join: ac in AppCategory,
      on: ac.id == s.app_category_id,
      where: ac.slug == ^slug,
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
  Bulk lookup: `%{product_id => %{cat_slug, cat_name, sub_slug, sub_name}}`
  for the given product ids. Walks
  Product → ProductListing → ChainListingCategory → CategoryMapping →
  AppSubcategory → AppCategory.

  A product can carry listings in multiple chain categories, each of
  which may map to a different app subcategory. We pick the
  most-frequent (chain_category × subcategory) pairing — that's the
  consensus categorization across the product's chains. Ties are
  broken alphabetically on subcategory name (stable + cheap).
  """
  def categories_by_product_ids(product_ids) when is_list(product_ids) do
    # Manual overrides win — fetch them first.
    overrides =
      Repo.all(
        from p in Product,
          join: s in AppSubcategory,
          on: s.id == p.app_subcategory_id,
          join: ac in AppCategory,
          on: ac.id == s.app_category_id,
          where: p.id in ^product_ids,
          select: %{
            product_id: p.id,
            cat_slug: ac.slug,
            cat_name: ac.name,
            sub_slug: s.slug,
            sub_name: s.name
          }
      )
      |> Map.new(fn r ->
        {r.product_id,
         %{
           cat_slug: r.cat_slug,
           cat_name: r.cat_name,
           sub_slug: r.sub_slug,
           sub_name: r.sub_name
         }}
      end)

    # Derive consensus only for products without a manual override.
    derive_for = product_ids -- Map.keys(overrides)

    rows =
      if derive_for == [] do
        []
      else
        Repo.all(
          from pl in ProductListing,
            join: clc in ChainListingCategory,
            on: clc.chain_listing_id == pl.chain_listing_id,
            join: cm in CategoryMapping,
            on: cm.chain_category_id == clc.chain_category_id,
            join: s in AppSubcategory,
            on: s.id == cm.app_subcategory_id,
            join: ac in AppCategory,
            on: ac.id == s.app_category_id,
            where: pl.product_id in ^derive_for,
            group_by: [pl.product_id, ac.slug, ac.name, s.slug, s.name],
            select: %{
              product_id: pl.product_id,
              cat_slug: ac.slug,
              cat_name: ac.name,
              sub_slug: s.slug,
              sub_name: s.name,
              count: count()
            }
        )
      end

    derived =
      rows
      |> Enum.group_by(& &1.product_id)
      |> Map.new(fn {pid, group} ->
        best =
          group
          |> Enum.sort_by(&{-&1.count, &1.sub_name})
          |> List.first()

        {pid,
         %{
           cat_slug: best.cat_slug,
           cat_name: best.cat_name,
           sub_slug: best.sub_slug,
           sub_name: best.sub_name
         }}
      end)

    Map.merge(derived, overrides)
  end

  @doc """
  Loads every AppCategory with its subcategories preloaded, in
  display order. Powers the cascading category/subcategory dropdowns
  on the product edit form.
  """
  def app_categories_with_subcategories do
    Repo.all(
      from c in AppCategory,
        order_by: [asc: c.position, asc: c.name],
        preload: [
          subcategories:
            ^from(s in AppSubcategory,
              order_by: [asc: s.position, asc: s.name]
            )
        ]
    )
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

  # When an FTS query is in play, order by combined relevance:
  # bm25 score (lower = better) minus a chain_count boost (more
  # chains = lower score = ranked higher). The factor 0.5 was
  # picked by eye — tweak when the search UX gets evaluated.
  defp apply_product_sort(query, _sort, fts_q) when is_binary(fts_q) and fts_q != "" do
    rank_sub =
      from f in "products_fts",
        where: fragment("products_fts MATCH ?", ^fts_q),
        select: %{rowid: fragment("rowid"), score: fragment("bm25(products_fts)")}

    from p in query,
      join: r in subquery(rank_sub),
      on: r.rowid == p.id,
      order_by: [asc: fragment("? - 1.5 * (? - 1)", r.score, p.chain_count)]
  end

  defp apply_product_sort(query, sort, _fts_q), do: apply_product_sort(query, sort)

  defp apply_product_sort(query, "-" <> field), do: apply_product_sort_dir(query, field, :desc)
  defp apply_product_sort(query, field), do: apply_product_sort_dir(query, field, :asc)

  defp apply_product_sort_dir(query, field, dir) do
    case Map.fetch(@product_sortable, field) do
      {:ok, atom} -> order_by(query, [p], [{^dir, field(p, ^atom)}])
      :error -> order_by(query, [p], desc: p.updated_at)
    end
  end
end
