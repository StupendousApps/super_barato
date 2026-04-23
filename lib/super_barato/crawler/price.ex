defmodule SuperBarato.Crawler.Price do
  @moduledoc """
  Plain struct returned by `Crawler.Chain.fetch_prices/1`.
  """

  @enforce_keys [:chain_sku, :regular_price]
  defstruct [:chain_sku, :regular_price, :promo_price, promotions: %{}]

  @type t :: %__MODULE__{
          chain_sku: String.t(),
          regular_price: integer(),
          promo_price: integer() | nil,
          promotions: map()
        }
end
