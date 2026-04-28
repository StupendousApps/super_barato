defmodule SuperBarato.Crawler.Jumbo do
  @moduledoc """
  Jumbo adapter. Categories are discovered by parsing the home page's
  `window.__renderData` blob (the menu Jumbo's SPA actually renders).
  Two earlier sources turned out to be too stale: the XML category
  sitemap (`assets.jumbo.cl/sitemap/category-0.xml`) and the BFF
  `categories.json` both keep entries for slugs that 301 to a new
  taxonomy or 410 outright. `__renderData` is the only source that
  matches what's currently displayed in the navigation menu.

  Products are still discovered via the public product sitemap and
  individual PDPs parsed for JSON-LD price data; the old VTEX
  `?sc=*` API path is gone.
  """

  @behaviour SuperBarato.Crawler.Chain

  alias SuperBarato.Crawler.Cencosud

  @home_url "https://www.jumbo.cl/"

  @config %Cencosud.Config{
    chain: :jumbo,
    site_url: "https://www.jumbo.cl",
    # Kept for Cencosud.Config's enforce_keys, but no longer the source
    # of category discovery — see `discover_categories_from_home/2`.
    categories_url: "https://assets.jumbo.cl/sitemap/category-0.xml",
    sales_channel: "1",
    sitemap_index: "https://assets.jumbo.cl/sitemap.xml"
  }

  @doc "Exposed so `Cencosud.ProductProducer` can fetch the sitemap layout."
  def cencosud_config, do: @config

  @impl true
  def id, do: @config.chain

  @impl true
  def refresh_identifier, do: :chain_sku

  @impl true
  def handle_task({:discover_categories, %{parent: _}}),
    do: Cencosud.discover_categories_from_home(@config, @home_url)

  def handle_task({:fetch_product_pdp, %{url: url}}),
    do: Cencosud.fetch_product_pdp(@config, url)

  def handle_task(other), do: {:error, {:unsupported_task, other}}
end
