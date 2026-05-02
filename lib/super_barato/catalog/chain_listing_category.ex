defmodule SuperBarato.Catalog.ChainListingCategory do
  @moduledoc """
  Join row tying a `ChainListing` to a `ChainCategory` — the
  source of truth for which category surfaces a listing was
  discovered through.
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
