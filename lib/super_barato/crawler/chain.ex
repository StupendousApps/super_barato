defmodule SuperBarato.Crawler.Chain do
  @moduledoc """
  Behaviour every supermarket adapter implements.

  Adapters route all HTTP through `SuperBarato.Crawler.RateLimiter.request/3`
  with the chain's id, so discovery and price fetches share the same bucket.
  """

  @type listing_attrs :: %{
          required(:chain) => String.t(),
          required(:chain_sku) => String.t(),
          required(:name) => String.t(),
          optional(:chain_product_id) => String.t() | nil,
          optional(:ean) => String.t() | nil,
          optional(:brand) => String.t() | nil,
          optional(:image_url) => String.t() | nil,
          optional(:pdp_url) => String.t() | nil,
          optional(:category_path) => String.t() | nil,
          optional(:current_regular_price) => integer() | nil,
          optional(:current_promo_price) => integer() | nil,
          optional(:current_promotions) => map()
        }

  @type price_attrs :: %{
          required(:chain_sku) => String.t(),
          required(:regular_price) => integer(),
          optional(:promo_price) => integer() | nil,
          optional(:promotions) => map()
        }

  @doc "Atom id of the chain, e.g. `:unimarc`."
  @callback id() :: atom()

  @doc "Categories to walk during discovery. Chain-specific format (ID, slug, etc.)."
  @callback seed_categories() :: [term()]

  @doc """
  Walks one category (handling pagination internally) and returns discovered
  listings. Must route all HTTP through the rate limiter.
  """
  @callback discover_category(category :: term()) ::
              {:ok, [listing_attrs()]} | {:error, term()}

  @doc """
  Fetches current prices for the given chain SKUs. Adapters may batch.
  """
  @callback fetch_prices(chain_skus :: [String.t()]) ::
              {:ok, [price_attrs()]} | {:error, term()}
end
