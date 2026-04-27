defmodule SuperBaratoWeb.Admin.ProductController do
  @moduledoc """
  Canonical-product browser. Each row is one `Catalog.Product`; the
  per-chain price columns are populated from its linked `ChainListing`
  rows via `Linker.listings_by_product_ids/1`.
  """
  use SuperBaratoWeb, :controller

  alias SuperBarato.{Catalog, Crawler, Linker}

  plug :put_root_layout, html: {SuperBaratoWeb.AdminLayouts, :root}
  plug :put_layout, html: {SuperBaratoWeb.AdminLayouts, :admin}

  def index(conn, params) do
    q = params["q"] || ""
    ean = params["ean"] || ""
    sort = params["sort"] || "-updated_at"
    page = parse_int(params["page"], 1)
    per_page = parse_int(params["per_page"], 25)

    result =
      Catalog.list_products_page(
        q: q,
        ean: ean,
        sort: sort,
        page: page,
        per_page: per_page
      )

    listings_by_product_id =
      result.items
      |> Enum.map(& &1.id)
      |> Linker.listings_by_product_ids()

    filters = %{q: q, ean: ean, per_page: params["per_page"] || ""}

    conn
    |> assign(:top_nav, :products)
    |> assign(:result, result)
    |> assign(:listings_by_product_id, listings_by_product_id)
    |> assign(:chains, Crawler.known_chains())
    |> assign(:filters, filters)
    |> assign(:sort, sort)
    |> assign(:page_title, "Products")
    |> render(:index)
  end

  defp parse_int(nil, d), do: d

  defp parse_int(s, d) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} when n > 0 -> n
      _ -> d
    end
  end

  defp parse_int(_, d), do: d
end
