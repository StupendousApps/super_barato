defmodule SuperBarato.Crawler.ScopeTest do
  use ExUnit.Case, async: true

  alias SuperBarato.Crawler.{ChainCategory, Scope}

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

    test "drops Lider current-nav promos and split-out departments" do
      for top <- ~w(aprovecha-tu-lider-bci tecno celulares computacion
                    electrohogar muebles dormitorio decohogar climatizacion
                    juguetes-y-entretencion mujer hombre infantil
                    maletas-y-accesorios-de-viaje deportes-y-aire-libre) do
        assert Scope.blacklisted?(:lider, top), "expected #{top} blacklisted"
        assert Scope.blacklisted?(:lider, top <> "/87654321")
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
    end

    test "Lider mundo-bebe-y-jugueteria: keeps the parent + bebés siblings, drops jugueteria sub-tree" do
      refute Scope.blacklisted?(:lider, "mundo-bebe-y-jugueteria")
      refute Scope.blacklisted?(:lider, "mundo-bebe-y-jugueteria/panales-y-toallas-humedas")
      refute Scope.blacklisted?(:lider, "mundo-bebe-y-jugueteria/alimentacion-bebe")

      assert Scope.blacklisted?(:lider, "mundo-bebe-y-jugueteria/jugueteria")
      assert Scope.blacklisted?(:lider, "mundo-bebe-y-jugueteria/jugueteria/vehiculos-y-rodados")
      assert Scope.blacklisted?(:lider, "mundo-bebe-y-jugueteria/jugueteria/peluches/oso-de-felpa")
    end

    test "unknown chain → never blacklisted" do
      refute Scope.blacklisted?(:nonsense, "hogar")
    end
  end

  describe "filter/2" do
    test "drops blacklisted categories from a list" do
      cats = [
        %ChainCategory{chain: :lider, slug: "frescos-y-lacteos", name: "x", level: 1},
        %ChainCategory{chain: :lider, slug: "vestuario", name: "x", level: 1},
        %ChainCategory{chain: :lider, slug: "vestuario/calcetines", name: "x", level: 2},
        %ChainCategory{chain: :lider, slug: "despensa", name: "x", level: 1}
      ]

      kept = Scope.filter(:lider, cats) |> Enum.map(& &1.slug)
      assert kept == ["frescos-y-lacteos", "despensa"]
    end

    test "drops descendants whose flat slug doesn't share the blacklisted prefix" do
      # Tottus: blacklist `CATG25257/San-Valentin`, expect `CATG27997/Menaje`
      # (a child) to drop too even though their slugs share no prefix.
      cats = [
        %ChainCategory{chain: :tottus, slug: "CATG25257/San-Valentin", name: "x",
                  level: 1, parent_slug: nil},
        %ChainCategory{chain: :tottus, slug: "CATG27997/Menaje", name: "x",
                  level: 2, parent_slug: "CATG25257/San-Valentin"},
        %ChainCategory{chain: :tottus, slug: "CATG28001/Sub", name: "x",
                  level: 3, parent_slug: "CATG27997/Menaje"},
        %ChainCategory{chain: :tottus, slug: "CATG27055/Despensa", name: "x",
                  level: 1, parent_slug: nil}
      ]

      kept = Scope.filter(:tottus, cats) |> Enum.map(& &1.slug)
      assert kept == ["CATG27055/Despensa"]
    end
  end
end
