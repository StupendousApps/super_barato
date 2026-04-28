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
  structs. Used by each chain's `discover_categories` immediately
  before `mark_leaves/1`.
  """
  @spec filter(atom() | String.t(), [struct()]) :: [struct()]
  def filter(chain, categories) when is_list(categories) do
    Enum.reject(categories, &blacklisted?(chain, &1.slug))
  end
end
