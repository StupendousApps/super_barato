defmodule SuperBarato.CatalogTest do
  use SuperBarato.DataCase, async: false

  alias SuperBarato.{Catalog, Repo}
  alias SuperBarato.Catalog.ChainListing
  alias SuperBarato.Crawler.Listing

  defp listing(opts) do
    %Listing{
      chain: opts[:chain] || :unimarc,
      chain_sku: opts[:chain_sku] || "sku-#{System.unique_integer([:positive])}",
      chain_product_id: opts[:chain_product_id],
      ean: opts[:ean],
      identifiers_key:
        opts[:identifiers_key] || "sku=#{opts[:chain_sku] || System.unique_integer([:positive])}",
      name: opts[:name] || "Test Product",
      brand: opts[:brand] || "Brand X",
      image_url: opts[:image_url] || "https://example.com/x.jpg",
      pdp_url: opts[:pdp_url] || "https://example.com/p/x",
      category_path: opts[:category_path],
      regular_price: Keyword.get(opts, :regular_price, 1990),
      promo_price: opts[:promo_price],
      promotions: opts[:promotions] || %{},
      raw: opts[:raw] || %{}
    }
  end

  describe "upsert_listing/1 — new rows" do
    test "with a price → :upserted, has_price true, all fields written" do
      l =
        listing(
          identifiers_key: "ean=7800000000001",
          ean: "7800000000001",
          regular_price: 1990,
          promo_price: 1490,
          category_path: "despensa/arroz"
        )

      assert {:ok, :upserted, row} = Catalog.upsert_listing(l)
      assert row.has_price == true
      assert row.current_regular_price == 1990
      assert row.current_promo_price == 1490
      assert row.category_paths == ["despensa/arroz"]
      assert row.last_priced_at != nil
      assert row.first_seen_at == row.last_discovered_at
    end

    test "without a price → :skipped, no row created" do
      l = listing(identifiers_key: "ean=7800000000002", regular_price: nil)

      assert {:ok, :skipped, nil} = Catalog.upsert_listing(l)
      refute Repo.get_by(ChainListing, identifiers_key: "ean=7800000000002")
    end

    test "with regular_price = 0 → :skipped" do
      l = listing(identifiers_key: "ean=7800000000003", regular_price: 0)
      assert {:ok, :skipped, nil} = Catalog.upsert_listing(l)
    end

    test "with negative price → :skipped (defensive)" do
      l = listing(identifiers_key: "ean=7800000000004", regular_price: -100)
      assert {:ok, :skipped, nil} = Catalog.upsert_listing(l)
    end
  end

  describe "upsert_listing/1 — existing row, refresh with price" do
    setup do
      l = listing(identifiers_key: "ean=78001", regular_price: 1990, name: "Original")
      {:ok, :upserted, row} = Catalog.upsert_listing(l)
      {:ok, row: row}
    end

    test "updates price + bumps last_priced_at + has_price stays true", %{row: row} do
      l = listing(identifiers_key: "ean=78001", regular_price: 2490, name: "Updated")

      assert {:ok, :upserted, new_row} = Catalog.upsert_listing(l)
      assert new_row.id == row.id
      assert new_row.has_price == true
      assert new_row.current_regular_price == 2490
      assert new_row.name == "Updated"
      assert DateTime.compare(new_row.last_priced_at, row.last_priced_at) in [:gt, :eq]
    end

    test "first_seen_at preserved across updates", %{row: row} do
      Process.sleep(1_100)

      l = listing(identifiers_key: "ean=78001", regular_price: 2000)
      {:ok, :upserted, new_row} = Catalog.upsert_listing(l)

      assert new_row.first_seen_at == row.first_seen_at
    end
  end

  describe "upsert_listing/1 — existing row, refresh WITHOUT price" do
    setup do
      l =
        listing(
          identifiers_key: "ean=78002",
          regular_price: 1990,
          promo_price: 1490,
          category_path: "despensa",
          name: "Original Name"
        )

      {:ok, :upserted, row} = Catalog.upsert_listing(l)
      {:ok, row: row}
    end

    test "marks has_price false, preserves last-known price", %{row: row} do
      Process.sleep(50)

      l = listing(identifiers_key: "ean=78002", regular_price: nil, name: "Updated Name")

      assert {:ok, :updated, new_row} = Catalog.upsert_listing(l)
      assert new_row.id == row.id
      assert new_row.has_price == false
      # Crucial: price columns are NOT overwritten with nil
      assert new_row.current_regular_price == 1990
      assert new_row.current_promo_price == 1490
      # last_priced_at is NOT bumped (we didn't observe a price now)
      assert new_row.last_priced_at == row.last_priced_at
      # but other display fields ARE refreshed
      assert new_row.name == "Updated Name"
      # last_discovered_at IS bumped (we did see the row exists)
      assert DateTime.compare(new_row.last_discovered_at, row.last_discovered_at) in [:gt, :eq]
    end

    test "round-trip: price → no price → price, last-known price preserved at each step",
         %{row: row} do
      # Step A: lose price
      l_unavailable = listing(identifiers_key: "ean=78002", regular_price: nil)
      {:ok, :updated, after_unavail} = Catalog.upsert_listing(l_unavailable)
      assert after_unavail.has_price == false
      assert after_unavail.current_regular_price == 1990

      # Step B: regain price (different value)
      l_back = listing(identifiers_key: "ean=78002", regular_price: 2200)
      {:ok, :upserted, after_back} = Catalog.upsert_listing(l_back)
      assert after_back.has_price == true
      assert after_back.current_regular_price == 2200
      assert after_back.id == row.id
    end

    test "merges category_paths even when no price", %{row: _row} do
      l =
        listing(
          identifiers_key: "ean=78002",
          regular_price: nil,
          category_path: "marcas-tottus/despensa"
        )

      {:ok, :updated, new_row} = Catalog.upsert_listing(l)
      assert "despensa" in new_row.category_paths
      assert "marcas-tottus/despensa" in new_row.category_paths
    end
  end

  describe "upsert_listing/1 — category_paths array merge" do
    test "first observation produces single-element array" do
      l = listing(identifiers_key: "k1", regular_price: 1000, category_path: "a/b")
      {:ok, :upserted, row} = Catalog.upsert_listing(l)
      assert row.category_paths == ["a/b"]
    end

    test "second discovery via different path appends + dedupes" do
      Catalog.upsert_listing(listing(identifiers_key: "k2", regular_price: 1000, category_path: "a/b"))

      {:ok, :upserted, row} =
        Catalog.upsert_listing(listing(identifiers_key: "k2", regular_price: 1000, category_path: "c/d"))

      assert Enum.sort(row.category_paths) == ["a/b", "c/d"]
    end

    test "rediscovery via the same path is a no-op for the array" do
      Catalog.upsert_listing(listing(identifiers_key: "k3", regular_price: 1000, category_path: "x/y"))

      {:ok, :upserted, row} =
        Catalog.upsert_listing(listing(identifiers_key: "k3", regular_price: 1000, category_path: "x/y"))

      assert row.category_paths == ["x/y"]
    end

    test "nil/empty incoming path leaves array unchanged" do
      Catalog.upsert_listing(listing(identifiers_key: "k4", regular_price: 1000, category_path: "kept"))

      {:ok, :upserted, row} =
        Catalog.upsert_listing(listing(identifiers_key: "k4", regular_price: 1000, category_path: nil))

      assert row.category_paths == ["kept"]
    end
  end

  describe "list_listings_page/1 — category filter via array" do
    setup do
      Catalog.upsert_listing(listing(identifiers_key: "f1", regular_price: 1, category_path: "despensa/arroz"))
      Catalog.upsert_listing(listing(identifiers_key: "f2", regular_price: 1, category_path: "despensa/aceites"))
      Catalog.upsert_listing(listing(identifiers_key: "f3", regular_price: 1, category_path: "carnes"))

      # Same SKU rediscovered through a second surface → both paths
      Catalog.upsert_listing(listing(identifiers_key: "f1", regular_price: 1, category_path: "marcas-tottus/despensa/arroz"))

      :ok
    end

    test "matches L1 prefix and any descendant path stored on a listing" do
      result = Catalog.list_listings_page(category: "despensa", per_page: 50)
      keys = Enum.map(result.items, & &1.identifiers_key)

      assert "f1" in keys
      assert "f2" in keys
      refute "f3" in keys
    end

    test "exact-match against a single path works too" do
      result = Catalog.list_listings_page(category: "carnes", per_page: 50)
      assert Enum.map(result.items, & &1.identifiers_key) == ["f3"]
    end

    test "matches a listing by either of its accumulated surfaces" do
      result = Catalog.list_listings_page(category: "marcas-tottus", per_page: 50)
      assert Enum.map(result.items, & &1.identifiers_key) == ["f1"]
    end
  end
end
