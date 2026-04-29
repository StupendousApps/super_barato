defmodule SuperBarato.Catalog.ChainListingCategory do
  @moduledoc """
  Join row tying a `ChainListing` to a `ChainCategory`. Replaces the
  legacy `chain_listings.category_paths` JSON-array-of-slugs — same
  many-to-many relationship, but normalized so we get FK integrity
  and proper joins.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SuperBarato.Catalog.{ChainCategory, ChainListing}

  schema "chain_listing_categories" do
    belongs_to :chain_listing, ChainListing
    belongs_to :chain_category, ChainCategory
  end

  @fields ~w(chain_listing_id chain_category_id)a

  def changeset(row, attrs) do
    row
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> assoc_constraint(:chain_listing)
    |> assoc_constraint(:chain_category)
    |> unique_constraint([:chain_listing_id, :chain_category_id])
  end
end
