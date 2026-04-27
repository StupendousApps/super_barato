defmodule SuperBarato.Catalog.Product do
  use Ecto.Schema
  import Ecto.Changeset

  alias SuperBarato.Catalog.ProductEan

  schema "products" do
    field :canonical_name, :string
    field :brand, :string
    field :image_url, :string

    # Many GS1-assigned GTINs may resolve to the same conceptual
    # product — e.g. Old Spice Pure Sport 50g exists with both a
    # Mexican (`750…`) and a US (`002…`) GTIN. The linker indexes on
    # the EAN side; the product is the conceptual identity.
    has_many :product_eans, ProductEan

    # No direct association to chain_listings — the link lives in
    # `product_listings`, owned by SuperBarato.Linker. Use
    # `Linker.listings_for_product/1` to fetch the listings, or
    # `Linker.links_for_product/1` for the join metadata.

    timestamps(type: :utc_datetime)
  end

  def changeset(product, attrs) do
    product
    |> cast(attrs, [:canonical_name, :brand, :image_url])
    |> validate_required([:canonical_name])
  end
end
