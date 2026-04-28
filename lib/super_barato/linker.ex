defmodule SuperBarato.Linker do
  @moduledoc """
  Owns the link between `Catalog.Product` (canonical identity) and
  `Catalog.ChainListing` (per-chain SKU rows). The crawler never
  touches this table; linking is a separate process that can be
  re-run, undone, and audited without disturbing the discovery side.

  All writes to `product_listings` go through this module.

  ## Link sources

  Every `product_listings` row carries a `source` tag describing how
  the link was created. Canonical values:

    * `"ean_canonical"` — the listing's canonicalized GTIN-13 / EAN-8
      matched a Product's identifier in `product_identifiers`. High
      confidence; produced live by `Linker.Worker`.
    * `"single_chain"` — listing has no usable EAN (Tottus's loose
      meat, produce sold by weight, anything where the chain doesn't
      expose a barcode). Each such listing gets a placeholder Product
      with only the per-chain `<chain>_sku` identifier; admin or a
      future fuzzy pass can
      merge these into canonical Products via `merge_products/2`.
    * `"admin"` — a human curator linked the pair through the admin
      UI (`Linker.link_admin/2`). High confidence by definition;
      used to fix or supplement what `ean_canonical` couldn't reach
      (cross-country dupes, granel items, missing EANs).

  Free-form for future passes (`"fuzzy_name"`, `"image_match"`, …)
  so we can grow strategies without a migration. `Linker.sources/0`
  is the live list of values that have been used in the DB.
  """

  import Ecto.Query

  alias SuperBarato.Catalog
  alias SuperBarato.Catalog.{ChainListing, Product, ProductIdentifier}
  alias SuperBarato.Linker.{Identity, ProductListing}
  alias SuperBarato.Repo

  @source_ean_canonical "ean_canonical"
  @source_single_chain "single_chain"
  @source_admin "admin"

  @doc "Canonical source-tag constants. See module docs."
  def source_ean_canonical, do: @source_ean_canonical
  def source_single_chain, do: @source_single_chain
  def source_admin, do: @source_admin

  @doc """
  Derive the typed identifiers a listing brings into the lookup
  table, ordered by priority: GS1 EANs first (cross-chain), then the
  per-chain SKU. Anything that doesn't canonicalize / is missing is
  silently dropped. Each tuple is `{kind, value}`.

  Priority matters: when looking up an existing Product we want to
  match on the **strongest** identifier first so a single-chain
  placeholder can be folded into the canonical EAN-keyed Product
  the moment the listing acquires an EAN.
  """
  @spec identifiers_for_listing(ChainListing.t()) :: [{String.t(), String.t()}]
  def identifiers_for_listing(%ChainListing{} = l) do
    ean_id =
      cond do
        e = Identity.canonicalize_gtin13(l.ean) -> [{"ean_13", e}]
        e = Identity.canonicalize_ean8(l.ean) -> [{"ean_8", e}]
        true -> []
      end

    sku_id =
      if is_binary(l.chain_sku) and l.chain_sku != "" and is_binary(l.chain) do
        [{"#{l.chain}_sku", l.chain_sku}]
      else
        []
      end

    ean_id ++ sku_id
  end

  def identifiers_for_listing(_), do: []

  @doc """
  Find-or-create a Product for the given listing's identifiers.
  Returns `{:created | :existed, %Product{}, source_tag}` where
  `source_tag` is `"ean_canonical"` if the match/creation was anchored
  on a GS1 EAN, or `"single_chain"` if only a per-chain SKU was
  available.

  Walks `identifiers_for_listing/1` in priority order:

    1. If any identifier already exists in `product_identifiers`, use
       that Product. Attach every other identifier the listing brings
       (idempotent insert-on-conflict — multiple Products with the
       same identifier is impossible by the unique index, but two
       listings can independently bring the same identifier without
       conflict).
    2. Otherwise insert a new Product seeded from the listing and
       attach all identifiers in one go.
  """
  def find_or_create_product_for_listing(%ChainListing{} = listing) do
    ids = identifiers_for_listing(listing)
    source = source_for(ids)

    {action, product} =
      case Enum.find_value(ids, fn {k, v} -> Catalog.get_product_by_identifier(k, v) end) do
        %Product{} = p ->
          attach_missing_identifiers(p, ids)
          {:existed, p}

        nil ->
          {:created, create_product_with_identifiers(listing, ids)}
      end

    {action, product, source}
  end

  defp source_for([{"ean_13", _} | _]), do: @source_ean_canonical
  defp source_for([{"ean_8", _} | _]), do: @source_ean_canonical
  defp source_for(_), do: @source_single_chain

  defp create_product_with_identifiers(%ChainListing{} = listing, ids) do
    attrs = %{
      canonical_name: listing.name || "(unnamed)",
      brand: listing.brand,
      image_url: listing.image_url
    }

    Repo.transaction(fn ->
      {:ok, product} = %Product{} |> Product.changeset(attrs) |> Repo.insert()

      Enum.each(ids, fn {k, v} ->
        %ProductIdentifier{}
        |> ProductIdentifier.changeset(%{product_id: product.id, kind: k, value: v})
        |> Repo.insert!()
      end)

      product
    end)
    |> case do
      {:ok, p} -> p
    end
  end

  defp attach_missing_identifiers(%Product{} = p, ids) do
    Enum.each(ids, fn {k, v} ->
      case Catalog.get_product_by_identifier(k, v) do
        nil ->
          %ProductIdentifier{}
          |> ProductIdentifier.changeset(%{product_id: p.id, kind: k, value: v})
          |> Repo.insert(
            on_conflict: :nothing,
            conflict_target: [:kind, :value]
          )

        _ ->
          :already_attached
      end
    end)
  end

  @doc """
  Atomically set the Product link for a listing. Replaces any
  pre-existing `product_listings` rows for the listing (a listing
  belongs to **at most one** Product), inserts/upserts the new one,
  and orphan-cleans previously-linked Products that lose their last
  listing.

  Idempotent — re-setting to the same Product is a no-op apart from
  refreshing `source`/`confidence`/`linked_at`.

  This is the only safe writer for an automatically-derived link;
  use `link/3` only when you genuinely want multiple-link semantics
  (admin draft scoring, etc.).
  """
  def set_listing_link(product_id, chain_listing_id, opts \\ [])
      when is_integer(product_id) and is_integer(chain_listing_id) do
    Repo.transaction(fn ->
      orphan_candidates =
        from(pl in ProductListing,
          where:
            pl.chain_listing_id == ^chain_listing_id and pl.product_id != ^product_id,
          select: pl.product_id
        )
        |> Repo.all()
        |> Enum.uniq()

      from(pl in ProductListing,
        where:
          pl.chain_listing_id == ^chain_listing_id and pl.product_id != ^product_id
      )
      |> Repo.delete_all()

      result =
        case link(product_id, chain_listing_id, opts) do
          {:ok, row} -> row
          {:error, cs} -> Repo.rollback(cs)
        end

      Enum.each(orphan_candidates, &delete_if_orphan/1)
      result
    end)
  end

  @doc """
  Link a product to a chain_listing. Idempotent — re-linking the same
  pair updates `source`/`confidence`/`linked_at` instead of failing.

  ## Options

    * `:source`     — string tag, defaults to `"manual"`.
    * `:confidence` — float `0.0..1.0`, optional.
    * `:linked_at`  — defaults to `DateTime.utc_now/0`.
  """
  def link(product_id, chain_listing_id, opts \\ []) do
    attrs = %{
      product_id: product_id,
      chain_listing_id: chain_listing_id,
      source: Keyword.get(opts, :source, "manual"),
      confidence: Keyword.get(opts, :confidence),
      linked_at: Keyword.get(opts, :linked_at, DateTime.utc_now() |> DateTime.truncate(:second))
    }

    %ProductListing{}
    |> ProductListing.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:source, :confidence, :linked_at]},
      conflict_target: [:product_id, :chain_listing_id]
    )
  end

  @doc """
  Admin-curated link. Replaces any pre-existing link the
  chain_listing has — a chain_listing belongs to **at most one**
  product, and an admin pick is the authoritative override. Any
  previously-linked product that ends up with zero listings is
  hard-deleted so it doesn't pollute the products list.
  """
  def link_admin(product_id, chain_listing_id) do
    set_listing_link(product_id, chain_listing_id,
      source: @source_admin,
      confidence: 1.0
    )
  end

  @doc """
  Merge `source_id` into `target_id`: reattach every
  `product_identifiers` row + `product_listings` row from source to
  target, then delete the source product (cascade clears anything
  left). Idempotent on collisions: if both products already share a
  `(kind, value)` identifier or a chain_listing, the source's row is
  dropped (target's is the surviving truth).
  """
  def merge_products(target_id, source_id)
      when is_integer(target_id) and is_integer(source_id) and target_id != source_id do
    Repo.transaction(fn ->
      target = Repo.get!(Product, target_id)
      source = Repo.get!(Product, source_id)

      # Reparent identifiers, dropping any source row whose (kind,
      # value) is already on target (the unique index would otherwise
      # block the update).
      target_identifier_keys =
        from(pi in ProductIdentifier,
          where: pi.product_id == ^target.id,
          select: {pi.kind, pi.value}
        )
        |> Repo.all()
        |> MapSet.new()

      from(pi in ProductIdentifier, where: pi.product_id == ^source.id)
      |> Repo.all()
      |> Enum.each(fn pi ->
        if MapSet.member?(target_identifier_keys, {pi.kind, pi.value}) do
          Repo.delete!(pi)
        else
          pi |> Ecto.Changeset.change(product_id: target.id) |> Repo.update!()
        end
      end)

      # Reparent product_listings, preferring target's existing row when
      # both products share a chain_listing.
      target_listing_ids =
        from(pl in ProductListing,
          where: pl.product_id == ^target.id,
          select: pl.chain_listing_id
        )
        |> Repo.all()

      if target_listing_ids != [] do
        from(pl in ProductListing,
          where:
            pl.product_id == ^source.id and pl.chain_listing_id in ^target_listing_ids
        )
        |> Repo.delete_all()
      end

      from(pl in ProductListing, where: pl.product_id == ^source.id)
      |> Repo.update_all(set: [product_id: target.id])

      Repo.delete!(source)
      target
    end)
  end

  @doc """
  Remove the link between a product and a chain_listing. If the
  product is left with zero listings, it's hard-deleted (cascades
  through `product_identifiers`).
  """
  def unlink(product_id, chain_listing_id) do
    Repo.transaction(fn ->
      {n, _} =
        from(pl in ProductListing,
          where: pl.product_id == ^product_id and pl.chain_listing_id == ^chain_listing_id
        )
        |> Repo.delete_all()

      if n > 0 do
        delete_if_orphan(product_id)
        :ok
      else
        :not_found
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Sweep every Product with zero `product_listings` and hard-delete it.
  Returns the number of deleted Products.

  Run once after a worker bug to clean up any Products that were
  created without a corresponding link (`set_listing_link` rolling
  back after `find_or_create_product_for_listing` had already
  committed). Safe to re-run — picks up exactly the orphans, no
  false positives, no listings touched.
  """
  def sweep_orphan_products do
    orphan_ids =
      from(p in Product,
        left_join: pl in ProductListing,
        on: pl.product_id == p.id,
        where: is_nil(pl.id),
        select: p.id
      )
      |> Repo.all()

    {n, _} =
      from(p in Product, where: p.id in ^orphan_ids)
      |> Repo.delete_all()

    n
  end

  @doc """
  Delete `product_id` if no `product_listings` rows reference it.
  Returns `:deleted` or `:kept`. Cascades through `product_identifiers`
  via the FK `on_delete: :delete_all`.
  """
  def delete_if_orphan(product_id) when is_integer(product_id) or is_binary(product_id) do
    count =
      Repo.aggregate(
        from(pl in ProductListing, where: pl.product_id == ^product_id),
        :count
      )

    if count == 0 do
      case Repo.get(Product, product_id) do
        nil -> :kept
        product ->
          Repo.delete!(product)
          :deleted
      end
    else
      :kept
    end
  end

  @doc "All chain_listings linked to the given product."
  def listings_for_product(product_id) do
    from(l in ChainListing,
      join: pl in ProductListing,
      on: pl.chain_listing_id == l.id,
      where: pl.product_id == ^product_id,
      order_by: [asc: l.chain]
    )
    |> Repo.all()
  end

  @doc "All products linked to the given chain_listing."
  def products_for_listing(chain_listing_id) do
    from(p in Product,
      join: pl in ProductListing,
      on: pl.product_id == p.id,
      where: pl.chain_listing_id == ^chain_listing_id
    )
    |> Repo.all()
  end

  @doc "Raw join rows for a product (with source/confidence/linked_at)."
  def links_for_product(product_id) do
    from(pl in ProductListing, where: pl.product_id == ^product_id)
    |> Repo.all()
  end

  @doc """
  `%{product_id => {min_eff, max_eff}}` for the given product ids,
  computed across each product's linked listings using the effective
  current price (promo if it beats regular, else regular). Listings
  with no current_regular_price contribute nothing. Products with no
  priced listings are absent from the map.
  """
  def price_range_by_product_ids(product_ids) when is_list(product_ids) do
    from(pl in ProductListing,
      join: l in ChainListing,
      on: l.id == pl.chain_listing_id,
      where: pl.product_id in ^product_ids and not is_nil(l.current_regular_price),
      select: {pl.product_id, l.current_regular_price, l.current_promo_price}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {pid, reg, promo}, acc ->
      eff =
        if is_integer(promo) and is_integer(reg) and promo < reg, do: promo, else: reg

      Map.update(acc, pid, {eff, eff}, fn {min_p, max_p} ->
        {min(min_p, eff), max(max_p, eff)}
      end)
    end)
  end

  @doc """
  `%{product_id => [chain_atom, ...]}` for the given product ids —
  every distinct chain a product is linked on, in alphabetical order.
  Used by the listings index to show small chain-badge stacks under
  the linked product's name.
  """
  def chains_by_product_ids(product_ids) when is_list(product_ids) do
    from(pl in ProductListing,
      join: l in ChainListing,
      on: l.id == pl.chain_listing_id,
      where: pl.product_id in ^product_ids,
      distinct: true,
      select: {pl.product_id, l.chain}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {pid, chain}, acc ->
      atom = String.to_atom(chain)
      Map.update(acc, pid, [atom], &[atom | &1])
    end)
    |> Enum.map(fn {pid, chains} -> {pid, Enum.sort(chains)} end)
    |> Map.new()
  end

  @doc """
  `%{chain_listing_id => source}` for every link on a product. Used
  by the product show page to show the provenance of each row in
  the linked-listings table.
  """
  def sources_by_listing(product_id) do
    from(pl in ProductListing,
      where: pl.product_id == ^product_id,
      select: {pl.chain_listing_id, pl.source}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Bulk inverse lookup: given a list of `product_id`s, returns
  `%{product_id => [%ChainListing{}, ...]}` covering every linked
  listing. Used by the admin products table to render per-chain
  price columns in a single query.
  """
  def listings_by_product_ids(product_ids) when is_list(product_ids) do
    from(pl in ProductListing,
      join: l in ChainListing,
      on: pl.chain_listing_id == l.id,
      where: pl.product_id in ^product_ids,
      select: {pl.product_id, l}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {product_id, listing}, acc ->
      Map.update(acc, product_id, [listing], &[listing | &1])
    end)
  end

  @doc """
  Bulk lookup: given a list of `chain_listing_id`s, returns
  `%{listing_id => %Product{}}` for those that have at least one
  product link. Used by the admin listings table to display the
  current product attached to each row in a single query.

  When a listing has multiple links (rare; future-fuzzy-match world),
  one product is picked at random — admin pages flag this case.
  """
  def products_by_listing_ids(listing_ids) when is_list(listing_ids) do
    from(pl in ProductListing,
      join: p in Product,
      on: p.id == pl.product_id,
      where: pl.chain_listing_id in ^listing_ids,
      select: {pl.chain_listing_id, p}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {listing_id, product}, acc ->
      Map.put_new(acc, listing_id, product)
    end)
  end
end
