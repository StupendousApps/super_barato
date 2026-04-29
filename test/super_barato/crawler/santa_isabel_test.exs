defmodule SuperBarato.Crawler.SantaIsabelTest do
  use ExUnit.Case, async: true

  alias SuperBarato.Crawler.{ChainCategory, Cencosud}
  alias SuperBarato.Fixtures

  describe "Cencosud.categories_from_render_data/2 (SI home fixture)" do
    setup do
      html = Fixtures.read!(:santa_isabel, "home.html")
      {:ok, data} = Cencosud.extract_render_data(html)
      {:ok, cats} = Cencosud.categories_from_render_data(:santa_isabel, data)
      {:ok, cats: cats}
    end

    test "returns L1 + L2 + L3 categories from one fetch", %{cats: cats} do
      assert length(cats) > 200
      assert Enum.any?(cats, &(&1.level == 1))
      assert Enum.any?(cats, &(&1.level == 2))
      assert Enum.any?(cats, &(&1.level == 3))
    end

    test "every category is tagged :santa_isabel with valid parent_slug", %{cats: cats} do
      slugs = MapSet.new(cats, & &1.slug)

      Enum.each(cats, fn c ->
        assert %ChainCategory{chain: :santa_isabel} = c
        assert is_binary(c.slug) and c.slug != ""
        refute String.starts_with?(c.slug, "/")
        assert is_binary(c.name) and c.name != ""

        if c.level == 1 do
          assert is_nil(c.parent_slug)
        else
          assert MapSet.member?(slugs, c.parent_slug)
        end
      end)
    end

    test "L1 includes well-known grocery departments", %{cats: cats} do
      slugs = MapSet.new(cats, & &1.slug)

      for top <- ~w(despensa frutas-y-verduras lacteos-huevos-y-congelados
                    botilleria limpieza mascotas) do
        assert MapSet.member?(slugs, top), "expected #{top} in L1"
      end
    end
  end
end
