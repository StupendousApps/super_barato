defmodule SuperBarato.Repo.Migrations.PruneTottus do
  use Ecto.Migration

  import Ecto.Query

  alias SuperBarato.Catalog.ChainListing
  alias SuperBarato.Linker

  # One-shot data migration. Three steps in order:
  #
  #   1. Drop every Tottus category whose ancestry hits a blacklisted
  #      L1 (and the listings that referenced them). Whitelisted
  #      sub-trees inside blacklisted ancestors are spared. Slugs
  #      mirror `Crawler.Scope`'s tottus list as of this migration's
  #      commit.
  #
  #   2. Drop the catalog rows that no longer have a price. A
  #      listing without a price isn't useful as a comparable
  #      Product — there's nothing to compare. Unlink, then sweep
  #      the resulting orphan Products.
  #
  #   3. Linker pass over every active chain_listing — find-or-create
  #      its Product through `Linker.find_or_create_product_for_listing`
  #      + `set_listing_link`. Replaces the previous `Linker.Backfill`
  #      module, which existed only to do this exact pass; folding
  #      it into the migration drops the dead module and keeps the
  #      one-time logic with the data-shape transition that needs it.
  #
  # All three are idempotent — re-running picks up new rows without
  # touching what's already correct.

  @blacklist [
    "CATG29085/Ofertas",
    "CATG24817/Black-Week",
    "CATG25257/San-Valentin",
    "CATG27086/Celebraciones",
    "CATG29069/Escolares",
    "CATG27082/Escolares-y-libreria",
    "CATG27077/Jugueteria",
    "CATG27080/Deporte-y-aire-libre",
    "CATG27088/Electro",
    "CATG27088/Electro-y-tecnologia",
    "CATG28816/Vestuario",
    "CATG27079/Hogar-y-Ferreteria"
  ]

  @whitelist [
    "CATG27968/Colaciones",
    "CATG27965/Utiles-de-Aseo",
    "CATG29073/Colaciones"
  ]

  def up do
    prune_tottus_categories()
    drop_no_price_products()
    backfill_links()
  end

  def down, do: :noop

  # === Step 1: blacklist-driven Tottus subtree drop =========================

  defp prune_tottus_categories do
    blacklist_sql = Enum.map_join(@blacklist, ",", fn s -> "'#{s}'" end)
    whitelist_sql = Enum.map_join(@whitelist, ",", fn s -> "'#{s}'" end)

    drop_set_sql = """
    WITH RECURSIVE dropped(slug) AS (
      SELECT slug FROM categories
      WHERE chain = 'tottus' AND slug IN (#{blacklist_sql})
      UNION ALL
      SELECT c.slug
      FROM categories c
      JOIN dropped d ON c.parent_slug = d.slug
      WHERE c.chain = 'tottus'
        AND c.slug NOT IN (#{whitelist_sql})
    )
    """

    # A listing is dropped iff every one of its `category_paths` is
    # blacklisted — i.e. there's no surface that keeps it in scope.
    # Equivalent: NOT EXISTS (a path that's NOT in `dropped`).
    {:ok, %{num_rows: listings_n}} =
      repo().query("""
      #{drop_set_sql}
      DELETE FROM chain_listings
      WHERE chain = 'tottus'
        AND NOT EXISTS (
          SELECT 1 FROM json_each(chain_listings.category_paths) AS p
          WHERE p.value NOT IN (SELECT slug FROM dropped)
        )
        AND EXISTS (
          SELECT 1 FROM json_each(chain_listings.category_paths) AS p
          WHERE p.value IN (SELECT slug FROM dropped)
        )
      """)

    # Also strip the blacklisted entries from listings that survive
    # — those listings have at least one in-scope path, but their
    # array shouldn't keep references to dropped categories.
    repo().query!("""
    #{drop_set_sql}
    UPDATE chain_listings
    SET category_paths = (
      SELECT json_group_array(p.value)
      FROM json_each(chain_listings.category_paths) AS p
      WHERE p.value NOT IN (SELECT slug FROM dropped)
    )
    WHERE chain = 'tottus'
      AND EXISTS (
        SELECT 1 FROM json_each(chain_listings.category_paths) AS p
        WHERE p.value IN (SELECT slug FROM dropped)
      )
    """)

    {:ok, %{num_rows: cats_n}} =
      repo().query("""
      #{drop_set_sql}
      DELETE FROM categories
      WHERE chain = 'tottus' AND slug IN (SELECT slug FROM dropped)
      """)

    IO.puts("[prune_tottus] removed #{cats_n} categories, #{listings_n} listings")
  end

  # === Step 2: drop no-price listings entirely ==============================
  #
  # The runtime rule (`Catalog.upsert_listing/1`) refuses to insert a
  # listing without a price, so going forward no row of this shape
  # gets created. This step cleans up the legacy ones already on
  # disk: unlink, delete the listings, then orphan-sweep Products
  # that lose their last link as a result.

  defp drop_no_price_products do
    {:ok, %{num_rows: unlinked_n}} =
      repo().query("""
      DELETE FROM product_listings
      WHERE chain_listing_id IN (
        SELECT id FROM chain_listings
        WHERE current_regular_price IS NULL OR current_regular_price <= 0
      )
      """)

    {:ok, %{num_rows: listings_n}} =
      repo().query("""
      DELETE FROM chain_listings
      WHERE current_regular_price IS NULL OR current_regular_price <= 0
      """)

    {:ok, %{num_rows: prod_n}} =
      repo().query("""
      DELETE FROM products
      WHERE id NOT IN (SELECT DISTINCT product_id FROM product_listings)
      """)

    IO.puts(
      "[prune_tottus] unlinked #{unlinked_n} no-price links, " <>
        "deleted #{listings_n} no-price listings, " <>
        "dropped #{prod_n} orphan products"
    )
  end

  # === Step 3: Linker pass ==================================================
  #
  # Mirrors what the streaming `Linker.Worker` does for new inserts,
  # applied across every active chain_listing in one sweep. Same
  # rules:
  #
  #   * No identifier (no EAN, no chain_sku) → skip.
  #   * No price            → skip (Step 2 handled the existing dirty
  #                            data; this guards re-runs).
  #   * Otherwise           → find_or_create the Product and write
  #                            the link via `set_listing_link`.

  defp backfill_links do
    counts = %{linked: 0, skipped: 0}

    {:ok, result} =
      repo().transaction(
        fn ->
          from(l in ChainListing, where: l.active == true)
          |> repo().stream(max_rows: 200)
          |> Enum.reduce(counts, &link_one/2)
        end,
        timeout: :infinity
      )

    IO.puts("[prune_tottus] linked=#{result.linked} skipped=#{result.skipped}")
  end

  defp link_one(%ChainListing{} = listing, acc) do
    cond do
      is_nil(listing.current_regular_price) or listing.current_regular_price <= 0 ->
        Map.update!(acc, :skipped, &(&1 + 1))

      Linker.identifiers_for_listing(listing) == [] ->
        Map.update!(acc, :skipped, &(&1 + 1))

      true ->
        repo().transaction(fn ->
          {_action, product, source} =
            Linker.find_or_create_product_for_listing(listing)

          Linker.set_listing_link(product.id, listing.id,
            source: source,
            confidence: confidence_for(source)
          )
        end)

        Map.update!(acc, :linked, &(&1 + 1))
    end
  end

  defp confidence_for("ean_canonical"), do: 1.0
  defp confidence_for("single_chain"), do: 0.5
  defp confidence_for(_), do: nil
end
