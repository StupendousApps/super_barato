defmodule SuperBarato.Crawler.SantaIsabel do
  @moduledoc """
  Santa Isabel adapter. Cencosud-owned like Jumbo. Products are
  discovered through a Supabase-hosted sitemap (`santaisabel-custom.xml`,
  ~15k URLs) referenced from the official `www.santaisabel.cl/sitemap.xml`;
  PDPs are fetched directly from Cencosud's nginx (no Cloudflare,
  reachable from prod).
  """

  @behaviour SuperBarato.Crawler.Chain

  alias SuperBarato.Crawler.Cencosud

  @config %Cencosud.Config{
    chain: :santa_isabel,
    site_url: "https://www.santaisabel.cl",
    categories_url: "https://assets.santaisabel.cl/sitemap/sitemap-categories.xml",
    sales_channel: "6",
    sitemap_index: "https://www.santaisabel.cl/sitemap.xml"
  }

  @doc "Exposed so `Cencosud.ProductProducer` can fetch the sitemap layout."
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
