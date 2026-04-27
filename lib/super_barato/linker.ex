defmodule SuperBarato.Linker do
  @moduledoc """
  Owns the link between `Catalog.Product` (canonical identity) and
  `Catalog.ChainListing` (per-chain SKU rows). The crawler never
  touches this table; linking is a separate process that can be
  re-run, undone, and audited without disturbing the discovery side.

  All writes to `product_listings` go through this module.
  """

  import Ecto.Query

  alias SuperBarato.Catalog.{ChainListing, Product}
  alias SuperBarato.Linker.ProductListing
  alias SuperBarato.Repo

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
