defmodule SuperBarato.Catalog do
  @moduledoc """
  Persistence for discovered listings and price snapshots.
  """

  import Ecto.Query

  alias SuperBarato.Catalog.{ChainListing, PriceSnapshot}
  alias SuperBarato.Repo

  @doc """
  Upserts a discovered listing by (chain, chain_sku). Sets `first_seen_at` on
  insert and `last_discovered_at` on update.
  """
  def upsert_listing(attrs) when is_map(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      attrs
      |> Map.put(:first_seen_at, now)
      |> Map.put(:last_discovered_at, now)
      |> Map.put_new(:active, true)

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
  def record_price(%ChainListing{} = listing, attrs) when is_map(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    attrs = Map.put_new(attrs, :captured_at, now)

    Repo.transaction(fn ->
      {:ok, snapshot} =
        %PriceSnapshot{}
        |> PriceSnapshot.changeset(Map.put(attrs, :chain_listing_id, listing.id))
        |> Repo.insert()

      {:ok, updated} =
        listing
        |> ChainListing.price_changeset(%{
          current_regular_price: attrs[:regular_price],
          current_promo_price: attrs[:promo_price],
          current_promotions: attrs[:promotions] || %{},
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
