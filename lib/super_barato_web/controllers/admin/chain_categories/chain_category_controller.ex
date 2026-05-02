defmodule SuperBaratoWeb.Admin.ChainCategoryController do
  use SuperBaratoWeb, :controller

  import Ecto.Query

  alias SuperBarato.{Catalog, Crawler, Repo}
  alias SuperBarato.Catalog.{ChainCategory, ChainListing, ChainListingCategory}

  plug :put_root_layout, html: {SuperBaratoWeb.AdminLayouts, :root}
  plug :put_layout, html: {SuperBaratoWeb.AdminLayouts, :admin}

  def chains, do: [nil | Crawler.known_chains()]

  def index(conn, params) do
    chain = parse_chain(params["chain"])
    q = params["q"] || ""
    type = parse_type(params["type"])
    crawl = parse_crawl(params["crawl"])
    sort = params["sort"] || "-last_seen_at"
    page = parse_int(params["page"], 1)
    per_page = parse_int(params["per_page"], 25)

    result =
      Catalog.list_categories_page(
        chain: chain,
        q: q,
        type: type,
        crawl: crawl,
        sort: sort,
        page: page,
        per_page: per_page
      )

    filters = %{
      chain: params["chain"] || "",
      q: q,
      type: params["type"] || "",
      crawl: params["crawl"] || "",
      per_page: params["per_page"] || ""
    }

    parent_names = parent_names_for(result.items)
    listing_counts = listing_counts_for(result.items)

    conn
    |> assign(:top_nav, :chain_categories)
    |> assign(:active_chain, chain)
    |> assign(:result, result)
    |> assign(:filters, filters)
    |> assign(:sort, sort)
    |> assign(:parent_names, parent_names)
    |> assign(:listing_counts, listing_counts)
    |> assign(:page_title, "Chain Categories")
    |> render(:index)
  end

  defp listing_counts_for([]), do: %{}

  defp listing_counts_for(items) do
    ids = Enum.map(items, & &1.id)

    Repo.all(
      from clc in ChainListingCategory,
        where: clc.chain_category_id in ^ids,
        group_by: clc.chain_category_id,
        select: {clc.chain_category_id, count(clc.chain_listing_id)}
    )
    |> Map.new()
  end

  def edit(conn, %{"id" => id}) do
    category = Repo.get!(ChainCategory, id)
    changeset = ChainCategory.edit_changeset(category, %{})

    conn
    |> assign(:top_nav, :chain_categories)
    |> assign(:category, category)
    |> assign(:changeset, changeset)
    |> assign(:listings, listings_for_category(category.id))
    |> assign(:page_title, "Edit · #{category.name}")
    |> render(:edit)
  end

  defp listings_for_category(category_id) do
    Repo.all(
      from l in ChainListing,
        join: clc in ChainListingCategory,
        on: clc.chain_listing_id == l.id,
        where: clc.chain_category_id == ^category_id,
        order_by: [desc: l.last_discovered_at]
    )
  end

  def delete_listings(conn, %{"id" => id}) do
    category = Repo.get!(ChainCategory, id)

    cond do
      category.crawl_enabled ->
        conn
        |> put_flash(:error, "Desactiva el crawl antes de borrar los listings.")
        |> redirect(to: ~p"/chain-categories/#{category.id}/edit")

      true ->
        {:ok, %{listings: l, products: p}} =
          Catalog.delete_chain_category_listings(category.id)

        conn
        |> put_flash(:info, "Eliminados #{l} listings y #{p} productos huérfanos.")
        |> redirect(to: ~p"/chain-categories/#{category.id}/edit")
    end
  end

  def update(conn, %{"id" => id, "chain_category" => attrs}) do
    category = Repo.get!(ChainCategory, id)

    case category |> ChainCategory.edit_changeset(attrs) |> Repo.update() do
      {:ok, _updated} ->
        conn
        |> put_flash(:info, "Categoría actualizada.")
        |> redirect(to: ~p"/chain-categories?#{[chain: category.chain, q: category.slug]}")

      {:error, changeset} ->
        conn
        |> assign(:top_nav, :chain_categories)
        |> assign(:category, category)
        |> assign(:changeset, changeset)
        |> assign(:listings, listings_for_category(category.id))
        |> assign(:page_title, "Edit · #{category.name}")
        |> render(:edit)
    end
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

  defp parse_crawl("enabled"), do: :enabled
  defp parse_crawl("disabled"), do: :disabled
  defp parse_crawl(_), do: :all

  defp parse_int(nil, d), do: d

  defp parse_int(s, d) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} when n > 0 -> n
      _ -> d
    end
  end

  defp parse_int(_, d), do: d
end
