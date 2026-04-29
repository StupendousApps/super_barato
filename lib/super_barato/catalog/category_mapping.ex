defmodule SuperBarato.Catalog.CategoryMapping do
  @moduledoc """
  Links a `ChainCategory` to a unified `AppSubcategory`. Source of
  truth lives in the per-chain checklist files
  (`priv/repo/seeds/categories/<chain>.txt`) and gets imported into
  this table once a chain's triage is complete.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SuperBarato.Catalog.{AppSubcategory, ChainCategory}

  schema "category_mappings" do
    belongs_to :chain_category, ChainCategory
    belongs_to :app_subcategory, AppSubcategory

    timestamps(type: :utc_datetime)
  end

  @fields ~w(chain_category_id app_subcategory_id)a

  def changeset(row, attrs) do
    row
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> assoc_constraint(:chain_category)
    |> assoc_constraint(:app_subcategory)
    |> unique_constraint(:chain_category_id)
  end
end
