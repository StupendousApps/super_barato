defmodule SuperBarato.Crawler.Chain do
  @moduledoc """
  Behaviour every supermarket adapter implements.

  Adapters route all HTTP through `SuperBarato.Crawler.RateLimiter.request/3`
  with the chain's id, so discovery and price fetches share the same bucket.

  Adapter output is in plain structs (`Crawler.Listing`, `Crawler.Price`) —
  no Ecto or DB coupling. Persistence is handled by `SuperBarato.Catalog`.
  """

  alias SuperBarato.Crawler.{Listing, Price}

  @doc "Atom id of the chain, e.g. `:unimarc`."
  @callback id() :: atom()

  @doc "Categories to walk during discovery. Chain-specific format (ID, slug, etc.)."
  @callback seed_categories() :: [term()]

  @doc """
  Walks one category (handling pagination internally) and returns discovered
  listings. Must route all HTTP through the rate limiter.
  """
  @callback discover_category(category :: term()) ::
              {:ok, [Listing.t()]} | {:error, term()}

  @doc """
  Fetches current prices for the given chain SKUs. Adapters may batch.
  """
  @callback fetch_prices(chain_skus :: [String.t()]) ::
              {:ok, [Price.t()]} | {:error, term()}
end
