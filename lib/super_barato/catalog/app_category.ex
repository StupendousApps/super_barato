defmodule SuperBarato.Catalog.AppCategory do
  @moduledoc """
  Top-level node of the unified, app-wide taxonomy seeded from
  `priv/repo/seeds/categories.yaml`. Independent of any chain —
  `ChainCategory` rows from the six chains are mapped onto these
  via the checklist files.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SuperBarato.Catalog.AppSubcategory

  schema "app_categories" do
    field :slug, :string
    field :name, :string
    field :position, :integer

    has_many :subcategories, AppSubcategory, foreign_key: :app_category_id

    timestamps(type: :utc_datetime)
  end

  @fields ~w(slug name position)a

  def changeset(app_category, attrs) do
    app_category
    |> cast(attrs, @fields)
    |> validate_required([:slug, :name])
    |> unique_constraint(:slug)
  end
end
