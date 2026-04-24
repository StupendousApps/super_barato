defmodule SuperBarato.Crawler.SantaIsabel do
  @moduledoc """
  Santa Isabel adapter. Cencosud-owned like Jumbo; delegates to
  `Crawler.Cencosud` with SI-specific config (sales channel 6, category
  tree at `assets.jumbo.cl/json/santaisabel/categories.json`).
  """

  @behaviour SuperBarato.Crawler.Chain

  alias SuperBarato.Crawler.Cencosud

  @config %Cencosud.Config{
    chain: :santa_isabel,
    site_url: "https://www.santaisabel.cl",
    categories_url: "https://assets.jumbo.cl/json/santaisabel/categories.json",
    sales_channel: "6"
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
