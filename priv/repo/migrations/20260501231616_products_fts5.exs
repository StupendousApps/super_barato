defmodule SuperBarato.Repo.Migrations.ProductsFts5 do
  use Ecto.Migration

  # FTS5 full-text search over products (canonical_name + brand) plus
  # a denormalized `products.chain_count` boost so cross-chain
  # products outrank one-off store-only items in the home search.
  #
  # Triggers keep both in sync going forward:
  #   * `products_*`         — mirror canonical_name / brand into the
  #                            FTS index on insert / update / delete.
  #   * `product_listings_*` — recompute `products.chain_count` when
  #                            a product↔listing link is added,
  #                            removed, or moved.
  #
  # The migration also backfills both pieces from the data already in
  # production so the index is immediately usable post-deploy.
  def change do
    alter table(:products) do
      add :chain_count, :integer, null: false, default: 0
    end

    # Backfill chain_count from existing product_listings.
    execute(
      """
      UPDATE products SET chain_count = (
        SELECT COUNT(DISTINCT cl.chain)
        FROM product_listings pl
        JOIN chain_listings cl ON cl.id = pl.chain_listing_id
        WHERE pl.product_id = products.id
      )
      """,
      "SELECT 1"
    )

    execute(
      """
      CREATE VIRTUAL TABLE products_fts USING fts5(
        canonical_name,
        brand,
        content='products',
        content_rowid='id',
        tokenize='unicode61 remove_diacritics 2'
      )
      """,
      "DROP TABLE products_fts"
    )

    # Backfill the FTS index from existing rows.
    execute(
      """
      INSERT INTO products_fts(rowid, canonical_name, brand)
      SELECT id, canonical_name, brand FROM products
      """,
      "DELETE FROM products_fts"
    )

    # Mirror products → products_fts.
    execute(
      """
      CREATE TRIGGER products_ai AFTER INSERT ON products BEGIN
        INSERT INTO products_fts(rowid, canonical_name, brand)
        VALUES (new.id, new.canonical_name, new.brand);
      END
      """,
      "DROP TRIGGER products_ai"
    )

    execute(
      """
      CREATE TRIGGER products_ad AFTER DELETE ON products BEGIN
        INSERT INTO products_fts(products_fts, rowid, canonical_name, brand)
        VALUES('delete', old.id, old.canonical_name, old.brand);
      END
      """,
      "DROP TRIGGER products_ad"
    )

    execute(
      """
      CREATE TRIGGER products_au AFTER UPDATE ON products BEGIN
        INSERT INTO products_fts(products_fts, rowid, canonical_name, brand)
        VALUES('delete', old.id, old.canonical_name, old.brand);
        INSERT INTO products_fts(rowid, canonical_name, brand)
        VALUES (new.id, new.canonical_name, new.brand);
      END
      """,
      "DROP TRIGGER products_au"
    )

    # Maintain chain_count on every product↔listing link change.
    execute(
      """
      CREATE TRIGGER product_listings_ai_chain_count AFTER INSERT ON product_listings
      BEGIN
        UPDATE products SET chain_count = (
          SELECT COUNT(DISTINCT cl.chain)
          FROM product_listings pl
          JOIN chain_listings cl ON cl.id = pl.chain_listing_id
          WHERE pl.product_id = new.product_id
        ) WHERE id = new.product_id;
      END
      """,
      "DROP TRIGGER product_listings_ai_chain_count"
    )

    execute(
      """
      CREATE TRIGGER product_listings_ad_chain_count AFTER DELETE ON product_listings
      BEGIN
        UPDATE products SET chain_count = (
          SELECT COUNT(DISTINCT cl.chain)
          FROM product_listings pl
          JOIN chain_listings cl ON cl.id = pl.chain_listing_id
          WHERE pl.product_id = old.product_id
        ) WHERE id = old.product_id;
      END
      """,
      "DROP TRIGGER product_listings_ad_chain_count"
    )

    execute(
      """
      CREATE TRIGGER product_listings_au_chain_count AFTER UPDATE ON product_listings
      WHEN old.product_id IS NOT new.product_id
      BEGIN
        UPDATE products SET chain_count = (
          SELECT COUNT(DISTINCT cl.chain)
          FROM product_listings pl
          JOIN chain_listings cl ON cl.id = pl.chain_listing_id
          WHERE pl.product_id = old.product_id
        ) WHERE id = old.product_id;

        UPDATE products SET chain_count = (
          SELECT COUNT(DISTINCT cl.chain)
          FROM product_listings pl
          JOIN chain_listings cl ON cl.id = pl.chain_listing_id
          WHERE pl.product_id = new.product_id
        ) WHERE id = new.product_id;
      END
      """,
      "DROP TRIGGER product_listings_au_chain_count"
    )
  end
end
