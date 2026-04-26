defmodule SuperBarato.Crawler.Jumbo do
  @moduledoc """
  Jumbo adapter. Categories are still discovered from the legacy
  `assets.jumbo.cl/json/categories.json` (CloudFront/S3, no bot
  protection — works fine from prod). Products are now discovered via
  the public sitemap and individual PDPs parsed for JSON-LD price
  data; the old VTEX `?sc=*` API path is gone.
  """

  @behaviour SuperBarato.Crawler.Chain

  alias SuperBarato.Crawler.Cencosud

  @config %Cencosud.Config{
    chain: :jumbo,
    site_url: "https://www.jumbo.cl",
    categories_url: "https://assets.jumbo.cl/json/categories.json",
    sales_channel: "1",
    sitemap_index: "https://assets.jumbo.cl/sitemap.xml"
  }

  @doc "Exposed so `Cencosud.SitemapProducer` can fetch the sitemap layout."
  def cencosud_config, do: @config

  @impl true
  def id, do: @config.chain

  @impl true
  def refresh_identifier, do: :chain_sku

  @impl true
  def handle_task({:discover_categories, %{parent: _}}),
    do: Cencosud.discover_categories(@config)

  def handle_task({:fetch_product_pdp, %{url: url}}),
    do: Cencosud.fetch_product_pdp(@config, url)

  def handle_task(other), do: {:error, {:unsupported_task, other}}
end
