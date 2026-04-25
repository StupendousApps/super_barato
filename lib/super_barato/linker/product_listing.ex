defmodule SuperBarato.Linker.ProductListing do
  @moduledoc """
  Join row connecting a `Catalog.Product` to a `Catalog.ChainListing`.

  Owned exclusively by `SuperBarato.Linker` — neither the crawler nor
  the Catalog context writes to this table. That separation is the
  whole point: discovery (chain_listings) and identity (products) stay
  decoupled, and re-running the linker doesn't risk corrupting either
  side.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias SuperBarato.Catalog.{ChainListing, Product}

  schema "product_listings" do
    belongs_to :product, Product
    belongs_to :chain_listing, ChainListing

    # Free-form tag describing how the link was made: "manual",
    # "ean_match", "name_match", … grow this without a migration.
    field :source, :string, default: "manual"

    # Optional confidence score for fuzzy matchers (0.0–1.0).
    field :confidence, :float

    field :linked_at, :utc_datetime
  end

  @fields ~w(product_id chain_listing_id source confidence linked_at)a

  def changeset(link, attrs) do
    link
    |> cast(attrs, @fields)
    |> validate_required([:product_id, :chain_listing_id, :source, :linked_at])
    |> validate_number(:confidence,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> unique_constraint([:product_id, :chain_listing_id])
    |> foreign_key_constraint(:product_id)
    |> foreign_key_constraint(:chain_listing_id)
  end
end
