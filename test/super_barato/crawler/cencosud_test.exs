defmodule SuperBarato.Crawler.CencosudTest do
  use ExUnit.Case, async: true

  alias SuperBarato.Crawler.{Category, Cencosud, Listing}
  alias SuperBarato.Fixtures

  @jumbo %Cencosud.Config{
    chain: :jumbo,
    site_url: "https://www.jumbo.cl",
    categories_url: "https://assets.jumbo.cl/sitemap/category-0.xml",
    sales_channel: "1",
    sitemap_index: "https://assets.jumbo.cl/sitemap.xml"
  }

  @santa_isabel %Cencosud.Config{
    chain: :santa_isabel,
    site_url: "https://www.santaisabel.cl",
    categories_url: "https://assets.santaisabel.cl/sitemap/sitemap-categories.xml",
    sales_channel: "6",
    sitemap_index: "https://www.santaisabel.cl/sitemap.xml"
  }

  @sitemap_dir Path.expand("../../fixtures/cencosud", __DIR__)
  defp xml(name), do: File.read!(Path.join(@sitemap_dir, name))

  describe "parse_categories_xml/2 (Jumbo category sitemap)" do
    setup do
      cats = Cencosud.parse_categories_xml(:jumbo, xml("jumbo_category-0.xml"))
      {:ok, cats: cats}
    end

    test "returns Category structs tagged with the chain", %{cats: cats} do
      assert length(cats) > 0
      assert Enum.all?(cats, &match?(%Category{chain: :jumbo}, &1))
    end

    test "external_id is nil — sitemap doesn't carry numeric ids", %{cats: cats} do
      assert Enum.all?(cats, &(&1.external_id == nil))
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

    test "a known top-level slug surfaces with a humanized name", %{cats: cats} do
      vacuno = Enum.find(cats, &(&1.slug == "carnes-y-pescados"))
      assert vacuno
      assert vacuno.level == 1
      assert vacuno.parent_slug == nil
      # "carnes-y-pescados" -> "Carnes Y Pescados"; capitalization is
      # naive on purpose, slug + URL are what downstream uses.
      assert vacuno.name == "Carnes Y Pescados"
    end
  end

  describe "parse_categories_xml/2 (Santa Isabel category sitemap)" do
    test "produces SI-tagged categories" do
      cats = Cencosud.parse_categories_xml(:santa_isabel, xml("santa_isabel_category.xml"))
      assert length(cats) > 0
      assert Enum.all?(cats, &match?(%Category{chain: :santa_isabel}, &1))

      # Bare host URL (https://www.santaisabel.cl) is filtered out —
      # no category at the empty path.
      refute Enum.any?(cats, &(&1.slug == ""))
    end
  end

  describe "category-pruning end-to-end (sitemap → Scope filter)" do
    test "Jumbo: blacklisted hogar-jugueteria-y-libreria branch is dropped" do
      cats = Cencosud.parse_categories_xml(:jumbo, xml("jumbo_category-0.xml"))

      # No top-level + no descendants survive.
      refute Enum.any?(cats, &String.starts_with?(&1.slug, "hogar-jugueteria-y-libreria"))

      # Sanity check: a non-blacklisted top-level still comes through.
      assert Enum.any?(cats, &(&1.slug == "despensa"))
    end

    test "Santa Isabel: blacklisted `hogar` and `hogar-jugueteria-y-libreria` branches are dropped" do
      cats = Cencosud.parse_categories_xml(:santa_isabel, xml("santa_isabel_category.xml"))

      refute Enum.any?(cats, fn c ->
               c.slug == "hogar" or String.starts_with?(c.slug, "hogar/")
             end)

      refute Enum.any?(
               cats,
               &String.starts_with?(&1.slug, "hogar-jugueteria-y-libreria")
             )

      # Food top-levels still in.
      assert Enum.any?(cats, &(&1.slug == "carnes-y-pescados"))
      assert Enum.any?(cats, &(&1.slug == "despensa"))
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

    test "regular_price + promo_price both populated when VTEX volunteers ListPrice and Price",
         %{listings: listings} do
      # Faithful pass-through: parser maps ListPrice → regular_price and
      # Price → promo_price whenever both fields are present, regardless
      # of whether Price < ListPrice. Display layer decides what to render.
      Enum.each(listings, fn l ->
        case {l.regular_price, l.promo_price} do
          {nil, nil} -> :ok
          {r, nil} when is_integer(r) -> :ok
          {r, p} when is_integer(r) and is_integer(p) -> :ok
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
