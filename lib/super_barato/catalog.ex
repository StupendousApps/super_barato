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
  alias SuperBarato.Thumbnails

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
      crawl_enabled: default_crawl_enabled?(cat.chain, cat.slug),
      first_seen_at: now,
      last_seen_at: now
    }

    %ChainCategory{}
    |> ChainCategory.discovery_changeset(attrs)
    |> Repo.insert(
      # `crawl_enabled` is intentionally absent from the replace
      # list so any operator-applied override survives subsequent
      # discovery sweeps.
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

  # Per-chain prefix denylist used at chain_category creation time
  # to default `crawl_enabled` to false for non-grocery branches
  # (toys, home, tech, vestuario, mundo bebé). Add prefixes here as
  # we observe more umbrellas worth excluding. Existing rows are
  # *not* retroactively flipped — only newly-discovered ones.
  @auto_disabled_prefixes %{
    "jumbo" => [
      "hogar-jugueteria-y-libreria/"
    ],
    "lider" => [],
    "santa_isabel" => [],
    "unimarc" => [],
    "tottus" => [],
    "acuenta" => []
  }

  @doc """
  True when a brand-new category should be crawled by default; false
  when its slug matches a denylist prefix for the chain.
  """
  def default_crawl_enabled?(chain, slug) when is_binary(slug) do
    prefixes = Map.get(@auto_disabled_prefixes, to_string(chain), [])
    not Enum.any?(prefixes, &String.starts_with?(slug, &1))
  end

  def default_crawl_enabled?(_chain, _slug), do: true

  @doc """
  Hard-delete every chain_listing linked to `category_id`, clean up
  any newly-orphaned products, and best-effort delete their R2
  thumbnails. Returns `{:ok, %{listings: n, products: m}}` with
  counts of rows actually removed.

  Cascades:
    chain_listings  → chain_listing_categories  (FK delete_all)
                    → product_listings          (FK delete_all)
    products (orphaned) → product_identifiers   (FK delete_all)

  Thumbnail R2 cleanup runs after the transaction commits. Each
  orphaned product's thumbnail embed is walked through
  `Thumbnails.delete_unreferenced/2` so we only delete R2 objects
  whose keys aren't still referenced by some other Product.
  """
  def delete_chain_category_listings(category_id) do
    Repo.transaction(fn ->
      listing_ids =
        Repo.all(
          from clc in ChainListingCategory,
            where: clc.chain_category_id == ^category_id,
            select: clc.chain_listing_id
        )

      if listing_ids == [] do
        %{listings: 0, products: 0, deleted_thumbnails: []}
      else
        candidate_product_ids =
          Repo.all(
            from pl in ProductListing,
              where: pl.chain_listing_id in ^listing_ids,
              distinct: true,
              select: pl.product_id
          )

        {n_listings, _} =
          Repo.delete_all(from l in ChainListing, where: l.id in ^listing_ids)

        # After cascade: products with zero remaining product_listings
        # are now orphans. Capture their thumbnail embeds before delete.
        orphan_rows =
          Repo.all(
            from p in Product,
              left_join: pl in ProductListing,
              on: pl.product_id == p.id,
              where: p.id in ^candidate_product_ids and is_nil(pl.id),
              select: {p.id, p.thumbnail}
          )

        orphan_ids = Enum.map(orphan_rows, &elem(&1, 0))

        {n_products, _} =
          Repo.delete_all(from p in Product, where: p.id in ^orphan_ids)

        thumbnails =
          orphan_rows
          |> Enum.map(&elem(&1, 1))
          |> Enum.reject(&is_nil/1)

        %{listings: n_listings, products: n_products, deleted_thumbnails: thumbnails}
      end
    end)
    |> case do
      {:ok, result} ->
        Enum.each(result.deleted_thumbnails, fn image ->
          Thumbnails.delete_unreferenced(image)
        end)

        {:ok, Map.delete(result, :deleted_thumbnails)}

      other ->
        other
    end
  end

  # Chains whose category slugs are slash-separated breadcrumbs
  # ("hogar/jugueteria/munecas"). For these we walk the path and
  # materialize an ancestor row per segment. Other chains emit
  # opaque slugs (sometimes containing slashes that aren't
  # separators, e.g. tottus's "<id>/<segment>"); those become a
  # single, parent-less row.
  @hierarchical_chains ~w(jumbo santa_isabel)

  @doc """
  Ensures a `chain_categories` row exists for `slug_path` (and, for
  hierarchical chains, for every ancestor). Returns the leaf row's
  id. Stub rows get a name derived from the slug's last segment;
  operators can rename them later via the admin edit page.

  This is the listing-ingest entry point: every listing must end up
  linked to exactly one chain_categories row, and that row must
  exist before the link is written.
  """
  def ensure_chain_category!(chain, slug_path)
      when is_binary(slug_path) and slug_path != "" do
    chain_str = to_string(chain)
    segments = path_segments(chain_str, slug_path)
    do_ensure_path(chain_str, segments, nil, 1)
  end

  defp path_segments(chain, slug_path) do
    if chain in @hierarchical_chains do
      slug_path
      |> String.split("/", trim: true)
      |> accumulate_segments([], "")
    else
      [slug_path]
    end
  end

  defp accumulate_segments([], acc, _prefix), do: Enum.reverse(acc)

  defp accumulate_segments([seg | rest], acc, ""),
    do: accumulate_segments(rest, [seg | acc], seg)

  defp accumulate_segments([seg | rest], acc, prefix) do
    full = prefix <> "/" <> seg
    accumulate_segments(rest, [full | acc], full)
  end

  defp do_ensure_path(_chain, [], leaf_id, _level), do: leaf_id

  defp do_ensure_path(chain, [slug | rest], _prev_id, level) do
    is_leaf = rest == []
    parent_slug = parent_of(slug)
    id = upsert_stub_category!(chain, slug, parent_slug, level, is_leaf)
    do_ensure_path(chain, rest, id, level + 1)
  end

  defp parent_of(slug) do
    case String.split(slug, "/") do
      [_only] -> nil
      parts -> parts |> Enum.drop(-1) |> Enum.join("/")
    end
  end

  defp upsert_stub_category!(chain, slug, parent_slug, level, is_leaf) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      chain: chain,
      slug: slug,
      name: stub_name_from_slug(slug),
      parent_slug: parent_slug,
      level: level,
      is_leaf: is_leaf,
      active: true,
      crawl_enabled: default_crawl_enabled?(chain, slug),
      first_seen_at: now,
      last_seen_at: now
    }

    # On insert: take the stub. On conflict: refresh `last_seen_at`,
    # promote the row to non-leaf if we now know it has a child, but
    # leave name/crawl_enabled/parent_slug/level untouched — the real
    # category-discovery crawl (or the admin edit page) is the source
    # of truth for those.
    on_conflict_set =
      if is_leaf do
        [last_seen_at: now, updated_at: now]
      else
        [is_leaf: false, last_seen_at: now, updated_at: now]
      end

    {:ok, row} =
      %ChainCategory{}
      |> ChainCategory.discovery_changeset(attrs)
      |> Repo.insert(
        on_conflict: [set: on_conflict_set],
        conflict_target: [:chain, :slug],
        returning: true
      )

    row.id
  end

  defp stub_name_from_slug(slug) do
    slug
    |> String.split("/")
    |> List.last()
    |> String.split("-")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @doc """
  Slugs whose entire branch is disabled — either the row itself
  carries `crawl_enabled = false` or one of its ancestors does.
  Walks the parent chain in Elixir off a single SELECT of all the
  chain's categories (per-chain row counts are in the low thousands
  at most, so this is fine).
  """
  def disabled_branch_slugs(chain) do
    chain_str = to_string(chain)

    rows =
      Repo.all(
        from c in ChainCategory,
          where: c.chain == ^chain_str,
          select: {c.slug, c.parent_slug, c.crawl_enabled}
      )

    by_slug = Map.new(rows, fn {slug, parent, enabled} -> {slug, {parent, enabled}} end)

    rows
    |> Enum.filter(fn {slug, _parent, _enabled} ->
      branch_disabled?(slug, by_slug, MapSet.new())
    end)
    |> Enum.map(fn {slug, _, _} -> slug end)
    |> MapSet.new()
  end

  defp branch_disabled?(nil, _by_slug, _seen), do: false

  defp branch_disabled?(slug, by_slug, seen) do
    cond do
      MapSet.member?(seen, slug) ->
        false

      true ->
        case Map.get(by_slug, slug) do
          nil -> false
          {_parent, false} -> true
          {parent, true} -> branch_disabled?(parent, by_slug, MapSet.put(seen, slug))
        end
    end
  end

  @doc """
  Drop every chain_listing whose categories all sit inside a
  disabled branch (self or any ancestor). Listings with no
  category attachments are left alone — those came from earlier
  crawls before we tracked categories and shouldn't be
  collateral damage of a later UI pruning.

  Cascades to product_listings via the FK `on_delete: :delete_all`.
  Returns the deleted-row count.
  """
  def prune_disabled_branch_listings(chain) do
    chain_str = to_string(chain)
    disabled = disabled_branch_slugs(chain) |> MapSet.to_list()

    if disabled == [] do
      0
    else
      with_cats =
        from clc in ChainListingCategory,
          join: cc in ChainCategory,
          on: cc.id == clc.chain_category_id,
          where: cc.chain == ^chain_str,
          distinct: true,
          select: clc.chain_listing_id

      with_enabled =
        from clc in ChainListingCategory,
          join: cc in ChainCategory,
          on: cc.id == clc.chain_category_id,
          where: cc.chain == ^chain_str and cc.slug not in ^disabled,
          distinct: true,
          select: clc.chain_listing_id

      {n, _} =
        Repo.delete_all(
          from cl in ChainListing,
            where: cl.chain == ^chain_str,
            where: cl.id in subquery(with_cats),
            where: cl.id not in subquery(with_enabled)
        )

      n
    end
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
    chain_str = to_string(chain)
    disabled = disabled_branch_slugs(chain) |> MapSet.to_list()

    base =
      ChainCategory
      |> where([c], c.chain == ^chain_str and c.is_leaf == true and c.active == true)

    if disabled == [], do: base, else: where(base, [c], c.slug not in ^disabled)
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
  def upsert_listing(%Listing{category_path: cp})
      when cp in [nil, ""] do
    {:error, :missing_category_path}
  end

  def upsert_listing(%Listing{} = listing) do
    if is_integer(listing.regular_price) and listing.regular_price > 0 do
      # Hot path — most refreshes have a price. Single INSERT…ON
      # CONFLICT statement; no SELECT needed. The category link
      # is written separately after the upsert returns.
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
        last_discovered_at: now,
        active: true,
        has_price: false
      }

    {:ok, updated} =
      row
      |> Ecto.Changeset.change(attrs)
      |> Repo.update()

    link_listing_to_category(updated, incoming.category_path)
    {:ok, :updated, updated}
  end

  # Single-statement INSERT…ON CONFLICT. The on_conflict :replace
  # list rewrites every column on the listing row; the
  # category-link side is handled separately via
  # `link_listing_to_category/2` after the insert returns.
  defp do_priced_upsert(%Listing{} = listing) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

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
      current_regular_price: listing.regular_price,
      current_promo_price: listing.promo_price,
      current_promotions: listing.promotions || %{},
      first_seen_at: now,
      last_discovered_at: now,
      last_priced_at: now,
      active: true,
      has_price: true
    }

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
            updated_at: fragment("excluded.updated_at")
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
        link_listing_to_category(row, listing.category_path)
        {:ok, :upserted, row}

      {:error, _} = err ->
        err
    end
  end

  # Ensures the `chain_categories` row exists for `slug_path` and
  # links it to `listing` via `chain_listing_categories`. The unique
  # index on (chain_listing_id, chain_category_id) absorbs re-runs.
  defp link_listing_to_category(%ChainListing{} = listing, slug_path)
       when is_binary(slug_path) and slug_path != "" do
    cat_id = ensure_chain_category!(listing.chain, slug_path)

    Repo.insert_all(
      ChainListingCategory,
      [%{chain_listing_id: listing.id, chain_category_id: cat_id}],
      on_conflict: :nothing
    )

    :ok
  end

  defp link_listing_to_category(_listing, _), do: :ok

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

  # Filter listings by their `chain_listing_categories` join. Accepts
  # either an exact slug or any descendant — passing an L1 slug
  # matches every listing under it. Descendant matching is a string
  # prefix on `chain_categories.slug`, which works because
  # hierarchical chains (jumbo, santa_isabel) use slash-separated
  # paths; non-hierarchical chains have opaque slugs and will only
  # match exactly, which is the right behavior for them.
  defp apply_category_filter(query, nil), do: query
  defp apply_category_filter(query, ""), do: query

  defp apply_category_filter(query, slug) when is_binary(slug) do
    like = String.replace(slug, "%", "\\%") <> "/%"

    where(
      query,
      [l],
      fragment(
        "EXISTS (SELECT 1 FROM chain_listing_categories clc JOIN chain_categories cc ON cc.id = clc.chain_category_id WHERE clc.chain_listing_id = ? AND (cc.slug = ? OR cc.slug LIKE ?))",
        l.id,
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
      |> apply_cat_crawl_filter(opts[:crawl])

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

  defp apply_cat_crawl_filter(query, :enabled), do: where(query, [c], c.crawl_enabled == true)
  defp apply_cat_crawl_filter(query, :disabled), do: where(query, [c], c.crawl_enabled == false)
  defp apply_cat_crawl_filter(query, _), do: query

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

  @stop_words ~w(de la el en y con sin los las del al por para su sus a un una uno mas
                 que se lo le mi tu nos vos como una es son sea ser sin de)
  @unit_words ~w(g kg mg ml cl cc lt l un mt cm km oz lb lbs pack pcs unid uns un)

  @doc """
  Most-frequent meaningful words across the canonical_name + brand
  fields of products matching the given filters. Used to power the
  suggestion chips below the search bar.

  Opts:
    * `:q` — full-text search filter (same FTS5 path as `list_products_page/1`)
    * `:cat` / `:sub` — app taxonomy filters
    * `:n` — how many `{term, count}` tuples to return (default 8)
    * `:scan_limit` — cap on rows scanned, ordered by `chain_count`
      desc so popular products dominate the sample (default 1_000)

  Tokenization is intentionally simple: lowercase, strip non-letters,
  drop stop-words, unit-words, anything ≤ 2 chars, and pure numbers.
  Tokens already present in `:q` are excluded so the user's query
  isn't echoed back as a chip.
  """
  def popular_terms(opts \\ []) do
    q = opts[:q]
    cat = opts[:cat]
    sub = opts[:sub]
    n = opts[:n] || 8
    scan_limit = opts[:scan_limit] || 1_000
    fts_q = fts_query(q)

    rows =
      Product
      |> apply_product_q_filter(q, fts_q)
      |> apply_product_app_category_filter(cat)
      |> apply_product_app_subcategory_filter(sub)
      |> order_by([p], desc: p.chain_count)
      |> limit(^scan_limit)
      |> select([p], {p.canonical_name, p.brand})
      |> Repo.all()

    exclude = MapSet.new(tokenize(q))

    rows
    |> Enum.flat_map(fn {name, brand} ->
      tokenize(name) ++ tokenize(brand)
    end)
    |> Enum.reject(&MapSet.member?(exclude, &1))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_t, c} -> -c end)
    |> Enum.take(n)
  end

  defp tokenize(nil), do: []
  defp tokenize(""), do: []

  defp tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.reject(fn t ->
      String.length(t) < 3 or
        t in @stop_words or
        t in @unit_words or
        Regex.match?(~r/^\d+$/, t)
    end)
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
  Per-category previews for the index empty state: each category
  with its top `per_cat` cross-chain products (ordered by
  chain_count desc). Categories with zero matching products are
  dropped so the index doesn't render empty sections.
  """
  def category_previews(per_cat \\ 6) do
    for c <- Repo.all(from a in AppCategory, order_by: [asc: a.position, asc: a.name]) do
      products =
        Product
        |> apply_product_app_category_filter(c.slug)
        |> order_by([p], desc: p.chain_count, desc: p.id)
        |> limit(^per_cat)
        |> Repo.all()

      %{slug: c.slug, name: c.name, products: products}
    end
    |> Enum.reject(&(&1.products == []))
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
