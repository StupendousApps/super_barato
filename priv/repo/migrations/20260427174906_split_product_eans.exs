defmodule SuperBarato.Repo.Migrations.SplitProductEans do
  use Ecto.Migration

  # Split EAN out of `products` into a many-to-one `product_eans`
  # table. A `Catalog.Product` is now "the conceptual product" (Old
  # Spice Pure Sport 50g) and may carry multiple GS1-assigned GTINs
  # (Mexican + US, manufacturer-relabel imports, etc.). The linker
  # looks up the canonicalized GTIN-13 in `product_eans`; admins can
  # merge two products by reattaching their `product_eans` to a single
  # surviving row.

  def change do
    create table(:product_eans) do
      add :product_id, references(:products, on_delete: :delete_all), null: false
      add :ean, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:product_eans, [:ean])
    create index(:product_eans, [:product_id])

    # Backfill: each existing product with a non-null ean gets one
    # `product_eans` row preserving the current 1:1 mapping. Then the
    # `ean` column on `products` is dropped — its unique partial index
    # has to go first.
    execute(
      """
      INSERT INTO product_eans (product_id, ean, inserted_at, updated_at)
      SELECT id, ean, inserted_at, updated_at
      FROM products
      WHERE ean IS NOT NULL AND ean != ''
      """,
      """
      INSERT INTO products (canonical_name, brand, image_url, ean, inserted_at, updated_at)
      SELECT NULL, NULL, NULL, NULL, inserted_at, updated_at FROM product_eans WHERE 0=1
      """
    )

    drop_if_exists index(:products, [:ean])

    alter table(:products) do
      remove :ean
    end
  end
end
