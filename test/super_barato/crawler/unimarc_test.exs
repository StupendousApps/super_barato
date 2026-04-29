defmodule SuperBarato.Crawler.UnimarcTest do
  use ExUnit.Case, async: true

  alias SuperBarato.Crawler.{ChainCategory, Listing, Unimarc}
  alias SuperBarato.Fixtures

  describe "parse_subtree/1 (postFacets Congelados fixture)" do
    setup do
      data = Fixtures.json!(:unimarc, "facets_subtree_congelados.json")
      cats = Unimarc.parse_subtree(data)
      {:ok, cats: cats, data: data}
    end

    test "every category is tagged :unimarc", %{cats: cats} do
      assert length(cats) > 0
      assert Enum.all?(cats, &match?(%ChainCategory{chain: :unimarc}, &1))
    end

    test "includes the top-level Congelados", %{cats: cats} do
      top = Enum.find(cats, &(&1.slug == "congelados"))
      assert top
      assert top.level == 1
      assert top.name == "Congelados"
      assert top.external_id == "354"
      assert top.parent_slug == nil
    end

    test "level-2 children have parent_slug == \"congelados\"", %{cats: cats} do
      level2 = Enum.filter(cats, &(&1.level == 2))
      assert length(level2) > 0
      assert Enum.all?(level2, &(&1.parent_slug == "congelados"))
    end

    test "level-3 slugs have three path segments", %{cats: cats} do
      level3 = Enum.filter(cats, &(&1.level == 3))
      assert length(level3) > 0
      Enum.each(level3, fn c -> assert length(String.split(c.slug, "/")) == 3 end)
    end

    test "leaves are categories nobody claims as parent", %{cats: cats} do
      parents = cats |> Enum.map(& &1.parent_slug) |> Enum.reject(&is_nil/1) |> MapSet.new()

      Enum.each(cats, fn c ->
        expected = not MapSet.member?(parents, c.slug)
        assert c.is_leaf == expected
      end)
    end
  end

  describe "parse_products/2 (postProductsSearch Camarones fixture)" do
    setup do
      %{"availableProducts" => products} =
        Fixtures.json!(:unimarc, "search_camarones_page1.json")

      listings =
        Unimarc.parse_products(products, "congelados/pescados-y-mariscos/camarones")

      {:ok, listings: listings}
    end

    test "returns Listing structs tagged :unimarc with the category slug", %{listings: listings} do
      assert length(listings) > 0

      Enum.each(listings, fn l ->
        assert %Listing{chain: :unimarc} = l
        assert l.category_path == "congelados/pescados-y-mariscos/camarones"
      end)
    end

    test "chain_sku, name, brand are strings", %{listings: listings} do
      Enum.each(listings, fn l ->
        assert is_binary(l.chain_sku) and l.chain_sku != ""
        assert is_binary(l.name)
        assert is_binary(l.brand)
      end)
    end

    test "EAN is a string (Unimarc exposes 13-digit EANs)", %{listings: listings} do
      Enum.each(listings, fn l ->
        assert is_binary(l.ean)
        assert String.length(l.ean) >= 8
      end)
    end

    test "prices are integers in CLP", %{listings: listings} do
      Enum.each(listings, fn l ->
        assert is_integer(l.regular_price) and l.regular_price > 0
        assert is_nil(l.promo_price) or (is_integer(l.promo_price) and l.promo_price > 0)
      end)
    end

    test "regular_price + promo_price both populated when Unimarc volunteers list and current",
         %{listings: listings} do
      # Faithful pass-through: parser maps listPrice → regular_price and
      # price → promo_price whenever both are present, regardless of
      # comparison. Display layer decides what to render as a promo.
      Enum.each(listings, fn l ->
        case {l.regular_price, l.promo_price} do
          {nil, nil} -> :ok
          {r, nil} when is_integer(r) -> :ok
          {r, p} when is_integer(r) and is_integer(p) -> :ok
        end
      end)
    end

    test "pdp_url points at unimarc.cl", %{listings: listings} do
      Enum.each(listings, fn l ->
        assert l.pdp_url == nil or String.starts_with?(l.pdp_url, "https://www.unimarc.cl/")
      end)
    end
  end

  describe "parse_products/2 (by-identifier fixture — stage 3)" do
    test "returns listings by EAN with same shape as search" do
      %{"availableProducts" => products} =
        Fixtures.json!(:unimarc, "by_identifier.json")

      listings = Unimarc.parse_products(products)

      # We fed two EANs in the probe
      assert length(listings) == 2

      by_ean = Map.new(listings, &{&1.ean, &1})

      hamburguesa = Map.fetch!(by_ean, "7809611721655")
      assert String.contains?(hamburguesa.name, "Hamburguesa")
      assert hamburguesa.brand == "Superbeef"
      assert is_integer(hamburguesa.regular_price)

      camaron = Map.fetch!(by_ean, "7807975009259")
      assert String.contains?(camaron.name, "Camarón")
    end
  end
end
