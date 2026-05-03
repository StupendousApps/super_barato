defmodule SuperBarato.Repo.Migrations.Init do
  use Ecto.Migration

  # Single consolidated initial schema. Production is being reset, so
  # there's nothing to preserve. New columns / tables go in their own
  # dated migration after this point.
  #
  # What's included:
  #   * Catalog: products, product_identifiers, chain_categories,
  #     chain_listings, chain_listing_categories, app_categories,
  #     app_subcategories, category_mappings, product_listings.
  #   * FTS5 over products + chain_count denormalization (with the
  #     mirror triggers).
  #   * crawler_schedules.
  #   * stupendous_admin: admin_users, admin_session_tokens,
  #     admin_notifications. Owned by the library; we just call
  #     `StupendousAdmin.Migrations.V1.up/0` to install them.
  #
  # What's NOT here: a separate `users` table. Admin auth lives
  # entirely in stupendous_admin; super_barato has no end-user
  # accounts (it's a public site).

  def change do
    # ---- Catalog: products + their identifiers ---------------------

    create table(:products) do
      add :canonical_name, :string
      add :brand, :string
      add :image_url, :text

      # Multi-variant thumbnail embed managed by :stupendous_thumbnails.
      # Currently a single 400-px WebP per product; structured to grow
      # into multi-size fan-out without a schema change.
      add :thumbnail, :map

      # Denormalized count of distinct chains carrying any listing
      # linked to this product. Maintained by triggers below; powers
      # the search ranking boost.
      add :chain_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    # Open-ended identifier set per product. `kind` is one of:
    #
    #   * "ean_13"      — global GS1 GTIN-13. Cross-chain identity.
    #   * "ean_8"       — global GS1 EAN-8. Cross-chain identity.
    #   * "<chain>_sku" — per-chain SKU. Anchors a Product when no
    #                     EAN is exposed (Tottus loose meat, produce
    #                     sold by weight, etc.).
    #
    # The unique (kind, value) index guarantees the same identifier
    # can't anchor two different Products.
    create table(:product_identifiers) do
      add :product_id, references(:products, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :value, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:product_identifiers, [:kind, :value])
    create index(:product_identifiers, [:product_id])

    # ---- Chain categories (per-chain navigation taxonomy) ----------

    create table(:chain_categories) do
      add :chain, :string, null: false
      add :external_id, :string
      add :slug, :string, null: false
      add :name, :string, null: false
      add :parent_slug, :string
      add :level, :integer
      add :is_leaf, :boolean, default: false, null: false
      add :active, :boolean, default: true, null: false

      # Per-category crawler opt-out. Defaults to true; the discovery
      # path passes `false` for new rows whose slug matches a
      # non-grocery prefix (see Catalog.@auto_disabled_prefixes).
      add :crawl_enabled, :boolean, default: true, null: false

      add :first_seen_at, :utc_datetime, null: false
      add :last_seen_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:chain_categories, [:chain, :slug])
    create index(:chain_categories, [:chain, :is_leaf, :active])
    create index(:chain_categories, [:chain, :parent_slug])

    # ---- Chain listings (per-chain product surfacing) --------------

    create table(:chain_listings) do
      add :chain, :string, null: false
      add :chain_sku, :string, null: false
      add :chain_product_id, :string

      # Identity key — `Linker.Identity.encode/1` over the id-shaped
      # subset of `raw`. Drives the (chain, identifiers_key) unique
      # index; any change to the id set produces a new row.
      add :identifiers_key, :string

      # Convenience denormalization of one well-known id key so the
      # admin EAN filter / sort work without a JSON path expression.
      add :ean, :string

      add :name, :string
      add :brand, :string
      add :image_url, :text
      add :pdp_url, :text

      # Everything else the chain sent — descriptions, ratings,
      # breadcrumbs, offers, etc. Source of truth for any field not
      # denormalized into a real column.
      add :raw, :map, default: %{}

      add :current_regular_price, :integer
      add :current_promo_price, :integer
      add :current_promotions, :map, default: %{}

      add :has_price, :boolean, default: true, null: false

      add :first_seen_at, :utc_datetime, null: false
      add :last_discovered_at, :utc_datetime
      add :last_priced_at, :utc_datetime
      add :active, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(
             :chain_listings,
             [:chain, :identifiers_key],
             name: :chain_listings_chain_identifiers_key_index
           )

    create index(:chain_listings, [:ean])
    create index(:chain_listings, [:chain, :active])

    # Normalized many-to-many between listings + chain_categories.
    # The source of truth for which category surfaces a listing was
    # discovered through.
    create table(:chain_listing_categories) do
      add :chain_listing_id,
          references(:chain_listings, on_delete: :delete_all),
          null: false

      add :chain_category_id,
          references(:chain_categories, on_delete: :delete_all),
          null: false
    end

    create unique_index(:chain_listing_categories, [:chain_listing_id, :chain_category_id])
    create index(:chain_listing_categories, [:chain_category_id])

    # ---- App taxonomy (chain-agnostic shopper-facing categories) ---

    create table(:app_categories) do
      add :slug, :string, null: false
      add :name, :string, null: false
      add :position, :integer

      timestamps(type: :utc_datetime)
    end

    create unique_index(:app_categories, [:slug])

    create table(:app_subcategories) do
      add :app_category_id,
          references(:app_categories, on_delete: :delete_all),
          null: false

      add :slug, :string, null: false
      add :name, :string, null: false
      add :position, :integer

      timestamps(type: :utc_datetime)
    end

    create unique_index(:app_subcategories, [:app_category_id, :slug])
    create index(:app_subcategories, [:app_category_id])

    # Each chain_category maps to at most one app_subcategory.
    create table(:category_mappings) do
      add :chain_category_id,
          references(:chain_categories, on_delete: :delete_all),
          null: false

      add :app_subcategory_id,
          references(:app_subcategories, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:category_mappings, [:chain_category_id])
    create index(:category_mappings, [:app_subcategory_id])

    # Optional manual override on a Product.
    alter table(:products) do
      add :app_subcategory_id,
          references(:app_subcategories, on_delete: :nilify_all)
    end

    create index(:products, [:app_subcategory_id])

    # ---- Linker: product ↔ chain_listing join ---------------------

    create table(:product_listings) do
      add :product_id, references(:products, on_delete: :delete_all), null: false
      add :chain_listing_id, references(:chain_listings, on_delete: :delete_all), null: false

      add :source, :string, null: false, default: "manual"
      add :confidence, :float
      add :linked_at, :utc_datetime, null: false
    end

    create unique_index(:product_listings, [:product_id, :chain_listing_id])
    create index(:product_listings, [:chain_listing_id])

    # ---- Crawler schedules (admin-editable cron) -------------------

    create table(:crawler_schedules) do
      add :chain, :string, null: false
      add :kind, :string, null: false
      add :days, :string, null: false
      add :times, :string, null: false
      add :active, :boolean, null: false, default: true
      add :note, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:crawler_schedules, [:chain, :kind])

    # ---- FTS5 over products + chain_count triggers -----------------

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

    # ---- stupendous_admin tables -----------------------------------

    StupendousAdmin.Migrations.V1.up()
  end
end
