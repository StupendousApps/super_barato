defmodule SuperBarato.Crawler.Listing do
  @moduledoc """
  Plain struct returned by `Crawler.Chain.discover_category/1`.

  Represents a single product-SKU snapshot as extracted from the chain's
  listing — not yet persisted. `chain` is an atom; prices are integers in
  CLP (pesos have no decimals).
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
          promotions: map()
        }
end
