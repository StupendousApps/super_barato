defmodule SuperBarato.Repo.Migrations.ChainListingsIdentifiersAndRaw do
  use Ecto.Migration

  # Capture-everything pivot.
  #
  # `raw` holds the entire chain payload, verbatim — including every
  # id-shaped key the chain emitted (SKU, EAN, UPC, GTINs, internal
  # product ids, etc.) and everything else (descriptions, ratings,
  # breadcrumbs, offers, …). It's the source of truth for any field
  # not denormalized into a real column.
  #
  # `identifiers_key` is the parser's canonical-string over the
  # id-shaped subset of that payload (Linker.Identity.encode/1 — a
  # sorted, comma-joined `<k>=<v>` string). Any change to the id set
  # (added key / removed key / value change) produces a different
  # `identifiers_key`, so the new `(chain, identifiers_key)` unique
  # index treats it as a new row. Old rows hang as orphans until the
  # inactivity sweep retires them. The string also supports cheap
  # `LIKE '%sku=…%'` lookups for ad-hoc admin queries.
  #
  # The previous `(chain, chain_sku, IFNULL(ean, ''))` unique index
  # is dropped — `(chain, identifiers_key)` replaces it.
  def change do
    alter table(:chain_listings) do
      add :identifiers_key, :string
      add :raw, :map, default: %{}
    end

    drop_if_exists index(:chain_listings, [:chain, :chain_sku, :ean],
                     name: :chain_listings_chain_sku_ean_index
                   )

    create unique_index(
             :chain_listings,
             [:chain, :identifiers_key],
             name: :chain_listings_chain_identifiers_key_index
           )
  end
end
