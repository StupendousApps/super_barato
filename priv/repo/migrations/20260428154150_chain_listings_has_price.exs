defmodule SuperBarato.Repo.Migrations.ChainListingsHasPrice do
  use Ecto.Migration

  # `has_price` tracks current availability: true when the chain
  # still shows a price for this SKU, false when a refresh observed
  # the product page without a price (out of stock, delisted, etc.).
  #
  # The `current_regular_price` column holds the **last-known** price,
  # never overwritten with NULL. UI can render "Last seen at $X" for
  # rows where `has_price = false`. Linker still anchors Products on
  # these rows because there's a meaningful price to compare on.
  #
  # New rows still require a price to be created (see
  # `Catalog.upsert_listing/1`); `has_price` only ever flips
  # true → false → true on an existing row.
  def change do
    alter table(:chain_listings) do
      add :has_price, :boolean, default: true, null: false
    end

    # Backfill: every existing row with a price is "currently
    # available" (true) — the migration that follows deletes any
    # row without a price, so this UPDATE is more about being
    # explicit than necessary.
    execute(
      """
      UPDATE chain_listings
      SET has_price = (current_regular_price IS NOT NULL AND current_regular_price > 0)
      """,
      """
      """
    )
  end
end
