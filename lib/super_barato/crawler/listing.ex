defmodule SuperBarato.Crawler.Listing do
  @moduledoc """
  Plain struct returned by chain adapters' parsers — not yet
  persisted. Prices are integers in CLP (pesos have no decimals).

  Two parser-supplied fields carry the chain's payload verbatim:

    * `raw` — the entire chain payload (every id-shaped key, plus
      descriptions, ratings, breadcrumb, offers, etc.). Source of
      truth for everything not denormalized into a real column.
    * `identifiers_key` — the parser's canonical-string encoding of
      the id-shaped subset of `raw` (`Linker.Identity.encode/1`).
      Drives the `(chain, identifiers_key)` unique index.

  The other fields (`chain_sku`, `ean`, `name`, etc.) are
  denormalizations the parser pulls out of the same source data so
  admin tables can index/sort without JSON path expressions.
  """

  @enforce_keys [:chain, :chain_sku, :name]
  defstruct [
    :chain,
    :chain_sku,
    :chain_product_id,
    :ean,
    :name,
    :brand,
    :image_url,
    :pdp_url,
    :category_path,
    :regular_price,
    :promo_price,
    :identifiers_key,
    raw: %{},
    promotions: %{}
  ]

  @type t :: %__MODULE__{
          chain: atom(),
          chain_sku: String.t(),
          chain_product_id: String.t() | nil,
          ean: String.t() | nil,
          name: String.t(),
          brand: String.t() | nil,
          image_url: String.t() | nil,
          pdp_url: String.t() | nil,
          category_path: String.t() | nil,
          regular_price: integer() | nil,
          promo_price: integer() | nil,
          identifiers_key: String.t(),
          raw: map(),
          promotions: map()
        }
end
