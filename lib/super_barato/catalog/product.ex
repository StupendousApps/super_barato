defmodule SuperBarato.Catalog.Product do
  use Ecto.Schema
  import Ecto.Changeset

  alias SuperBarato.Catalog.{AppSubcategory, ProductIdentifier}

  schema "products" do
    field :canonical_name, :string
    field :brand, :string
    field :image_url, :string

    # Pre-rendered thumbnail variants on R2, managed by
    # `StupendousThumbnails`. Currently a single 400-px WebP per
    # product; structured to grow into multi-size fan-out without a
    # schema change. Home cards prefer the embed when set, falling
    # back to `image_url` otherwise.
    embeds_one :thumbnail, StupendousThumbnails.Image, on_replace: :update

    # Denormalized count of distinct chains carrying any listing
    # linked to this product. Maintained by SQLite triggers on
    # `product_listings` (insert/delete/move) — see the FTS5
    # migration. Powers the search ranking boost so cross-chain
    # products surface above one-off store-only items.
    field :chain_count, :integer, default: 0

    # Optional manual taxonomy override. When set it wins over the
    # consensus categorization derived from the product's chain
    # listings (see Catalog.categories_by_product_ids/1). The category
    # follows from the subcategory's `app_category` parent.
    belongs_to :app_subcategory, AppSubcategory

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
    |> cast(attrs, [:canonical_name, :brand, :image_url, :app_subcategory_id])
    |> cast_embed(:thumbnail, with: &StupendousThumbnails.Image.changeset/2)
    |> validate_required([:canonical_name])
  end
end
