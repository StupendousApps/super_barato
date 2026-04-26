defmodule SuperBarato.Repo.Migrations.ChainListingsUniqIncludesEan do
  use Ecto.Migration

  # Identity for a chain_listing was `(chain, chain_sku)`. Reality is
  # that some chains reuse a chain_sku across distinct GTINs over time
  # (a slot gets repurposed when a SKU is delisted, a new product takes
  # the same internal id, etc.). Conflating those onto one row would
  # silently retarget any product_listings link the row already had.
  #
  # Move identity to `(chain, chain_sku, ean)`. NULL eans are
  # preserved as a distinct value via IFNULL — SQLite would otherwise
  # treat each NULL as unique, which would break the on-conflict
  # upsert path completely. So a listing with no EAN still uses
  # `(chain, chain_sku, '')` as its identity, and a chain that later
  # surfaces an EAN for that same SKU creates a new row.
  def change do
    drop_if_exists unique_index(:chain_listings, [:chain, :chain_sku])

    create unique_index(
             :chain_listings,
             ["chain", "chain_sku", "IFNULL(ean, '')"],
             name: :chain_listings_chain_sku_ean_index
           )
  end
end
