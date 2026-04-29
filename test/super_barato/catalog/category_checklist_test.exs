defmodule SuperBarato.Catalog.CategoryChecklistTest do
  use ExUnit.Case, async: true

  alias SuperBarato.Catalog.CategoryChecklist

  test "parses every status flavor" do
    text = """
    aaaaaaaa [ ]
       0  Bebé
    mi-bebe

    bbbbbbbb [-]
      12  Bebé / Rodados
    mi-bebe/rodados

    cccccccc [N]
       3  Marcas Tottus / Recco
    CATG27088/Electro-y-Tecnologia

    dddddddd [x] 3c84119d
     123  Frutas y Verduras / Verduras
    frutas-y-verduras/verduras
    """

    [a, b, c, d] = CategoryChecklist.parse(text)

    assert a == %{
             entry_id: "aaaaaaaa",
             status: :unchecked,
             count: 0,
             path: "Bebé",
             slug: "mi-bebe",
             mapping: nil
           }

    assert b == %{
             entry_id: "bbbbbbbb",
             status: :no_match,
             count: 12,
             path: "Bebé / Rodados",
             slug: "mi-bebe/rodados",
             mapping: nil
           }

    assert c == %{
             entry_id: "cccccccc",
             status: :no_mapping,
             count: 3,
             path: "Marcas Tottus / Recco",
             slug: "CATG27088/Electro-y-Tecnologia",
             mapping: nil
           }

    assert d == %{
             entry_id: "dddddddd",
             status: :mapped,
             count: 123,
             path: "Frutas y Verduras / Verduras",
             slug: "frutas-y-verduras/verduras",
             mapping: %{id: "3c84119d"}
           }
  end

  test "raises when entry-id is missing" do
    assert_raise ArgumentError, ~r/expected `<entry-id> <status>`/, fn ->
      CategoryChecklist.parse("[ ]\n   0  X\nx\n")
    end
  end

  test "raises on unrecognized status payload" do
    assert_raise ArgumentError, ~r/unrecognized status payload/, fn ->
      CategoryChecklist.parse("aaaaaaaa [?]\n   0  X\nx\n")
    end
  end

  test "raises when [x] payload is not an 8-char hex id" do
    assert_raise ArgumentError, ~r/expected 8-char hex id/, fn ->
      CategoryChecklist.parse("aaaaaaaa [x] notanid\n   0  X\nx\n")
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
    aaaaaaaa [ ]
       0  Bebé
    mi-bebe

    bbbbbbbb [-]
      12  Bebé / Rodados
    mi-bebe/rodados

    cccccccc [N]
       3  Marcas Tottus / Recco
    CATG27088/Electro-y-Tecnologia

    dddddddd [x] 3c84119d
     123  Frutas y Verduras / Verduras
    frutas-y-verduras/verduras
    """

    entries = CategoryChecklist.parse(text)
    assert CategoryChecklist.parse(CategoryChecklist.serialize(entries)) == entries
  end
end
