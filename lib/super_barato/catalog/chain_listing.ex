defmodule SuperBarato.Catalog.ChainListing do
  use Ecto.Schema
  import Ecto.Changeset

  schema "chain_listings" do
    field :chain, :string
    field :chain_sku, :string
    field :chain_product_id, :string

    # Identity key — `Linker.Identity.encode/1` over the id-shaped
    # subset of `raw` (SKU, EAN, UPC, GTINs, …). The unique index
    # lives on (chain, identifiers_key); any change to the id set
    # produces a different key and a fresh row.
    field :identifiers_key, :string

    # Convenience denormalization of one well-known id key so the
    # admin EAN filter / sort work without a JSON path expression.
    # Projection of `raw`, not separate truth.
    field :ean, :string

    # Per-listing display + state (independent of identity).
    field :name, :string
    field :brand, :string
    field :image_url, :string
    field :category_path, :string
    field :pdp_url, :string

    # Everything else the chain sent — descriptions, ratings, the
    # breadcrumb node, offers, images, etc. Source of truth for any
    # field not denormalized above.
    field :raw, :map, default: %{}

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
    chain chain_sku chain_product_id
    identifiers_key
    ean name brand image_url category_path pdp_url
    raw
    current_regular_price current_promo_price current_promotions
    last_discovered_at last_priced_at first_seen_at active
  )a

  def discovery_changeset(listing, attrs) do
    listing
    |> cast(attrs, @discovery_fields)
    |> validate_required([:chain, :chain_sku, :name, :first_seen_at, :identifiers_key])
    |> unique_constraint([:chain, :identifiers_key],
      name: :chain_listings_chain_identifiers_key_index
    )
  end

  @price_fields ~w(current_regular_price current_promo_price current_promotions last_priced_at)a

  def price_changeset(listing, attrs) do
    listing
    |> cast(attrs, @price_fields)
    |> validate_required([:current_regular_price, :last_priced_at])
  end
end
