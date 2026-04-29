defmodule SuperBarato.Repo.Migrations.CreateCategoryMappings do
  use Ecto.Migration

  def change do
    create table(:category_mappings) do
      add :chain_category_id,
          references(:chain_categories, on_delete: :delete_all),
          null: false

      add :app_subcategory_id,
          references(:app_subcategories, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime)
    end

    # A chain category maps to at most one app subcategory.
    create unique_index(:category_mappings, [:chain_category_id])
    create index(:category_mappings, [:app_subcategory_id])
  end
end
