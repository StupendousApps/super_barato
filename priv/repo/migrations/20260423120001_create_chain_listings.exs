defmodule SuperBarato.Repo.Migrations.CreateChainListings do
  use Ecto.Migration

  def change do
    create table(:chain_listings) do
      add :chain, :string, null: false
      add :chain_sku, :string, null: false
      add :chain_product_id, :string
      add :product_id, references(:products, on_delete: :nilify_all)

      add :ean, :string
      add :name, :string
      add :brand, :string
      add :image_url, :text
      add :category_path, :string
      add :pdp_url, :text

      add :current_regular_price, :integer
      add :current_promo_price, :integer
      add :current_promotions, :map, default: %{}

      add :first_seen_at, :utc_datetime, null: false
      add :last_discovered_at, :utc_datetime
      add :last_priced_at, :utc_datetime
      add :active, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:chain_listings, [:chain, :chain_sku])
    create index(:chain_listings, [:product_id])
    create index(:chain_listings, [:ean])
    create index(:chain_listings, [:chain, :active])
  end
end
