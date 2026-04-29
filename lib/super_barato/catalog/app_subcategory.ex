defmodule SuperBarato.Catalog.AppSubcategory do
  @moduledoc """
  Second-level node of the unified taxonomy. Slug is unique within
  the parent `AppCategory`; chain categories from `ChainCategory`
  ultimately link to one of these.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SuperBarato.Catalog.AppCategory

  schema "app_subcategories" do
    field :slug, :string
    field :name, :string
    field :position, :integer

    belongs_to :app_category, AppCategory

    timestamps(type: :utc_datetime)
  end

  @fields ~w(slug name position app_category_id)a

  def changeset(app_subcategory, attrs) do
    app_subcategory
    |> cast(attrs, @fields)
    |> validate_required([:slug, :name, :app_category_id])
    |> assoc_constraint(:app_category)
    |> unique_constraint([:app_category_id, :slug])
  end
end
