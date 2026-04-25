defmodule SuperBarato.Catalog.ChainListing do
  use Ecto.Schema
  import Ecto.Changeset

  schema "chain_listings" do
    field :chain, :string
    field :chain_sku, :string
    field :chain_product_id, :string

    field :ean, :string
    field :name, :string
    field :brand, :string
    field :image_url, :string
    field :category_path, :string
    field :pdp_url, :string

    field :current_regular_price, :integer
    field :current_promo_price, :integer
    field :current_promotions, :map, default: %{}

    field :first_seen_at, :utc_datetime
    field :last_discovered_at, :utc_datetime
    field :last_priced_at, :utc_datetime
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @discovery_fields ~w(
    chain chain_sku chain_product_id ean name brand image_url
    category_path pdp_url current_regular_price current_promo_price
    current_promotions last_discovered_at first_seen_at active
  )a

  def discovery_changeset(listing, attrs) do
    listing
    |> cast(attrs, @discovery_fields)
    |> validate_required([:chain, :chain_sku, :name, :first_seen_at])
    |> unique_constraint([:chain, :chain_sku])
  end

  @price_fields ~w(current_regular_price current_promo_price current_promotions last_priced_at)a

  def price_changeset(listing, attrs) do
    listing
    |> cast(attrs, @price_fields)
    |> validate_required([:current_regular_price, :last_priced_at])
  end
end
