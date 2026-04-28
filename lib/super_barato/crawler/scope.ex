defmodule SuperBarato.Crawler.Scope do
  @moduledoc """
  Per-chain top-level category blacklist. Each chain's
  `discover_categories` consults this before returning, dropping
  branches we don't want in the catalog: TVs / electronics, furniture /
  homewares, clothing, hardware, sporting goods, books, toys-only
  shelves, automotive.

  Everything else is kept — including pet, cleaning, baby supplies,
  perfumería, pharmacy. Mixed branches (e.g. Lider's
  `mundo-bebe-y-jugueteria`, `marcas-americanas`) are kept whole;
  the cross-chain Linker simply leaves the non-food sub-listings as
  single-chain rows.

  Match is by **path prefix**. Each blacklist entry is a slash-joined
  slug; if the listing's slug equals or descends from that prefix it's
  blacklisted. Top-level entries (`hogar`) catch the entire branch;
  multi-segment entries (`mundo-bebe-y-jugueteria/jugueteria`) drop
  a sub-tree while leaving siblings (`mundo-bebe-y-jugueteria/bebes`)
  in scope.
  """

  @blacklists %{
    "jumbo" => ~w(
      hogar-jugueteria-y-libreria
    ),
    "santa_isabel" => ~w(
      hogar
      hogar-jugueteria-y-libreria
    ),
    # Lider blacklist mixes historical and current slugs. The old
    # umbrellas (`tecno-y-electro`, `vestuario`, `deporte-y-aire-libre`)
    # got split into per-vertical entries (`tecno`, `celulares`, etc.);
    # the historical entries stay for defensive coverage of older
    # snapshot fixtures, the current ones cover live discovery.
    "lider" => ~w(
      hogar
      libreria-y-cumpleanos
      tecno-y-electro
      ferreteria
      vestuario
      deporte-y-aire-libre
      parrillas-y-jardin
      automovil
      mainstays
      mundo-bebe-y-jugueteria/jugueteria
      aprovecha-tu-lider-bci
      tecno
      celulares
      computacion
      electrohogar
      muebles
      dormitorio
      decohogar
      climatizacion
      juguetes-y-entretencion
      mujer
      hombre
      infantil
      maletas-y-accesorios-de-viaje
      deportes-y-aire-libre
    ),
    "unimarc" => ~w(
      hogar
    ),
    "tottus" => ~w(
      CATG29085/Ofertas
      CATG24817/Black-Week
      CATG25257/San-Valentin
      CATG27086/Celebraciones
    ),
    "acuenta" => ~w(
      hogar-entretencion-y-tecnologia
    )
  }

  @blacklist_sets Map.new(@blacklists, fn {chain, slugs} ->
                    {chain, MapSet.new(slugs)}
                  end)

  @doc """
  True iff any path-prefix of `slug` matches an entry on `chain`'s
  blacklist. A blacklisted prefix drops itself and every descendant.
  """
  @spec blacklisted?(atom() | String.t(), String.t()) :: boolean()
  def blacklisted?(chain, slug) when is_atom(chain),
    do: blacklisted?(Atom.to_string(chain), slug)

  def blacklisted?(chain, slug) when is_binary(chain) and is_binary(slug) do
    set = Map.get(@blacklist_sets, chain, MapSet.new())

    if MapSet.size(set) == 0 do
      false
    else
      slug
      |> String.split("/")
      |> prefixes()
      |> Enum.any?(&MapSet.member?(set, &1))
    end
  end

  def blacklisted?(_, _), do: false

  # ["a", "b", "c"] -> ["a", "a/b", "a/b/c"]
  defp prefixes(segments) do
    segments
    |> Enum.scan([], fn seg, acc -> acc ++ [seg] end)
    |> Enum.map(&Enum.join(&1, "/"))
  end

  @doc "Inverse of `blacklisted?/2`."
  @spec in_scope?(atom() | String.t(), String.t()) :: boolean()
  def in_scope?(chain, slug), do: not blacklisted?(chain, slug)

  @doc """
  Drops blacklisted categories from a list of `%Crawler.Category{}`
  structs, including descendants of blacklisted categories whose own
  slug doesn't share the blacklisted prefix. Used by each chain's
  `discover_categories` immediately before `mark_leaves/1`.

  Slug-prefix matching alone is sufficient for chains where slugs
  encode the path (Cencosud / Lider — `hogar-jugueteria/jugueteria/...`),
  but Tottus uses flat per-node slugs (`CATG27997/Menaje`) where the
  hierarchy lives only in `parent_slug`. We also walk the parent chain
  so blacklisting `CATG25257/San-Valentin` correctly drops every
  descendant the slug-prefix would miss.
  """
  @spec filter(atom() | String.t(), [struct()]) :: [struct()]
  def filter(chain, categories) when is_list(categories) do
    by_slug = Map.new(categories, &{&1.slug, &1})

    Enum.reject(categories, fn cat ->
      blacklisted?(chain, cat.slug) or ancestor_blacklisted?(chain, cat, by_slug)
    end)
  end

  defp ancestor_blacklisted?(chain, %{parent_slug: parent}, by_slug) when is_binary(parent) do
    cond do
      blacklisted?(chain, parent) -> true
      true ->
        case Map.get(by_slug, parent) do
          nil -> false
          ancestor -> ancestor_blacklisted?(chain, ancestor, by_slug)
        end
    end
  end

  defp ancestor_blacklisted?(_chain, _cat, _by_slug), do: false
end
