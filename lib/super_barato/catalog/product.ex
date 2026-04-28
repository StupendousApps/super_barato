defmodule SuperBarato.Catalog.Product do
  use Ecto.Schema
  import Ecto.Changeset

  alias SuperBarato.Catalog.ProductIdentifier

  schema "products" do
    field :canonical_name, :string
    field :brand, :string
    field :image_url, :string

    # Typed identifiers anchoring this Product. A single Product can
    # carry many — cross-country GTIN dupes (`ean_13`/`ean_8`), and
    # any number of per-chain SKUs (`tottus_sku`, `lider_sku`, …) that
    # accumulate as listings observe the product over time. Lookup is
    # via `(kind, value)`, unique-indexed; see Catalog.ProductIdentifier.
    has_many :product_identifiers, ProductIdentifier

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
