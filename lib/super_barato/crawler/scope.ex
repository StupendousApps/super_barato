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

  Match is by **top-level slug** (first path segment). All descendants
  of a blacklisted top-level are also blacklisted — sub-trees aren't
  individually addressable here.
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
    ),
    "unimarc" => ~w(
      hogar
    ),
    "tottus" => ~w(),
    # Empty until we see Acuenta's actual category tree (Instaleap
    # multi-tenant — top-levels not yet known). Filled in once the
    # parser lands.
    "acuenta" => ~w()
  }

  @blacklist_sets Map.new(@blacklists, fn {chain, slugs} ->
                    {chain, MapSet.new(slugs)}
                  end)

  @doc "True iff `slug`'s top-level segment is on `chain`'s blacklist."
  @spec blacklisted?(atom() | String.t(), String.t()) :: boolean()
  def blacklisted?(chain, slug) when is_atom(chain),
    do: blacklisted?(Atom.to_string(chain), slug)

  def blacklisted?(chain, slug) when is_binary(chain) and is_binary(slug) do
    top = slug |> String.split("/", parts: 2) |> List.first()
    @blacklist_sets |> Map.get(chain, MapSet.new()) |> MapSet.member?(top)
  end

  def blacklisted?(_, _), do: false

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
