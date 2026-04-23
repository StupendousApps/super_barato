defmodule SuperBarato.Crawler.Category do
  @moduledoc """
  Plain struct returned by `Crawler.Chain.discover_categories/0` — one row
  per category in the chain's tree. `slug` is the full path separator-
  joined (e.g. `"congelados/pescados-y-mariscos/camarones"`); `parent_slug`
  is that path with the last segment dropped.
  """

  @enforce_keys [:chain, :slug, :name]
  defstruct [
    :chain,
    :slug,
    :name,
    :parent_slug,
    :external_id,
    :level,
    is_leaf: false
  ]

  @type t :: %__MODULE__{
          chain: atom(),
          slug: String.t(),
          name: String.t(),
          parent_slug: String.t() | nil,
          external_id: String.t() | nil,
          level: pos_integer() | nil,
          is_leaf: boolean()
        }
end
