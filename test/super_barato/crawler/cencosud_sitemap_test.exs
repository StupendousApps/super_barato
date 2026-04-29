defmodule SuperBarato.Crawler.CencosudSitemapTest do
  @moduledoc """
  Tests against real Jumbo + Santa Isabel sitemap and PDP fixtures
  captured 2026-04-26. The schema isn't versioned by the chains so we
  expect drift over time — when a fixture stops matching reality,
  re-capture from the same URLs and update the assertions, don't
  weaken the parser to fit stale data.
  """
  use ExUnit.Case, async: true

  alias SuperBarato.Crawler.{Cencosud, Listing}
  alias SuperBarato.Fixtures

  defp fixture(chain, name), do: Fixtures.read!(chain, name)

  @jumbo %Cencosud.Config{
    chain: :jumbo,
    site_url: "https://www.jumbo.cl",
    categories_url: "https://assets.jumbo.cl/json/categories.json",
    sales_channel: "1",
    sitemap_index: "https://assets.jumbo.cl/sitemap.xml"
  }

  @si %Cencosud.Config{
    chain: :santa_isabel,
    site_url: "https://www.santaisabel.cl",
    categories_url: "https://assets.jumbo.cl/json/santaisabel/categories.json",
    sales_channel: "6",
    sitemap_index: "https://www.santaisabel.cl/sitemap.xml"
  }

  describe "extract_locs/2 against real sitemap fixtures" do
    test "Jumbo sitemap index lists 57 sub-sitemaps" do
      xml = fixture(:jumbo, "sitemap_index.xml")
      sub_sitemaps = Cencosud.extract_locs(xml, "sitemap")

      assert length(sub_sitemaps) == 57
      assert "https://assets.jumbo.cl/sitemap/product-0.xml" in sub_sitemaps
      assert "https://assets.jumbo.cl/sitemap/category-0.xml" in sub_sitemaps
      # No <url> entries in an index.
      assert Cencosud.extract_locs(xml, "url") == []
    end

    test "Jumbo product-0 has 1000 PDP URLs, all canonical /<slug>/p" do
      xml = fixture(:jumbo, "sitemap_product-0.xml")
      urls = Cencosud.extract_locs(xml, "url")

      assert length(urls) == 1000
      assert Enum.all?(urls, &String.starts_with?(&1, "https://www.jumbo.cl/"))
      assert Enum.all?(urls, &String.ends_with?(&1, "/p"))
    end

    test "Jumbo category-0 has 624 category URLs" do
      xml = fixture(:jumbo, "sitemap_category-0.xml")
      urls = Cencosud.extract_locs(xml, "url")
      assert length(urls) == 624
    end

    test "Santa Isabel index lists 3 sub-sitemaps including the Supabase custom feed" do
      xml = fixture(:santa_isabel, "sitemap_index.xml")
      subs = Cencosud.extract_locs(xml, "sitemap")
      assert length(subs) == 3

      assert Enum.any?(subs, &String.contains?(&1, "supabase.co"))
      assert Enum.any?(subs, &String.contains?(&1, "santaisabel-custom"))
    end

    test "Santa Isabel custom feed has 15_656 PDP URLs" do
      xml = fixture(:santa_isabel, "sitemap_custom.xml")
      urls = Cencosud.extract_locs(xml, "url")

      # The custom feed embeds attributes on `<url>` is no — but our
      # regex tolerates it either way; this also catches multi-line
      # url blocks (which the SI fixture uses, unlike Jumbo's compact
      # one-line layout).
      assert length(urls) == 15_656
      assert Enum.all?(urls, &String.starts_with?(&1, "https://www.santaisabel.cl/"))
    end
  end

  describe "parse_pdp/3 — Jumbo PDPs" do
    test "meat PDP — full assertion of every parsed field" do
      url = "https://www.jumbo.cl/lomoliso-envasado-12kgaprox/p"
      html = fixture(:jumbo, "pdp_meat.html")

      assert {:ok, %Listing{} = l} = Cencosud.parse_pdp(@jumbo, html, url)

      assert l.chain == :jumbo
      assert l.chain_sku == "23"
      assert l.ean == "24990905"
      assert l.name == "Lomo Liso Al Vacío kg"
      assert l.brand == "Carnicería Propia"
      assert l.regular_price > 0
      assert l.pdp_url == url
      # category_path is the deepest breadcrumb-URL slug, NOT a name
      # trail — that's what `chain_categories.slug` stores, so the
      # downstream `chain_listing_categories` join can resolve it.
      assert l.category_path == "carnes-y-pescados/vacuno/carnes-de-uso-diario"
      assert is_binary(l.image_url) and l.image_url != ""
    end

    test "water PDP" do
      assert_jumbo_basics(fixture(:jumbo, "pdp_water.html"))
    end

    test "nectar PDP — stale sitemap entry (Product node has no name/sku, price 'undefined')" do
      # Real-world drift: sitemap still lists the URL but the PDP
      # serves a delisted Product node with nil fields. Parser must
      # detect and tag :stale_pdp so we skip the row, not persist
      # garbage. Also validates the @graph empty-list-placeholder
      # regression fix (raised BadMapError before).
      url = "https://www.jumbo.cl/nectar-andina/p"
      html = fixture(:jumbo, "pdp_nectar.html")

      assert {:error, :stale_pdp} = Cencosud.parse_pdp(@jumbo, html, url)
    end

    test "cleaning PDP" do
      assert_jumbo_basics(fixture(:jumbo, "pdp_cleaning.html"))
    end
  end

  defp assert_jumbo_basics(html) do
    url = "https://www.jumbo.cl/example/p"

    assert {:ok, %Listing{} = l} = Cencosud.parse_pdp(@jumbo, html, url)
    assert l.chain == :jumbo
    assert is_binary(l.name) and l.name != ""
    assert is_integer(l.regular_price) and l.regular_price > 0
    assert is_binary(l.chain_sku) and l.chain_sku != ""
  end

  describe "parse_pdp/3 — Santa Isabel PDPs" do
    test "parses water PDP (gtin8 EAN shape)" do
      url = "https://www.santaisabel.cl/agua/p"
      html = fixture(:santa_isabel, "pdp_water.html")

      assert {:ok, %Listing{} = listing} = Cencosud.parse_pdp(@si, html, url)

      assert listing.chain == :santa_isabel
      assert listing.pdp_url == url
      assert is_integer(listing.regular_price)
      assert listing.regular_price > 0
      assert is_binary(listing.name)

      # SI breadcrumbs sometimes have only home + leaf-category (no
      # product entry) and emit `position` as a string. Both used to
      # break the parse and leave category_path nil; now the leaf
      # slug is extracted from the breadcrumb item URL.
      assert is_binary(listing.category_path)
      assert listing.category_path != ""
      refute String.ends_with?(listing.category_path, "/p")
    end

    test "parses energy-drink PDP" do
      url = "https://www.santaisabel.cl/monster/p"
      html = fixture(:santa_isabel, "pdp_energy.html")

      assert {:ok, %Listing{} = listing} = Cencosud.parse_pdp(@si, html, url)

      assert listing.regular_price > 0
      assert is_binary(listing.name)
    end
  end
end
