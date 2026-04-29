defmodule SuperBarato.Catalog.CategoryChecklistTest do
  use ExUnit.Case, async: true

  alias SuperBarato.Catalog.CategoryChecklist

  test "parses every status flavor" do
    text = """
    [ ]
       0  Bebé
    mi-bebe

    [-]
      12  Bebé / Rodados
    mi-bebe/rodados

    [N]
       3  Marcas Tottus / Recco
    CATG27088/Electro-y-Tecnologia

    [x]: {category: "frutas-y-verduras", subcategory: "verduras"}
     123  Frutas y Verduras / Verduras
    frutas-y-verduras/verduras
    """

    [a, b, c, d] = CategoryChecklist.parse(text)

    assert a == %{status: :unchecked, count: 0, path: "Bebé", slug: "mi-bebe", mapping: nil}

    assert b == %{
             status: :no_match,
             count: 12,
             path: "Bebé / Rodados",
             slug: "mi-bebe/rodados",
             mapping: nil
           }

    assert c == %{
             status: :no_mapping,
             count: 3,
             path: "Marcas Tottus / Recco",
             slug: "CATG27088/Electro-y-Tecnologia",
             mapping: nil
           }

    assert d == %{
             status: :mapped,
             count: 123,
             path: "Frutas y Verduras / Verduras",
             slug: "frutas-y-verduras/verduras",
             mapping: %{category: "frutas-y-verduras", subcategory: "verduras"}
           }
  end

  test "raises on unrecognized status" do
    assert_raise ArgumentError, ~r/unrecognized checklist status/, fn ->
      CategoryChecklist.parse("[?]\n   0  X\nx\n")
    end
  end

  test "raises when [x] is missing category/subcategory" do
    assert_raise ArgumentError, ~r/missing subcategory/, fn ->
      CategoryChecklist.parse(~s/[x]: {category: "foo"}\n   0  X\nx\n/)
    end
  end

  test "round-trips against a real seed file" do
    path = Path.join([File.cwd!(), "priv/repo/seeds/categories/lider.txt"])
    entries = CategoryChecklist.parse_file(path)
    assert length(entries) > 0
    assert Enum.all?(entries, &(&1.status in [:unchecked, :no_match, :no_mapping, :mapped]))
  end

  test "serialize/parse round-trip preserves entries" do
    text = """
    [ ]
       0  Bebé
    mi-bebe

    [-]
      12  Bebé / Rodados
    mi-bebe/rodados

    [N]
       3  Marcas Tottus / Recco
    CATG27088/Electro-y-Tecnologia

    [x]: {category: "frutas-y-verduras", subcategory: "verduras"}
     123  Frutas y Verduras / Verduras
    frutas-y-verduras/verduras
    """

    entries = CategoryChecklist.parse(text)
    assert CategoryChecklist.parse(CategoryChecklist.serialize(entries)) == entries
  end
end
