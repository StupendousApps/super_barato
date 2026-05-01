defmodule SuperBarato.Crawler.SantaIsabel do
  @moduledoc """
  Santa Isabel adapter. Cencosud-owned like Jumbo and shares the
  same `window.__renderData`-driven category source on its home page.
  Products are discovered through a Supabase-hosted sitemap
  (`santaisabel-custom.xml`, ~15k URLs) referenced from the official
  `www.santaisabel.cl/sitemap.xml`; PDPs are fetched directly from
  Cencosud's nginx (no Cloudflare, reachable from prod).
  """

  @behaviour SuperBarato.Crawler.Chain

  alias SuperBarato.Crawler.Cencosud

  @home_url "https://www.santaisabel.cl/"

  @config %Cencosud.Config{
    chain: :santa_isabel,
    site_url: "https://www.santaisabel.cl",
    # Kept for Cencosud.Config's enforce_keys, but the XML category
    # sitemap is stale (mix of 301/410); discovery now reads
    # `window.__renderData` from the home page instead.
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
    do: Cencosud.discover_categories_from_home(@config, @home_url)

  # Category-walk path — `Chain.ProductProducer` enqueues one of these
  # per leaf category. Returns up to 40 priced listings per request via
  # the same Instaleap endpoint Acuenta uses; ~40× faster than the
  # legacy per-PDP sitemap walk below, which is kept as a fallback.
  def handle_task({:discover_products, %{slug: slug}}),
    do: Cencosud.discover_products(@config, slug)

  def handle_task({:fetch_product_pdp, %{url: url}}),
    do: Cencosud.fetch_product_pdp(@config, url)

  def handle_task(other), do: {:error, {:unsupported_task, other}}
end
