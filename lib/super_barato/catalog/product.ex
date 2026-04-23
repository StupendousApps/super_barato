defmodule SuperBarato.Catalog.Product do
  use Ecto.Schema
  import Ecto.Changeset

  alias SuperBarato.Catalog.ChainListing

  schema "products" do
    field :ean, :string
    field :canonical_name, :string
    field :brand, :string
    field :image_url, :string

    has_many :chain_listings, ChainListing

    timestamps(type: :utc_datetime)
  end

  def changeset(product, attrs) do
    product
    |> cast(attrs, [:ean, :canonical_name, :brand, :image_url])
    |> validate_required([:canonical_name])
    |> unique_constraint(:ean)
  end
end
