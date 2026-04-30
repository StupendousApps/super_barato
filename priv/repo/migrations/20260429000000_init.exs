defmodule SuperBarato.Repo.Migrations.Init do
  use Ecto.Migration

  # Single consolidated initial schema. Replaces the prior 12-migration
  # history (one-shots like prune_tottus, intermediate column splits,
  # the categories→chain_categories rename, the seed_category_mappings
  # data migration). Production is being reset, so there's nothing to
  # preserve. New columns / tables go in their own dated migration
  # after this point.
  #
  # Seed data lives outside migrations:
  #
  #   * priv/repo/seed_admin.exs              — superadmin + crawler
  #                                             schedules
  #   * priv/repo/seed_chain_categories.exs   — frozen prod snapshot
  #                                             (priv/repo/source/...)
  #   * priv/repo/seed_app_categories.exs     — unified taxonomy
  #   * priv/repo/seed_app_chain_mappings.exs — chain → app subcategory
  #                                             mapping
  #
  # Run them all in dependency order with: mix run priv/repo/seeds.exs

  def change do
    # ---- Users + auth tokens ---------------------------------------

    create table(:users) do
      # Email is normalised to lowercase in the User changeset, so a
      # plain unique index is enough — SQLite has no citext equivalent.
      add :email, :string, null: false
      add :hashed_password, :string
      add :confirmed_at, :utc_datetime
      add :role, :string, null: false, default: "visitor"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])
    create index(:users, [:role])

    create table(:users_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      add :authenticated_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:users_tokens, [:user_id])
    create unique_index(:users_tokens, [:context, :token])

    # ---- Catalog: products + their identifiers ---------------------

    create table(:products) do
      add :canonical_name, :string
      add :brand, :string
      add :image_url, :text

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
    # can't anchor two different Products. A listing transitioning
    # from "no EAN" to "has EAN" re-attaches its <chain>_sku entry to
    # the canonical EAN-keyed Product and the placeholder orphans.
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
      # Projection of `raw`, not separate truth.
      add :ean, :string

      add :name, :string
      add :brand, :string
      add :image_url, :text
      add :pdp_url, :text

      # Every category surface where this listing has been observed.
      # Each entry is a `chain_categories.slug` for the same chain;
      # the `chain_listing_categories` join table gives FK-correct
      # access to the resolved rows.
      add :category_paths, {:array, :string}, default: [], null: false

      # Everything else the chain sent — descriptions, ratings,
      # breadcrumbs, offers, etc. Source of truth for any field not
      # denormalized into a real column.
      add :raw, :map, default: %{}

      add :current_regular_price, :integer
      add :current_promo_price, :integer
      add :current_promotions, :map, default: %{}

      # `has_price` is the signal that the chain is currently
      # offering this listing. A row with no price is kept (its
      # last-known shopper-facing price stays in
      # current_regular_price for history) but flagged unavailable.
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

    # Normalized many-to-many. `Catalog.upsert_listing/1` syncs this
    # from `category_paths` after every insert/update so reads can
    # join through it without re-parsing JSON. The legacy array
    # column stays as the source of truth for what the crawler
    # observed.
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

    # Each chain_category maps to at most one app_subcategory — the
    # unique index on chain_category_id enforces the "at most one"
    # half. seed_app_chain_mappings.exs reads the chains: blocks of
    # priv/repo/source/categories.yaml and writes one row here per
    # entry.
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

    # Optional manual override on a Product. When set it wins over the
    # consensus categorization derived from listings → category_mappings.
    # Nullable — most products inherit categorization from their chain
    # listings and never get a manual touch.
    alter table(:products) do
      add :app_subcategory_id,
          references(:app_subcategories, on_delete: :nilify_all)
    end

    create index(:products, [:app_subcategory_id])

    # ---- Linker: product ↔ chain_listing join ---------------------

    create table(:product_listings) do
      add :product_id, references(:products, on_delete: :delete_all), null: false
      add :chain_listing_id, references(:chain_listings, on_delete: :delete_all), null: false

      # Where the link came from — "ean_canonical", "single_chain",
      # "manual", etc. Free-form so the Linker can grow new
      # strategies without a migration.
      add :source, :string, null: false, default: "manual"

      # Optional confidence score for fuzzy matchers (0.0–1.0).
      add :confidence, :float

      add :linked_at, :utc_datetime, null: false
    end

    create unique_index(:product_listings, [:product_id, :chain_listing_id])
    create index(:product_listings, [:chain_listing_id])

    # ---- Crawler schedules (admin-editable cron) -------------------

    create table(:crawler_schedules) do
      # Chain id, e.g. "unimarc". String (not enum) so adding a new
      # chain doesn't require a migration — validated in the schema.
      add :chain, :string, null: false

      # Kind: "discover_categories" | "discover_products" |
      # "refresh_listings". String for the same future-proofing reason.
      add :kind, :string, null: false

      # Weekly cadence stored as comma-separated primitives.
      #   days:  "mon"        | "mon,tue,wed,thu,fri,sat,sun"
      #   times: "04:00:00"   | "05:00:00,14:30:00"
      add :days, :string, null: false
      add :times, :string, null: false

      add :active, :boolean, null: false, default: true

      # Free-form admin note (e.g. "paused after rate-limit incident").
      add :note, :string

      timestamps(type: :utc_datetime)
    end

    # One row per (chain, kind). Add a `name` column + drop this if
    # you ever want more than one schedule of the same kind on a chain.
    create unique_index(:crawler_schedules, [:chain, :kind])
  end
end
