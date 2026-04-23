defmodule SuperBarato.Crawler.Chain do
  @moduledoc """
  Behaviour every supermarket adapter implements. Three stages:

    * `discover_categories/0` — walks the chain's category tree.
    * `discover_products/1` — enumerates every SKU in a given leaf
      category, paginating as needed.
    * `fetch_product_info/1` — refreshes price + metadata for a batch
      of EANs already known to the system.

  Adapters route all HTTP through `Crawler.Http` (curl-impersonate) and
  `Crawler.RateLimiter` so the chain's politeness budget is shared
  across all three stages.

  Stage outputs are plain structs (`Crawler.Category`, `Crawler.Listing`)
  — no Ecto. Persistence is the `SuperBarato.Catalog` context's job.
  """

  alias SuperBarato.Crawler.{Category, Listing}

  @doc "Atom id of the chain, e.g. `:unimarc`."
  @callback id() :: atom()

  @doc """
  Which `ChainListing` field the chain's `fetch_product_info/1` keys on.

    * `:ean` — adapter expects a list of EAN-13 strings (Unimarc).
    * `:chain_sku` — adapter expects a list of the chain's internal SKUs
      (Jumbo uses VTEX itemIds).

  The Crawler facade reads this to pick the right column when building
  the batch for stage 3.
  """
  @callback refresh_identifier() :: :ean | :chain_sku

  @doc """
  Walks the chain's category tree. Returns a flat list of `%Category{}`
  structs (top-levels + sub-categories + leaves). Parent/child
  relationships are expressed through `parent_slug`.
  """
  @callback discover_categories() :: {:ok, [Category.t()]} | {:error, term()}

  @doc """
  Enumerates products in a leaf category, paginating through the chain's
  search API until exhausted. Returns `%Listing{}` structs with whatever
  fields the endpoint happens to include (prices optional).
  """
  @callback discover_products(category_slug :: String.t()) ::
              {:ok, [Listing.t()]} | {:error, term()}

  @doc """
  Refreshes product info (price, promo, image, etc.) for a batch of
  EANs. The chain is expected to batch internally to fit API limits.
  """
  @callback fetch_product_info(eans :: [String.t()]) ::
              {:ok, [Listing.t()]} | {:error, term()}
end
