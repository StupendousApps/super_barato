defmodule SuperBaratoWeb.Admin.ChainCategoryController do
  use SuperBaratoWeb, :controller

  import Ecto.Query

  alias SuperBarato.{Catalog, Crawler, Repo}
  alias SuperBarato.Catalog.ChainCategory

  plug :put_root_layout, html: {SuperBaratoWeb.AdminLayouts, :root}
  plug :put_layout, html: {SuperBaratoWeb.AdminLayouts, :admin}

  def chains, do: [nil | Crawler.known_chains()]

  def index(conn, params) do
    chain = parse_chain(params["chain"])
    q = params["q"] || ""
    type = parse_type(params["type"])
    sort = params["sort"] || "-last_seen_at"
    page = parse_int(params["page"], 1)
    per_page = parse_int(params["per_page"], 25)

    result =
      Catalog.list_categories_page(
        chain: chain,
        q: q,
        type: type,
        sort: sort,
        page: page,
        per_page: per_page
      )

    filters = %{
      chain: params["chain"] || "",
      q: q,
      type: params["type"] || "",
      per_page: params["per_page"] || ""
    }

    parent_names = parent_names_for(result.items)

    conn
    |> assign(:top_nav, :chain_categories)
    |> assign(:active_chain, chain)
    |> assign(:result, result)
    |> assign(:filters, filters)
    |> assign(:sort, sort)
    |> assign(:parent_names, parent_names)
    |> assign(:page_title, "Chain Categories")
    |> render(:index)
  end

  defp parent_names_for(items) do
    pairs =
      items
      |> Enum.flat_map(fn c ->
        if c.parent_slug, do: [{c.chain, c.parent_slug}], else: []
      end)
      |> Enum.uniq()

    case pairs do
      [] ->
        %{}

      pairs ->
        chains = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
        slugs = pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

        Repo.all(
          from c in ChainCategory,
            where: c.chain in ^chains and c.slug in ^slugs,
            select: {{c.chain, c.slug}, c.name}
        )
        |> Map.new()
    end
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

  defp parse_type("leaf"), do: :leaf
  defp parse_type("parent"), do: :parent
  defp parse_type(_), do: :all

  defp parse_int(nil, d), do: d

  defp parse_int(s, d) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} when n > 0 -> n
      _ -> d
    end
  end

  defp parse_int(_, d), do: d
end
