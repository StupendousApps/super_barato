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

  alias SuperBarato.Catalog.{Category, ChainListing}
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

    attrs = %{
      chain: to_string(listing.chain),
      chain_sku: listing.chain_sku,
      chain_product_id: listing.chain_product_id,
      ean: listing.ean,
      name: listing.name,
      brand: listing.brand,
      image_url: listing.image_url,
      pdp_url: listing.pdp_url,
      category_path: listing.category_path,
      current_regular_price: listing.regular_price,
      current_promo_price: listing.promo_price,
      current_promotions: listing.promotions || %{},
      first_seen_at: now,
      last_discovered_at: now,
      active: true
    }

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
           :category_path,
           :pdp_url,
           :current_regular_price,
           :current_promo_price,
           :current_promotions,
           :last_discovered_at,
           :active,
           :updated_at
         ]},
      conflict_target: [:chain, :chain_sku],
      returning: true
    )
  end

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
end
