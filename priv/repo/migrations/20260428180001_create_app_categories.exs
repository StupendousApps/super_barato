defmodule SuperBarato.Repo.Migrations.CreateAppCategories do
  use Ecto.Migration

  def change do
    create table(:app_categories) do
      add :slug, :string, null: false
      add :name, :string, null: false
      add :position, :integer
      timestamps(type: :utc_datetime)
    end

    create unique_index(:app_categories, [:slug])

    create table(:app_subcategories) do
      add :app_category_id,
          references(:app_categories, on_delete: :delete_all),
          null: false

      add :slug, :string, null: false
      add :name, :string, null: false
      add :position, :integer
      timestamps(type: :utc_datetime)
    end

    create unique_index(:app_subcategories, [:app_category_id, :slug])
    create index(:app_subcategories, [:app_category_id])
  end
end
