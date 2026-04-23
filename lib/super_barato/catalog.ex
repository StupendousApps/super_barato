defmodule SuperBarato.Catalog do
  @moduledoc """
  Persistence for discovered listings and price snapshots.

  Accepts plain structs from the crawler layer (`Crawler.Listing`,
  `Crawler.Price`) and converts them to DB rows.
  """

  import Ecto.Query

  alias SuperBarato.Catalog.{ChainListing, PriceSnapshot}
  alias SuperBarato.Crawler.{Listing, Price}
  alias SuperBarato.Repo

  @doc """
  Upserts a discovered listing by (chain, chain_sku). Sets `first_seen_at`
  on insert and `last_discovered_at` on update.
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
  Writes a price snapshot and updates the listing's current price columns.
  """
  def record_price(%ChainListing{} = listing, %Price{} = price) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      {:ok, snapshot} =
        %PriceSnapshot{}
        |> PriceSnapshot.changeset(%{
          chain_listing_id: listing.id,
          regular_price: price.regular_price,
          promo_price: price.promo_price,
          promotions: price.promotions || %{},
          captured_at: now
        })
        |> Repo.insert()

      {:ok, updated} =
        listing
        |> ChainListing.price_changeset(%{
          current_regular_price: price.regular_price,
          current_promo_price: price.promo_price,
          current_promotions: price.promotions || %{},
          last_priced_at: now
        })
        |> Repo.update()

      {updated, snapshot}
    end)
  end

  @doc """
  Active chain_skus for a chain, for price refreshes.
  """
  def active_listings(chain) do
    ChainListing
    |> where([l], l.chain == ^to_string(chain) and l.active == true)
    |> Repo.all()
  end

  def get_listing(chain, chain_sku) do
    Repo.get_by(ChainListing, chain: to_string(chain), chain_sku: chain_sku)
  end
end
