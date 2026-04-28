defmodule SuperBarato.Repo.Migrations.TypedProductIdentifiers do
  use Ecto.Migration

  # Generalize `product_eans` into a typed identifier table. Each
  # Product now collects an open set of identifiers, each tagged with
  # a `kind`:
  #
  #   * "ean_13"          — global GS1 GTIN-13. Cross-chain identity.
  #   * "ean_8"           — global GS1 EAN-8. Cross-chain identity.
  #   * "<chain>_sku"     — per-chain SKU (Tottus's productId, Lider's
  #                         usItemId, etc.). Single-chain by definition;
  #                         enough to anchor a Product when no EAN is
  #                         exposed (Tottus's loose meat, produce sold
  #                         by weight).
  #
  # Lookup / merge stays clean: a unique index on (kind, value) means
  # the same identifier can never anchor two different Products. A
  # listing transitioning from "no EAN" to "has EAN" reattaches its
  # chain-sku identifier to the canonical EAN-keyed Product, and the
  # placeholder Product orphan-cleans.
  def change do
    create table(:product_identifiers) do
      add :product_id, references(:products, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :value, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:product_identifiers, [:kind, :value])
    create index(:product_identifiers, [:product_id])

    # Backfill: every existing `product_eans` row becomes a
    # `product_identifiers` row tagged "ean_13" or "ean_8" by length.
    # Reversal recreates the source `product_eans` row from any
    # ean_13/ean_8 identifier.
    execute(
      """
      INSERT INTO product_identifiers (product_id, kind, value, inserted_at, updated_at)
      SELECT product_id,
             CASE WHEN length(ean) = 8 THEN 'ean_8' ELSE 'ean_13' END,
             ean,
             inserted_at,
             updated_at
      FROM product_eans
      """,
      """
      INSERT INTO product_eans (product_id, ean, inserted_at, updated_at)
      SELECT product_id, value, inserted_at, updated_at
      FROM product_identifiers
      WHERE kind IN ('ean_13', 'ean_8')
      """
    )

    drop table(:product_eans)
  end
end
