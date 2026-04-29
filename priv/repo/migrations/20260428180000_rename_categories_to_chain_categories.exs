defmodule SuperBarato.Repo.Migrations.RenameCategoriesToChainCategories do
  use Ecto.Migration

  def up do
    # Rename the table itself.
    rename table(:categories), to: table(:chain_categories)

    # SQLite doesn't ALTER INDEX RENAME; drop the old indexes and
    # recreate with the chain_categories naming.
    drop_if_exists unique_index(:chain_categories, [:chain, :slug],
                     name: :categories_chain_slug_index
                   )

    drop_if_exists index(:chain_categories, [:chain, :is_leaf, :active],
                     name: :categories_chain_is_leaf_active_index
                   )

    drop_if_exists index(:chain_categories, [:chain, :parent_slug],
                     name: :categories_chain_parent_slug_index
                   )

    create unique_index(:chain_categories, [:chain, :slug])
    create index(:chain_categories, [:chain, :is_leaf, :active])
    create index(:chain_categories, [:chain, :parent_slug])
  end

  def down do
    drop_if_exists unique_index(:chain_categories, [:chain, :slug])
    drop_if_exists index(:chain_categories, [:chain, :is_leaf, :active])
    drop_if_exists index(:chain_categories, [:chain, :parent_slug])

    rename table(:chain_categories), to: table(:categories)

    create unique_index(:categories, [:chain, :slug],
             name: :categories_chain_slug_index
           )

    create index(:categories, [:chain, :is_leaf, :active],
             name: :categories_chain_is_leaf_active_index
           )

    create index(:categories, [:chain, :parent_slug],
             name: :categories_chain_parent_slug_index
           )
  end
end
