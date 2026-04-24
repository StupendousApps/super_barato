defmodule SuperBaratoWeb.Admin.CategoryController do
  use SuperBaratoWeb, :controller

  alias SuperBarato.{Catalog, Crawler}

  plug :put_root_layout, html: {SuperBaratoWeb.AdminLayouts, :root}
  plug :put_layout, html: {SuperBaratoWeb.AdminLayouts, :app}

  def chains, do: [nil | Crawler.known_chains()]

  def index(conn, params) do
    chain = parse_chain(params["chain"])
    q = params["q"] || ""
    leaves_only = params["leaves_only"] == "yes"
    sort = params["sort"] || "-last_seen_at"
    page = parse_int(params["page"], 1)
    per_page = parse_int(params["per_page"], 25)

    result =
      Catalog.list_categories_page(
        chain: chain,
        q: q,
        leaves_only: leaves_only,
        sort: sort,
        page: page,
        per_page: per_page
      )

    filters = %{
      chain: params["chain"] || "",
      q: q,
      leaves_only: params["leaves_only"] || "",
      per_page: params["per_page"] || ""
    }

    conn
    |> assign(:top_nav, :categories)
    |> assign(:active_chain, chain)
    |> assign(:result, result)
    |> assign(:filters, filters)
    |> assign(:sort, sort)
    |> assign(:page_title, "Categories")
    |> render(:index)
  end

  defp parse_chain(nil), do: nil
  defp parse_chain(""), do: nil

  defp parse_chain(s) when is_binary(s) do
    try do
      atom = String.to_existing_atom(s)
      if atom in Crawler.known_chains(), do: atom, else: nil
    rescue
      ArgumentError -> nil
    end
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
