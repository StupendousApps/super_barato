defmodule SuperBarato.Repo.Migrations.LinkProductsToListings do
  use Ecto.Migration

  # Move the product ↔ chain_listing link out of chain_listings and
  # into a dedicated join table. Linking is now a separate concern
  # (the SuperBarato.Linker context); the crawler keeps writing
  # chain_listings without ever touching products.
  def change do
    drop_if_exists index(:chain_listings, [:product_id])

    alter table(:chain_listings) do
      remove :product_id, references(:products, on_delete: :nilify_all)
    end

    create table(:product_listings) do
      add :product_id, references(:products, on_delete: :delete_all), null: false
      add :chain_listing_id, references(:chain_listings, on_delete: :delete_all), null: false

      # Where the link came from — "manual", "ean_match", "name_match",
      # etc. Free-form so the Linker can grow new strategies without a
      # migration.
      add :source, :string, null: false, default: "manual"

      # Optional confidence score for fuzzy matchers (0.0–1.0).
      add :confidence, :float

      add :linked_at, :utc_datetime, null: false
    end

    create unique_index(:product_listings, [:product_id, :chain_listing_id])
    create index(:product_listings, [:chain_listing_id])
  end
end
