defmodule SuperBarato.Catalog.ChainCategory do
  use Ecto.Schema
  import Ecto.Changeset

  schema "chain_categories" do
    field :chain, :string
    field :external_id, :string
    field :slug, :string
    field :name, :string
    field :parent_slug, :string
    field :level, :integer
    field :is_leaf, :boolean, default: false
    field :active, :boolean, default: true
    # Per-category crawler opt-out. Defaults to true at the schema
    # level; the discovery path passes `false` for new rows whose
    # slug matches a non-grocery prefix (see Catalog).
    field :crawl_enabled, :boolean, default: true
    field :first_seen_at, :utc_datetime
    field :last_seen_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @discovery_fields ~w(chain external_id slug name parent_slug level is_leaf active crawl_enabled first_seen_at last_seen_at)a

  def discovery_changeset(category, attrs) do
    category
    |> cast(attrs, @discovery_fields)
    |> validate_required([:chain, :slug, :name, :first_seen_at])
    |> unique_constraint([:chain, :slug])
  end

  @edit_fields ~w(name crawl_enabled)a

  @doc """
  Operator-facing changeset — mutates only the fields the admin
  edit page exposes (name + crawl flag). Discovery-driven
  attributes (chain, slug, parent_slug, level, …) stay untouched.
  """
  def edit_changeset(category, attrs) do
    category
    |> cast(attrs, @edit_fields)
    |> validate_required([:name])
  end
end
