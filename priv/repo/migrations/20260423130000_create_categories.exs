defmodule SuperBarato.Repo.Migrations.CreateCategories do
  use Ecto.Migration

  def change do
    create table(:categories) do
      add :chain, :string, null: false
      add :external_id, :string
      add :slug, :string, null: false
      add :name, :string, null: false
      add :parent_slug, :string
      add :level, :integer
      add :is_leaf, :boolean, default: false, null: false
      add :active, :boolean, default: true, null: false
      add :first_seen_at, :utc_datetime, null: false
      add :last_seen_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:categories, [:chain, :slug])
    create index(:categories, [:chain, :is_leaf, :active])
    create index(:categories, [:chain, :parent_slug])
  end
end
