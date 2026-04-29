defmodule SuperBarato.Crawler.LiderTest do
  use ExUnit.Case, async: true

  alias SuperBarato.Crawler.{ChainCategory, Lider, Listing}
  alias SuperBarato.Fixtures

  describe "extract_next_data/1" do
    test "pulls the __NEXT_DATA__ JSON out of a Lider HTML page" do
      html = Fixtures.read!(:lider, "homepage.html")
      assert {:ok, %{"props" => _}} = Lider.extract_next_data(html)
    end

    test "returns error when __NEXT_DATA__ script is missing" do
      assert {:error, :no_next_data} = Lider.extract_next_data("<html><body>nope</body></html>")
    end
  end

  describe "parse_categories_from_next_data/1 (homepage fixture)" do
    setup do
      html = Fixtures.read!(:lider, "homepage.html")
      {:ok, data} = Lider.extract_next_data(html)
      {:ok, cats} = Lider.parse_categories_from_next_data(data)
      {:ok, cats: cats}
    end

    test "returns a non-empty Category list tagged :lider", %{cats: cats} do
      assert length(cats) > 0
      assert Enum.all?(cats, &match?(%ChainCategory{chain: :lider}, &1))
    end

    test "top-levels have level 1 and nil parent_slug", %{cats: cats} do
      tops = Enum.filter(cats, &(&1.level == 1))
      assert length(tops) > 0
      assert Enum.all?(tops, &(&1.parent_slug == nil))
    end

    test "includes a known food department (Despensa)", %{cats: cats} do
      desp = Enum.find(cats, &(&1.name == "Despensa"))

      assert desp, "expected a Despensa top-level (super.lider.cl)"
      assert desp.level == 1
      assert String.starts_with?(desp.slug, "despensa/")
      assert is_binary(desp.external_id)
    end

    test "blacklisted top-levels are filtered before mark_leaves runs", %{cats: cats} do
      slugs = Enum.map(cats, & &1.slug)

      # Every Lider blacklist entry — top-level departments must be
      # absent from the parsed tree (they get dropped before
      # mark_leaves).
      for top <- ~w(hogar libreria-y-cumpleanos tecno-y-electro
                    ferreteria vestuario deporte-y-aire-libre
                    parrillas-y-jardin automovil mainstays) do
        refute Enum.any?(slugs, &(&1 == top or String.starts_with?(&1, top <> "/"))),
               "expected #{top} branch to be filtered out, but found in: " <>
                 inspect(Enum.filter(slugs, &(&1 == top or String.starts_with?(&1, top <> "/"))))
      end
    end

    test "the mundo-bebe-y-jugueteria/jugueteria sub-tree is dropped, non-toy siblings remain",
         %{cats: cats} do
      slugs = Enum.map(cats, & &1.slug)

      refute Enum.any?(slugs, &String.starts_with?(&1, "mundo-bebe-y-jugueteria/jugueteria"))

      # Lider stores top-level slugs as `<dept>/<id>` so the bare
      # parent slug doesn't appear; instead, multiple siblings under
      # the parent prefix should still be in scope (panales, alimentación,
      # perfumería, …).
      kept_under_parent =
        Enum.filter(slugs, &String.starts_with?(&1, "mundo-bebe-y-jugueteria/"))

      assert length(kept_under_parent) > 0,
             "expected non-toy mundo-bebe-y-jugueteria/* siblings to survive"
    end

    test "sub-categories reference an existing parent_slug", %{cats: cats} do
      parent_slugs = cats |> Enum.map(& &1.slug) |> MapSet.new()
      l2 = Enum.filter(cats, &(&1.level == 2))
      assert length(l2) > 0

      # Most sub-categories should point at a parent we also collected.
      # Lider's mega-menu occasionally links across departments (cross-
      # promotional tiles) so we tolerate a handful of orphans.
      orphans = Enum.reject(l2, &MapSet.member?(parent_slugs, &1.parent_slug))
      assert length(orphans) / length(l2) < 0.2
    end

    test "is_leaf is true for categories nobody claims as parent", %{cats: cats} do
      parents = cats |> Enum.map(& &1.parent_slug) |> Enum.reject(&is_nil/1) |> MapSet.new()

      Enum.each(cats, fn c ->
        expected = not MapSet.member?(parents, c.slug)
        assert c.is_leaf == expected
      end)
    end
  end

  describe "parse_search_from_next_data/2 (browse fixture)" do
    @browse_slug "despensa/pastas-y-salsas/pastas-cortas/46589040_59615139_15312906"

    setup do
      html = Fixtures.read!(:lider, "browse_pastas.html")
      {:ok, data} = Lider.extract_next_data(html)
      {:ok, listings, total} = Lider.parse_search_from_next_data(data, @browse_slug)
      {:ok, listings: listings, total: total}
    end

    test "returns the aggregated total count", %{total: total} do
      assert is_integer(total) and total > 0
    end

    test "returns Listing structs tagged :lider", %{listings: listings} do
      assert length(listings) > 0
      assert Enum.all?(listings, &match?(%Listing{chain: :lider}, &1))
    end

    test "listings have chain_sku + name + image + pdp_url", %{listings: listings} do
      Enum.each(listings, fn l ->
        assert is_binary(l.chain_sku) and l.chain_sku != ""
        assert is_binary(l.name) and l.name != ""
        assert is_binary(l.image_url) or is_nil(l.image_url)
        assert is_binary(l.pdp_url) and String.starts_with?(l.pdp_url, "https://super.lider.cl/")
      end)
    end

    test "category_path propagates from the call", %{listings: listings} do
      [l | _] = listings
      assert l.category_path == @browse_slug
    end

    test "at least one listing has a populated regular_price", %{listings: listings} do
      assert Enum.any?(listings, &(is_integer(&1.regular_price) and &1.regular_price > 0))
    end
  end

  describe "parse_pdp_from_next_data/1 (PDP fixture)" do
    setup do
      html = Fixtures.read!(:lider, "pdp_pasta.html")
      {:ok, data} = Lider.extract_next_data(html)
      {:ok, listing} = Lider.parse_pdp_from_next_data(data)
      {:ok, listing: listing}
    end

    test "returns a fully-populated listing", %{listing: l} do
      assert %Listing{chain: :lider} = l
      assert l.chain_sku == "00780250000052"
      assert is_binary(l.name) and String.contains?(l.name, "Pantrucas")
      assert l.brand == "Lucchetti"
      assert l.regular_price == 990
      # EAN is the chain's raw `upc`/`usItemId` value — no
      # transformation. Linker generates canonical candidates at
      # match time.
      assert l.ean == "00780250000052"
      assert String.starts_with?(l.image_url, "https://")
    end

    test "identifiers_key encodes every id-shaped key", %{listing: l} do
      # `usItemId` is always present; `upc` is sometimes the same value
      # and sometimes empty depending on the product. The PDP fixture
      # has both, so the key carries them as separate entries.
      assert is_binary(l.identifiers_key)
      assert l.identifiers_key =~ "usItemId=00780250000052"
    end

    test "raw carries the source product map", %{listing: l} do
      assert is_map(l.raw)
      assert is_map(l.raw["product"])
      assert l.raw["product"]["usItemId"] == "00780250000052"
    end
  end
end
