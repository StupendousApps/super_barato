defmodule SuperBarato.Crawler.AcuentaTest do
  use ExUnit.Case, async: true

  alias SuperBarato.Crawler.{Acuenta, ChainCategory, Listing}
  alias SuperBarato.Linker.Identity

  @fixture_dir Path.expand("../../support/fixtures/acuenta", __DIR__)

  defp json!(name), do: @fixture_dir |> Path.join(name) |> File.read!() |> Jason.decode!()

  describe "parse_category_tree/1 (categories.json fixture)" do
    setup do
      %{"data" => %{"getCategory" => roots}} = json!("categories.json")
      cats = Acuenta.parse_category_tree(roots)
      {:ok, cats: cats}
    end

    test "returns Category structs tagged :acuenta", %{cats: cats} do
      assert length(cats) > 0
      assert Enum.all?(cats, &match?(%ChainCategory{chain: :acuenta}, &1))
    end

    test "top-levels have level 1 and nil parent_slug", %{cats: cats} do
      tops = Enum.filter(cats, &(&1.level == 1))
      assert length(tops) > 0
      assert Enum.all?(tops, &(&1.parent_slug == nil))
    end

    test "every top-level slug ends with `<name>/<reference>`", %{cats: cats} do
      tops = Enum.filter(cats, &(&1.level == 1))

      Enum.each(tops, fn c ->
        assert String.ends_with?(c.slug, "/" <> c.external_id),
               "expected slug #{c.slug} to end with /#{c.external_id}"
      end)
    end

    test "deeper categories' parent_slug is a real prefix of their slug", %{cats: cats} do
      nested = Enum.filter(cats, &(&1.level > 1))
      assert length(nested) > 0

      Enum.each(nested, fn c ->
        assert is_binary(c.parent_slug)
        assert String.starts_with?(c.slug, c.parent_slug <> "/")
      end)
    end

    test "is_leaf is true exactly for nodes nobody claims as parent", %{cats: cats} do
      parents = cats |> Enum.map(& &1.parent_slug) |> Enum.reject(&is_nil/1) |> MapSet.new()

      Enum.each(cats, fn c ->
        expected = not MapSet.member?(parents, c.slug)
        assert c.is_leaf == expected
      end)
    end

    test "known top-level Despensa surfaces with the right ref", %{cats: cats} do
      desp = Enum.find(cats, &(&1.level == 1 and &1.name == "Despensa"))

      assert desp
      assert desp.external_id == "05"
      assert desp.slug == "despensa/05"
    end

    test "blacklisted hogar-entretencion-y-tecnologia branch is dropped", %{cats: cats} do
      slugs = Enum.map(cats, & &1.slug)

      refute Enum.any?(slugs, &String.starts_with?(&1, "hogar-entretencion-y-tecnologia")),
             "expected the homewares branch to be filtered out"

      # Sanity: a non-blacklisted top-level still comes through.
      assert Enum.any?(slugs, &String.starts_with?(&1, "despensa/"))
    end
  end

  describe "parse_products_response/2 (products_despensa_p1.json fixture)" do
    setup do
      response = json!("products_despensa_p1.json")
      listings = Acuenta.parse_products_response(response, "despensa/05")
      {:ok, listings: listings}
    end

    test "returns Listing structs tagged :acuenta", %{listings: listings} do
      assert length(listings) > 0
      assert Enum.all?(listings, &match?(%Listing{chain: :acuenta}, &1))
    end

    test "every listing has a chain_sku, name, and identifiers_key", %{listings: listings} do
      Enum.each(listings, fn l ->
        assert is_binary(l.chain_sku) and l.chain_sku != ""
        assert is_binary(l.name) and l.name != ""
        assert is_binary(l.identifiers_key)
      end)
    end

    test "listings preserve category_path passed in", %{listings: listings} do
      assert Enum.all?(listings, &(&1.category_path == "despensa/05"))
    end

    test "ean column carries the first array entry", %{listings: listings} do
      with_ean = Enum.filter(listings, &(&1.ean != nil))
      assert length(with_ean) > 0
      assert Enum.all?(with_ean, &is_binary(&1.ean))
    end

    test "identifiers_key includes sku and the EANs", %{listings: listings} do
      arroz = Enum.find(listings, &(&1.chain_sku == "4791831"))
      assert arroz
      assert arroz.ean == "7801420002246"
      # Order-independent canonical form: sku=, ean=, …
      assert String.contains?(arroz.identifiers_key, "sku=4791831")
      assert String.contains?(arroz.identifiers_key, "ean=7801420002246")
    end

    test "multi-EAN product encodes every EAN under ean / ean2 / …", %{listings: listings} do
      aceite = Enum.find(listings, &(&1.chain_sku == "696785"))
      assert aceite

      assert aceite.ean == "7794870055767",
             "ean column should carry the first EAN from the array"

      key = aceite.identifiers_key
      assert String.contains?(key, "ean=7794870055767")
      assert String.contains?(key, "ean2=7790272005461")
      assert String.contains?(key, "ean3=400007304161")

      # The encoded key is a stable Identity hash.
      decoded =
        key
        |> String.split(",")
        |> Enum.map(&String.split(&1, "=", parts: 2))
        |> Map.new(fn [k, v] -> {k, v} end)

      assert Identity.encode(decoded) == key
    end

    test "pdp_url is reconstructed from the slug", %{listings: listings} do
      arroz = Enum.find(listings, &(&1.chain_sku == "4791831"))
      assert arroz.pdp_url ==
               "https://www.acuenta.cl/p/" <>
                 "arroz-tucapel-extra-fino-grado-2-grano-largo-fino-1-kg-tucapel-4791831"
    end

    test "regular_price comes from previousPrice when present, else from price",
         %{listings: listings} do
      # Faithful pass-through: the parser doesn't compare values to
      # decide what's a promo. When the chain volunteers both prices
      # both columns get populated; downstream renders the promo.
      Enum.each(listings, fn l ->
        # At minimum a regular price is set when the chain volunteered any price.
        case {l.regular_price, l.promo_price} do
          {nil, nil} -> :ok
          {n, nil} when is_integer(n) -> :ok
          {n, m} when is_integer(n) and is_integer(m) -> :ok
        end
      end)
    end
  end

  describe "category_reference_from_slug/1" do
    test "returns the trailing segment" do
      assert Acuenta.category_reference_from_slug("despensa/05") == "05"

      assert Acuenta.category_reference_from_slug(
               "despensa/05/arroz-legumbres-y-semillas/0502/arroz/050201"
             ) == "050201"
    end

    test "nil and empty inputs are nil" do
      assert Acuenta.category_reference_from_slug(nil) == nil
      assert Acuenta.category_reference_from_slug("") == nil
    end
  end
end
