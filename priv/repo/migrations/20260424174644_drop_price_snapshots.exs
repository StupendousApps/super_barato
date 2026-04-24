defmodule SuperBarato.Repo.Migrations.DropPriceSnapshots do
  use Ecto.Migration

  # Prices live on chain_listings.current_* (most-recent snapshot).
  # Full history is append-only in priv/data/prices/<chain>/<sku>.log
  # via SuperBarato.PriceLog — the DB table was never written to.
  def up do
    drop table(:price_snapshots)
  end

  def down do
    create table(:price_snapshots) do
      add :chain_listing_id, references(:chain_listings, on_delete: :delete_all), null: false
      add :regular_price, :integer, null: false
      add :promo_price, :integer
      add :promotions, :map, default: %{}
      add :captured_at, :utc_datetime, null: false
    end

    create index(:price_snapshots, [:chain_listing_id, :captured_at])
  end
end
