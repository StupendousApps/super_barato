defmodule SuperBarato.Repo.Migrations.Init do
  use Ecto.Migration

  # Single consolidated initial schema. Replaces the prior history of
  # incremental migrations — prod is being reset, so there's nothing
  # to preserve. New chains / new columns / new tables go in their
  # own dated migration after this point.

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

    # ---- Catalog: products + chain_listings + categories -----------

    create table(:products) do
      add :ean, :string
      add :canonical_name, :string
      add :brand, :string
      add :image_url, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:products, [:ean], where: "ean IS NOT NULL")

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
      add :category_path, :string
      add :pdp_url, :text

      # Everything else the chain sent — descriptions, ratings,
      # breadcrumbs, offers, etc. Source of truth for any field not
      # denormalized into a real column.
      add :raw, :map, default: %{}

      add :current_regular_price, :integer
      add :current_promo_price, :integer
      add :current_promotions, :map, default: %{}

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

    create table(:categories) do
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

    create unique_index(:categories, [:chain, :slug])
    create index(:categories, [:chain, :is_leaf, :active])
    create index(:categories, [:chain, :parent_slug])

    # ---- Linker: product ↔ chain_listing join ---------------------

    create table(:product_listings) do
      add :product_id, references(:products, on_delete: :delete_all), null: false
      add :chain_listing_id, references(:chain_listings, on_delete: :delete_all), null: false

      # Where the link came from — "ean_match", "manual", "fuzzy_name",
      # etc. Free-form so the Linker can grow new strategies without
      # a migration.
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
