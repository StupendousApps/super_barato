defmodule SuperBarato.Catalog.Product do
  use Ecto.Schema
  import Ecto.Changeset

  schema "products" do
    field :ean, :string
    field :canonical_name, :string
    field :brand, :string
    field :image_url, :string

    # No direct association to chain_listings — the link lives in
    # `product_listings`, owned by SuperBarato.Linker. Use
    # `Linker.listings_for_product/1` to fetch the listings, or
    # `Linker.links_for_product/1` for the join metadata.

    timestamps(type: :utc_datetime)
  end

  def changeset(product, attrs) do
    product
    |> cast(attrs, [:ean, :canonical_name, :brand, :image_url])
    |> validate_required([:canonical_name])
    |> unique_constraint(:ean)
  end
end
