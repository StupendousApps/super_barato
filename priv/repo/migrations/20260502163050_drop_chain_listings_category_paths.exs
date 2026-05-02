defmodule SuperBarato.Repo.Migrations.DropChainListingsCategoryPaths do
  use Ecto.Migration

  def up do
    # Delete listings that have no category breadcrumb at all and
    # therefore can't be linked to any chain_categories row. Going
    # forward, ingest will reject these at the source.
    execute("""
    DELETE FROM chain_listings
    WHERE id NOT IN (SELECT chain_listing_id FROM chain_listing_categories)
    """)

    alter table(:chain_listings) do
      remove :category_paths
    end
  end

  def down do
    alter table(:chain_listings) do
      add :category_paths, {:array, :string}, default: [], null: false
    end
  end
end
