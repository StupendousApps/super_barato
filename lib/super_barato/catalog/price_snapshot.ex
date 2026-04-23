defmodule SuperBarato.Catalog.PriceSnapshot do
  use Ecto.Schema
  import Ecto.Changeset

  alias SuperBarato.Catalog.ChainListing

  @primary_key {:id, :id, autogenerate: true}
  schema "price_snapshots" do
    field :regular_price, :integer
    field :promo_price, :integer
    field :promotions, :map, default: %{}
    field :captured_at, :utc_datetime

    belongs_to :chain_listing, ChainListing
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:chain_listing_id, :regular_price, :promo_price, :promotions, :captured_at])
    |> validate_required([:chain_listing_id, :regular_price, :captured_at])
    |> foreign_key_constraint(:chain_listing_id)
  end
end
