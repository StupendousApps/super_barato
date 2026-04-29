defmodule SuperBarato.Crawler.Chain do
  @moduledoc """
  Behaviour every supermarket adapter implements. The pipeline Worker
  dispatches tagged task tuples to `handle_task/1`; the adapter does
  the HTTP, parses, and returns one of:

    * `{:ok, payload}` — success; Results will persist `payload`.
    * `:blocked` — the server rejected us (Akamai challenge, TLS
      fingerprint block, etc.). Worker rotates the chain's curl-
      impersonate profile and requeues the same task.
    * `{:error, reason}` — transport failure or malformed response.
      Worker logs and moves on.

  Task shapes the Worker may dispatch:

    * `{:discover_categories, %{chain: atom, parent: slug | nil}}`
    * `{:discover_products, %{chain: atom, slug: String.t()}}`
    * `{:fetch_product_info, %{chain: atom, identifiers: [String.t()]}}`
    * `{:fetch_product_pdp, %{chain: atom, url: String.t()}}` — used
      by sitemap-driven adapters: fetch one product detail page and
      parse its embedded JSON-LD into a `%Listing{}`.

  Adapters also declare `id/0` and `refresh_identifier/0`; the latter
  tells the pipeline which column (`:ean` or `:chain_sku`) to batch on
  during stage-3 refresh.
  """

  alias SuperBarato.Crawler.{ChainCategory, Listing}

  @type task ::
          {:discover_categories, %{chain: atom(), parent: String.t() | nil}}
          | {:discover_products, %{chain: atom(), slug: String.t()}}
          | {:fetch_product_info, %{chain: atom(), identifiers: [String.t()]}}
          | {:fetch_product_pdp, %{chain: atom(), url: String.t()}}

  @type payload :: [ChainCategory.t()] | [Listing.t()]

  @callback id() :: atom()

  @callback refresh_identifier() :: :ean | :chain_sku

  @callback handle_task(task()) ::
              {:ok, payload()} | :blocked | {:error, term()}
end
