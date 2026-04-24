defmodule SuperBarato.Crawler.CencosudTest do
  use ExUnit.Case, async: true

  alias SuperBarato.Crawler.{Category, Cencosud, Listing}
  alias SuperBarato.Fixtures

  @jumbo %Cencosud.Config{
    chain: :jumbo,
    site_url: "https://www.jumbo.cl",
    categories_url: "https://assets.jumbo.cl/json/categories.json",
    sales_channel: "1"
  }

  @santa_isabel %Cencosud.Config{
    chain: :santa_isabel,
    site_url: "https://www.santaisabel.cl",
    categories_url: "https://assets.jumbo.cl/json/santaisabel/categories.json",
    sales_channel: "6"
  }

  describe "parse_categories/2 (Jumbo fixture)" do
    setup do
      tree = Fixtures.json!(:jumbo, "categories.json")
      cats = Cencosud.parse_categories(:jumbo, tree)
      {:ok, cats: cats}
    end

    test "returns Category structs tagged with the chain", %{cats: cats} do
      assert length(cats) > 0
      assert Enum.all?(cats, &match?(%Category{chain: :jumbo}, &1))
    end

    test "top-levels have level 1 and nil parent", %{cats: cats} do
      tops = Enum.filter(cats, &(&1.level == 1))
      assert length(tops) > 0
      assert Enum.all?(tops, &(&1.parent_slug == nil))
    end

    test "deeper categories have a parent_slug that's a prefix of their slug", %{cats: cats} do
      nested = Enum.filter(cats, &(&1.level > 1))
      assert length(nested) > 0

      Enum.each(nested, fn c ->
        assert is_binary(c.parent_slug)
        assert String.starts_with?(c.slug, c.parent_slug <> "/")
      end)
    end

    test "is_leaf is true for categories nobody claims as parent", %{cats: cats} do
      parents = cats |> Enum.map(& &1.parent_slug) |> Enum.reject(&is_nil/1) |> MapSet.new()

      Enum.each(cats, fn c ->
        expected = not MapSet.member?(parents, c.slug)
        assert c.is_leaf == expected
      end)
    end

    test "a known category (Lácteos y Quesos) appears as a top-level", %{cats: cats} do
      lacteos = Enum.find(cats, &(&1.slug == "lacteos-y-quesos"))
      assert lacteos
      assert lacteos.level == 1
      assert lacteos.parent_slug == nil
      assert lacteos.name == "Lácteos y Quesos"
      assert lacteos.external_id == "1"
    end
  end

  describe "parse_categories/2 (Santa Isabel fixture)" do
    test "produces SI-tagged categories with a different top-level set" do
      tree = Fixtures.json!(:santa_isabel, "categories.json")
      cats = Cencosud.parse_categories(:santa_isabel, tree)

      assert Enum.all?(cats, &match?(%Category{chain: :santa_isabel}, &1))

      # Santa Isabel's first top-level has id 1 and a different (combined) name
      first = Enum.find(cats, &(&1.external_id == "1" and &1.level == 1))
      assert first.name == "Lácteos, Huevos y Congelados"
    end
  end

  describe "parse_products/3 (Jumbo search fixture)" do
    setup do
      products = Fixtures.json!(:jumbo, "search_leche_en_polvo_page1.json")

      listings =
        Cencosud.parse_products(@jumbo, products, "lacteos-y-quesos/leches/leche-en-polvo")

      {:ok, listings: listings, raw: products}
    end

    test "returns Listing structs tagged with the chain", %{listings: listings} do
      assert length(listings) > 0
      assert Enum.all?(listings, &match?(%Listing{chain: :jumbo}, &1))
    end

    test "every listing has a chain_sku + chain_product_id + name", %{listings: listings} do
      Enum.each(listings, fn l ->
        assert is_binary(l.chain_sku) and l.chain_sku != ""
        assert is_binary(l.chain_product_id) and l.chain_product_id != ""
        assert is_binary(l.name) and l.name != ""
      end)
    end

    test "price is a positive integer (CLP, no decimals)", %{listings: listings} do
      Enum.each(listings, fn l ->
        assert is_nil(l.regular_price) or (is_integer(l.regular_price) and l.regular_price > 0)
        assert is_nil(l.promo_price) or (is_integer(l.promo_price) and l.promo_price > 0)
      end)
    end

    test "promo_price is nil when no discount; set when discounted", %{listings: listings} do
      Enum.each(listings, fn l ->
        if is_integer(l.regular_price) and is_integer(l.promo_price) do
          assert l.promo_price < l.regular_price
        end
      end)
    end

    test "pdp_url is built from linkText when present", %{listings: listings} do
      [l | _] = listings
      assert is_binary(l.pdp_url)
      assert String.starts_with?(l.pdp_url, "https://www.jumbo.cl/")
      assert String.ends_with?(l.pdp_url, "/p")
    end

    test "category_path propagates from the call", %{listings: listings} do
      [l | _] = listings
      assert l.category_path == "lacteos-y-quesos/leches/leche-en-polvo"
    end
  end

  describe "parse_products/3 (Jumbo by-SKU fixture — stage 3)" do
    test "returns listings with EAN populated (stage 3 endpoint includes it)" do
      products = Fixtures.json!(:jumbo, "skus.json")
      [l1, l2] = Cencosud.parse_products(@jumbo, products)

      # Two known products from our fixture probe
      by_sku = %{l1.chain_sku => l1, l2.chain_sku => l2}

      lomo = Map.fetch!(by_sku, "23")
      assert lomo.ean == "24990905"
      assert String.starts_with?(lomo.name, "Lomo")
      assert is_integer(lomo.regular_price) and lomo.regular_price > 0

      helado = Map.fetch!(by_sku, "104393")
      assert helado.ean == "7804673960073"
      assert helado.brand == "Bravissimo"
    end
  end

  describe "parse_products/3 (Santa Isabel fixtures)" do
    test "search fixture parses with sc=6 chain tag" do
      products = Fixtures.json!(:santa_isabel, "search_despensa_page1.json")
      [first | _] = Cencosud.parse_products(@santa_isabel, products, "despensa")
      assert first.chain == :santa_isabel
      assert first.category_path == "despensa"
    end

    test "by-SKU fixture has EANs" do
      products = Fixtures.json!(:santa_isabel, "skus.json")
      listings = Cencosud.parse_products(@santa_isabel, products)
      assert Enum.all?(listings, &is_binary(&1.ean))
    end
  end

  describe "parse_resources_total/1" do
    test "extracts total from 'resources: 0-39/664'" do
      assert Cencosud.parse_resources_total([{"resources", "0-39/664"}]) == 664
    end

    test "handles uppercase-insensitive key not being present" do
      # Header keys are lowercased by Http.parse_headers; so 'Resources' wouldn't be found
      assert Cencosud.parse_resources_total([{"Resources", "0-39/664"}]) == nil
    end

    test "returns nil when header missing" do
      assert Cencosud.parse_resources_total([]) == nil
      assert Cencosud.parse_resources_total([{"content-type", "application/json"}]) == nil
    end

    test "returns nil on malformed value" do
      assert Cencosud.parse_resources_total([{"resources", "gibberish"}]) == nil
    end
  end
end
