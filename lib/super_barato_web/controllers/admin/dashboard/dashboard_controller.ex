defmodule SuperBaratoWeb.Admin.DashboardController do
  use SuperBaratoWeb, :controller

  import Ecto.Query

  alias SuperBarato.{Crawler, Repo}
  alias SuperBarato.Catalog.{Category, ChainListing, Product}
  alias SuperBarato.Linker.ProductListing

  plug :put_root_layout, html: {SuperBaratoWeb.AdminLayouts, :root}
  plug :put_layout, html: {SuperBaratoWeb.AdminLayouts, :admin}

  def index(conn, _params) do
    products = Repo.aggregate(Product, :count)
    listings = Repo.aggregate(ChainListing, :count)
    categories = Repo.aggregate(Category, :count)
    links = Repo.aggregate(ProductListing, :count)

    multi_chain_products =
      Repo.aggregate(
        from(pl in ProductListing,
          join: l in ChainListing,
          on: l.id == pl.chain_listing_id,
          group_by: pl.product_id,
          having: fragment("COUNT(DISTINCT ?)", l.chain) > 1,
          select: pl.product_id
        )
        |> subquery(),
        :count
      )

    chains = Crawler.known_chains()
    chain_labels = Enum.map(chains, &Atom.to_string/1)

    # Bucket every chain_listing as multi (product is linked across
    # 2+ chains), single (product is linked only on this chain), or
    # none (no product link). Two queries, then in-memory bucketing.
    chains_per_product =
      Repo.all(
        from pl in ProductListing,
          join: l in ChainListing,
          on: l.id == pl.chain_listing_id,
          group_by: pl.product_id,
          select: {pl.product_id, fragment("COUNT(DISTINCT ?)", l.chain)}
      )
      |> Map.new()

    listing_status =
      Repo.all(
        from l in ChainListing,
          left_join: pl in ProductListing,
          on: pl.chain_listing_id == l.id,
          select: {l.chain, pl.product_id}
      )

    buckets =
      Enum.reduce(listing_status, %{}, fn {chain, pid}, acc ->
        bucket =
          cond do
            is_nil(pid) -> :none
            Map.get(chains_per_product, pid, 0) >= 2 -> :multi
            true -> :single
          end

        Map.update(acc, {chain, bucket}, 1, &(&1 + 1))
      end)

    bars_for = fn bucket ->
      Enum.map(chains, fn c -> Map.get(buckets, {Atom.to_string(c), bucket}, 0) end)
    end

    conn
    |> assign(:page_title, "Dashboard")
    |> assign(:top_nav, :dashboard)
    |> assign(:totals, %{
      products: products,
      listings: listings,
      categories: categories,
      links: links,
      multi_chain_products: multi_chain_products
    })
    |> assign(:chain_labels, chain_labels)
    |> assign(:chain_bars, %{
      multi: bars_for.(:multi),
      single: bars_for.(:single),
      none: bars_for.(:none)
    })
    |> render(:index)
  end
end
