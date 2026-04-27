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

    * `"ean_canonical"` — `Linker.Backfill` matched the listing's
      canonicalized GTIN-13 against a Product's `ean`. High
      confidence; produced in bulk.
    * `"admin"` — a human curator linked the pair through the admin
      UI (`Linker.link_admin/2`). High confidence by definition;
      used to fix or supplement what `ean_canonical` couldn't reach
      (cross-country dupes, granel items, missing EANs).

  Free-form for future passes (`"fuzzy_name"`, `"image_match"`, …)
  so we can grow strategies without a migration. `Linker.sources/0`
  is the live list of values that have been used in the DB.
  """

  import Ecto.Query

  alias SuperBarato.Catalog.{ChainListing, Product, ProductEan}
  alias SuperBarato.Linker.ProductListing
  alias SuperBarato.Repo

  @source_ean_canonical "ean_canonical"
  @source_admin "admin"

  @doc "Canonical source-tag constants. See module docs."
  def source_ean_canonical, do: @source_ean_canonical
  def source_admin, do: @source_admin

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
  product, and an admin pick is the authoritative override.
  """
  def link_admin(product_id, chain_listing_id) do
    Repo.transaction(fn ->
      from(pl in ProductListing,
        where:
          pl.chain_listing_id == ^chain_listing_id and pl.product_id != ^product_id
      )
      |> Repo.delete_all()

      case link(product_id, chain_listing_id, source: @source_admin, confidence: 1.0) do
        {:ok, row} -> row
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  @doc """
  Merge `source_id` into `target_id`: reattach every `product_eans`
  row + `product_listings` row from source to target, then delete
  the source product (cascade clears anything left). Idempotent on
  collisions: if both products already share a chain_listing, the
  source's link is dropped (target's is the surviving truth).
  """
  def merge_products(target_id, source_id)
      when is_integer(target_id) and is_integer(source_id) and target_id != source_id do
    Repo.transaction(fn ->
      target = Repo.get!(Product, target_id)
      source = Repo.get!(Product, source_id)

      # Reparent EANs.
      from(pe in ProductEan, where: pe.product_id == ^source.id)
      |> Repo.update_all(set: [product_id: target.id])

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

  @doc "Remove the link between a product and a chain_listing."
  def unlink(product_id, chain_listing_id) do
    from(pl in ProductListing,
      where: pl.product_id == ^product_id and pl.chain_listing_id == ^chain_listing_id
    )
    |> Repo.delete_all()
    |> case do
      {0, _} -> :not_found
      {_, _} -> :ok
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
