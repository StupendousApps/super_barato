defmodule SuperBarato.Crawler.JumboTest do
  use ExUnit.Case, async: true

  alias SuperBarato.Crawler.{Category, Jumbo}
  alias SuperBarato.Fixtures

  describe "extract_render_data/1" do
    test "pulls window.__renderData out of the home page" do
      html = Fixtures.read!(:jumbo, "home.html")
      assert {:ok, %{"menu" => _}} = Jumbo.extract_render_data(html)
    end

    test "errors when __renderData is missing" do
      assert {:error, :no_render_data} =
               Jumbo.extract_render_data("<html><body>no render data here</body></html>")
    end
  end

  describe "categories_from_render_data/1 (home fixture)" do
    setup do
      html = Fixtures.read!(:jumbo, "home.html")
      {:ok, data} = Jumbo.extract_render_data(html)
      {:ok, cats} = Jumbo.categories_from_render_data(data)
      {:ok, cats: cats}
    end

    test "returns L1 + L2 + L3 categories from one fetch", %{cats: cats} do
      assert length(cats) > 200
      assert Enum.any?(cats, &(&1.level == 1))
      assert Enum.any?(cats, &(&1.level == 2))
      assert Enum.any?(cats, &(&1.level == 3))
    end

    test "every category has slug, name, level, valid parent_slug", %{cats: cats} do
      slugs = MapSet.new(cats, & &1.slug)

      Enum.each(cats, fn c ->
        assert %Category{chain: :jumbo} = c
        assert is_binary(c.slug) and c.slug != ""
        refute String.starts_with?(c.slug, "/")
        assert is_binary(c.name) and c.name != ""
        assert c.level in [1, 2, 3]

        if c.level == 1 do
          assert is_nil(c.parent_slug)
        else
          assert MapSet.member?(slugs, c.parent_slug),
                 "parent_slug #{inspect(c.parent_slug)} not in tree"
        end
      end)
    end

    test "L1 includes well-known grocery departments", %{cats: cats} do
      slugs = MapSet.new(cats, & &1.slug)

      for top <- ~w(despensa frutas-y-verduras lacteos-huevos-y-congelados
                    licores-bebidas-y-aguas limpieza farmacia mascotas) do
        assert MapSet.member?(slugs, top), "expected #{top} in L1"
      end
    end
  end
end
