defmodule SuperBarato.Repo.Migrations.ChainListingsCategoryPathsArray do
  use Ecto.Migration

  # Replace `category_path :: string` with `category_paths :: text`
  # storing a JSON array. A single product can be discovered through
  # several category surfaces (Tottus's "Marcas Tottus" umbrella
  # parallel to the regular grocery aisles, Jumbo's
  # "experiencias-jumbo" mirror, etc.). The single-string field could
  # only hold the slug from the most recent discovery, so the older
  # surface was lost on every re-scrape.
  #
  # JSON-encoded strings on top of a TEXT column keep the SQLite
  # schema simple; Ecto's `{:array, :string}` field type maps cleanly
  # to it. Filtering uses `json_each` to expand the array; the
  # listings index gains a join-style filter without moving to a
  # separate `chain_listing_categories` table.
  def change do
    alter table(:chain_listings) do
      add :category_paths, :text, default: "[]", null: false
    end

    # `json_array(x)` builds `["x"]` with proper JSON escaping —
    # safer than string-concatenating slugs that may contain
    # apostrophes, quotes, or `>` (Cencosud breadcrumbs).
    execute(
      """
      UPDATE chain_listings
      SET category_paths = CASE
        WHEN category_path IS NULL OR category_path = ''
          THEN '[]'
        ELSE json_array(category_path)
      END
      """,
      """
      UPDATE chain_listings
      SET category_path = COALESCE(json_extract(category_paths, '$[0]'), category_path)
      """
    )

    alter table(:chain_listings) do
      remove :category_path, :string
    end
  end
end
