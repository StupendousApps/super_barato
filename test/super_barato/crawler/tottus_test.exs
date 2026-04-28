defmodule SuperBarato.Crawler.TottusTest do
  use ExUnit.Case, async: true

  alias SuperBarato.Crawler.{Listing, Tottus}
  alias SuperBarato.Fixtures

  describe "extract_next_data/1" do
    test "pulls __NEXT_DATA__ out of a Tottus HTML page" do
      html = Fixtures.read!(:tottus, "category_carnes.html")
      assert {:ok, %{"props" => _}} = Tottus.extract_next_data(html)
    end

    test "errors when __NEXT_DATA__ is missing" do
      assert {:error, :no_next_data} = Tottus.extract_next_data("<html><body>x</body></html>")
    end
  end

  describe "categories_from_next_data/1 (home fixture)" do
    setup do
      html = Fixtures.read!(:tottus, "home_tottus.html")
      {:ok, data} = Tottus.extract_next_data(html)
      {:ok, cats} = Tottus.categories_from_next_data(data)
      {:ok, cats: cats}
    end

    test "returns L1 + L2 + L3 categories from one fetch", %{cats: cats} do
      # 30+ L1 + dozens of L2 / L3 — total well over the previous 25.
      assert length(cats) > 50
    end

    test "every category has slug, name, level, valid parent_slug", %{cats: cats} do
      slugs = MapSet.new(cats, & &1.slug)

      Enum.each(cats, fn c ->
        assert String.starts_with?(c.slug, "CATG")
        assert String.contains?(c.slug, "/")
        assert is_binary(c.name) and c.name != ""
        assert c.level in [1, 2, 3]

        if c.level == 1 do
          assert is_nil(c.parent_slug)
        else
          assert MapSet.member?(slugs, c.parent_slug)
        end
      end)
    end

    test "includes well-known departments (Carnes, Despensa)", %{cats: cats} do
      names = MapSet.new(cats, & &1.name)
      assert MapSet.member?(names, "Carnes")
      assert MapSet.member?(names, "Despensa")
    end
  end

  # The v2 fixture is a fresh capture taken after we hit a production
  # hang: the menu's "Marcas Propias" L2/L3 entries used filter URLs
  # (`?facetSelected=…`) that, after `slug_from_url/1` strips the
  # query string, collapse onto the parent's slug. That produced
  # `slug == parent_slug` self-cycles which Scope.filter's parent
  # walk infinite-looped on. Construction now skips those entries.
  describe "categories_from_next_data/1 (home_tottus_v2 — facet-link case)" do
    setup do
      html = Fixtures.read!(:tottus, "home_tottus_v2.html")
      {:ok, data} = Tottus.extract_next_data(html)
      {:ok, cats} = Tottus.categories_from_next_data(data)
      {:ok, cats: cats}
    end

    test "no category is its own parent", %{cats: cats} do
      self_parents = Enum.filter(cats, &(&1.slug == &1.parent_slug))
      assert self_parents == [], "expected no self-parents, got #{length(self_parents)}"
    end

    test "Scope.filter completes quickly (no parent-walk loop)", %{cats: cats} do
      task = Task.async(fn -> SuperBarato.Crawler.Scope.filter(:tottus, cats) end)

      filtered =
        case Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          nil -> flunk("Scope.filter did not finish within 1s — looped on parent chain")
        end

      assert length(filtered) > 500
    end
  end

  describe "parse_search_from_next_data/2 (Carnes fixture)" do
    setup do
      html = Fixtures.read!(:tottus, "category_carnes.html")
      {:ok, data} = Tottus.extract_next_data(html)
      {:ok, listings, total} = Tottus.parse_search_from_next_data(data, "CATG27069/Carnes")
      {:ok, listings: listings, total: total}
    end

    test "returns the pagination total count", %{total: total} do
      assert is_integer(total) and total > 0
    end

    test "returns Listing structs tagged :tottus", %{listings: listings} do
      assert length(listings) == 48
      assert Enum.all?(listings, &match?(%Listing{chain: :tottus}, &1))
    end

    test "listings carry chain_sku, name, and pdp_url", %{listings: listings} do
      Enum.each(listings, fn l ->
        assert is_binary(l.chain_sku) and l.chain_sku != ""
        assert is_binary(l.name) and l.name != ""
        assert is_binary(l.pdp_url) and String.starts_with?(l.pdp_url, "https://www.tottus.cl/")
      end)
    end

    test "category_path propagates from the call arg", %{listings: listings} do
      [l | _] = listings
      assert l.category_path == "CATG27069/Carnes"
    end

    test "at least one listing has a populated regular_price", %{listings: listings} do
      assert Enum.any?(listings, &(is_integer(&1.regular_price) and &1.regular_price > 0))
    end

    test "ean is always nil (Tottus doesn't expose barcode data)", %{listings: listings} do
      assert Enum.all?(listings, &is_nil(&1.ean))
    end
  end

  describe "parse_search_from_next_data/2 (Cervezas fixture, with promos)" do
    test "promo products have regular > promo" do
      html = Fixtures.read!(:tottus, "category_cervezas.html")
      {:ok, data} = Tottus.extract_next_data(html)
      {:ok, listings, _total} = Tottus.parse_search_from_next_data(data, "CATG27083/Cervezas")

      promo = Enum.filter(listings, & &1.promo_price)
      assert promo != []

      Enum.each(promo, fn l ->
        assert is_integer(l.regular_price)
        assert is_integer(l.promo_price)
        assert l.promo_price < l.regular_price
      end)
    end
  end

  describe "parse_prices/1" do
    test "internetPrice only → regular, no promo" do
      prices = [%{"type" => "internetPrice", "crossed" => false, "price" => ["11.990"]}]
      assert Tottus.parse_prices(prices) == {11_990, nil}
    end

    test "internetPrice (active) + normalPrice (crossed) → regular + promo" do
      prices = [
        %{"type" => "internetPrice", "crossed" => false, "price" => ["8.990"]},
        %{"type" => "normalPrice", "crossed" => true, "price" => ["12.990"]}
      ]

      assert Tottus.parse_prices(prices) == {12_990, 8_990}
    end

    test "cmrPrice is ignored; picks internetPrice" do
      prices = [
        %{"type" => "cmrPrice", "crossed" => false, "price" => ["7.990"]},
        %{"type" => "internetPrice", "crossed" => false, "price" => ["8.490"]},
        %{"type" => "normalPrice", "crossed" => true, "price" => ["9.650"]}
      ]

      assert Tottus.parse_prices(prices) == {9_650, 8_490}
    end

    test "normalPrice only (no internet) → regular" do
      prices = [%{"type" => "normalPrice", "crossed" => false, "price" => ["1.500"]}]
      assert Tottus.parse_prices(prices) == {1_500, nil}
    end

    test "empty list → {nil, nil}" do
      assert Tottus.parse_prices([]) == {nil, nil}
    end
  end

  describe "parse_pdp_from_next_data/1 (PDP fixture)" do
    setup do
      html = Fixtures.read!(:tottus, "pdp_costillas.html")
      {:ok, data} = Tottus.extract_next_data(html)
      {:ok, listing} = Tottus.parse_pdp_from_next_data(data)
      {:ok, listing: listing}
    end

    test "returns a fully-populated listing", %{listing: l} do
      assert %Listing{chain: :tottus} = l
      assert l.chain_sku == "146031074"
      assert String.contains?(l.name, "Costillas")
      assert l.brand == "MARVEST"
      assert l.regular_price == 11_990
      assert is_nil(l.promo_price)
      # Tottus PDPs carry GTIN-13s on `variants[0].okayToShopBarcodes`;
      # we only accept values that pass the GTIN-13 / EAN-8 check digit.
      assert l.ean == "7804604862605"
      assert String.starts_with?(l.pdp_url, "https://www.tottus.cl/tottus-cl/articulo/")
    end
  end

  describe "ean_from_variant/1" do
    test "accepts a valid GTIN-13" do
      assert Tottus.ean_from_variant(%{"okayToShopBarcodes" => ["7804604862605"]}) ==
               "7804604862605"
    end

    test "rejects too-short internal codes (deli / produce)" do
      assert Tottus.ean_from_variant(%{"okayToShopBarcodes" => ["13526"]}) == nil
    end

    test "rejects values that fail the GTIN check digit" do
      # Last digit changed from 5 → 4
      assert Tottus.ean_from_variant(%{"okayToShopBarcodes" => ["7804604862604"]}) == nil
    end

    test "picks the first valid value when the list mixes valid + junk" do
      assert Tottus.ean_from_variant(%{
               "okayToShopBarcodes" => ["13526", "7804604862605"]
             }) == "7804604862605"
    end

    test "missing field returns nil" do
      assert Tottus.ean_from_variant(%{}) == nil
      assert Tottus.ean_from_variant(%{"okayToShopBarcodes" => []}) == nil
    end
  end

  describe "adapter basics" do
    test "id/0 returns :tottus" do
      assert Tottus.id() == :tottus
    end

    test "refresh_identifier/0 is :chain_sku (no EAN exposed)" do
      assert Tottus.refresh_identifier() == :chain_sku
    end

    test "unsupported tasks return an error tuple" do
      assert {:error, {:unsupported_task, _}} = Tottus.handle_task({:bogus, %{}})
    end
  end
end
