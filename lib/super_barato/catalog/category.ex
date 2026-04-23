defmodule SuperBarato.Catalog.Category do
  use Ecto.Schema
  import Ecto.Changeset

  schema "categories" do
    field :chain, :string
    field :external_id, :string
    field :slug, :string
    field :name, :string
    field :parent_slug, :string
    field :level, :integer
    field :is_leaf, :boolean, default: false
    field :active, :boolean, default: true
    field :first_seen_at, :utc_datetime
    field :last_seen_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @discovery_fields ~w(chain external_id slug name parent_slug level is_leaf active first_seen_at last_seen_at)a

  def discovery_changeset(category, attrs) do
    category
    |> cast(attrs, @discovery_fields)
    |> validate_required([:chain, :slug, :name, :first_seen_at])
    |> unique_constraint([:chain, :slug])
  end
end
