defmodule SuperBarato.Crawler.ScopeTest do
  use ExUnit.Case, async: true

  alias SuperBarato.Crawler.{Category, Scope}

  describe "blacklisted?/2" do
    test "drops Jumbo non-grocery top-levels" do
      assert Scope.blacklisted?(:jumbo, "hogar-jugueteria-y-libreria")
      assert Scope.blacklisted?(:jumbo, "hogar-jugueteria-y-libreria/juguetes/educativos")
      refute Scope.blacklisted?(:jumbo, "experiencias-jumbo")
    end

    test "drops Lider TVs / furniture / clothing / hardware" do
      for top <- ~w(hogar tecno-y-electro vestuario ferreteria
                    automovil parrillas-y-jardin mainstays
                    libreria-y-cumpleanos deporte-y-aire-libre) do
        assert Scope.blacklisted?(:lider, top), "expected #{top} blacklisted"
        assert Scope.blacklisted?(:lider, top <> "/anything/deeper")
      end
    end

    test "drops Unimarc hogar; keeps everything else" do
      assert Scope.blacklisted?(:unimarc, "hogar")
      refute Scope.blacklisted?(:unimarc, "limpieza")
      refute Scope.blacklisted?(:unimarc, "perfumeria")
      refute Scope.blacklisted?(:unimarc, "mascotas")
      refute Scope.blacklisted?(:unimarc, "bebes-y-ninos")
    end

    test "keeps food/drinks across chains" do
      for {chain, slug} <- [
            {:jumbo, "despensa"},
            {:jumbo, "frutas-y-verduras"},
            {:lider, "frescos-y-lacteos"},
            {:lider, "bebidas-y-snacks"},
            {:unimarc, "lacteos-huevos-y-refrigerados"},
            {:santa_isabel, "carnes-y-pescados"}
          ] do
        refute Scope.blacklisted?(chain, slug), "#{chain}/#{slug} should be in scope"
      end
    end

    test "keeps adjacent categories user said to keep (cleaning, perfume, baby, pet)" do
      refute Scope.blacklisted?(:lider, "limpieza-y-aseo")
      refute Scope.blacklisted?(:lider, "mascotas")
      refute Scope.blacklisted?(:lider, "salud-y-estilos-de-vida")
      refute Scope.blacklisted?(:lider, "perfumeria-y-salud")
      refute Scope.blacklisted?(:lider, "la-boti")
      # The mixed bebé+jugueteria branch is kept whole; user said babies stay.
      refute Scope.blacklisted?(:lider, "mundo-bebe-y-jugueteria")
    end

    test "unknown chain → never blacklisted" do
      refute Scope.blacklisted?(:nonsense, "hogar")
    end
  end

  describe "filter/2" do
    test "drops blacklisted categories from a list" do
      cats = [
        %Category{chain: :lider, slug: "frescos-y-lacteos", name: "x", level: 1},
        %Category{chain: :lider, slug: "vestuario", name: "x", level: 1},
        %Category{chain: :lider, slug: "vestuario/calcetines", name: "x", level: 2},
        %Category{chain: :lider, slug: "despensa", name: "x", level: 1}
      ]

      kept = Scope.filter(:lider, cats) |> Enum.map(& &1.slug)
      assert kept == ["frescos-y-lacteos", "despensa"]
    end
  end
end
