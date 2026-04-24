defmodule SuperBarato.Crawler.Jumbo do
  @moduledoc """
  Jumbo adapter. Delegates all three stages to `Crawler.Cencosud` with a
  Jumbo-specific `Config{}` (sales channel 1, its own `categories.json`
  path under `assets.jumbo.cl`).
  """

  @behaviour SuperBarato.Crawler.Chain

  alias SuperBarato.Crawler.Cencosud

  @config %Cencosud.Config{
    chain: :jumbo,
    site_url: "https://www.jumbo.cl",
    categories_url: "https://assets.jumbo.cl/json/categories.json",
    sales_channel: "1"
  }

  @impl true
  def id, do: @config.chain

  @impl true
  def refresh_identifier, do: :chain_sku

  @impl true
  def handle_task({:discover_categories, %{parent: _}}),
    do: Cencosud.discover_categories(@config)

  def handle_task({:discover_products, %{slug: slug}}),
    do: Cencosud.discover_products(@config, slug)

  def handle_task({:fetch_product_info, %{identifiers: ids}}),
    do: Cencosud.fetch_product_info(@config, ids)

  def handle_task(other), do: {:error, {:unsupported_task, other}}
end
