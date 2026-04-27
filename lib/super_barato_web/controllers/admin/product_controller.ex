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

    product_ids = Enum.map(result.items, & &1.id)

    listings_by_product_id = Linker.listings_by_product_ids(product_ids)
    eans_by_product_id = Catalog.eans_by_product_ids(product_ids)

    filters = %{q: q, ean: ean, per_page: params["per_page"] || ""}

    conn
    |> assign(:top_nav, :products)
    |> assign(:result, result)
    |> assign(:listings_by_product_id, listings_by_product_id)
    |> assign(:eans_by_product_id, eans_by_product_id)
    |> assign(:chains, Crawler.known_chains())
    |> assign(:filters, filters)
    |> assign(:sort, sort)
    |> assign(:page_title, "Products")
    |> render(:index)
  end

  def show(conn, %{"id" => id} = params) do
    product = SuperBarato.Repo.get!(SuperBarato.Catalog.Product, id)
    listings = Linker.listings_for_product(product.id)
    linked_listing_ids = MapSet.new(listings, & &1.id)
    sources = Linker.sources_by_listing(product.id)
    eans = Catalog.eans_for_product(product.id)

    # Listing search params — only run a search if the admin
    # actually typed something; the page should still load fast for
    # admins who just want to view linked listings.
    q = params["q"] || ""
    chain = parse_chain(params["chain"])
    ean = params["ean"] || ""
    page = parse_int(params["page"], 1)
    per_page = parse_int(params["per_page"], 50)

    search_active? = q != "" or ean != "" or chain != nil

    search_result =
      if search_active? do
        Catalog.list_listings_page(
          q: q,
          ean: ean,
          chain: chain,
          page: page,
          per_page: per_page
        )
      end

    {search_products_by_id, search_chains_by_product_id} =
      if search_result do
        listing_ids = Enum.map(search_result.items, & &1.id)
        products = Linker.products_by_listing_ids(listing_ids)
        product_ids = products |> Map.values() |> Enum.map(& &1.id) |> Enum.uniq()
        chains = Linker.chains_by_product_ids(product_ids)
        {products, chains}
      else
        {%{}, %{}}
      end

    conn
    |> assign(:top_nav, :products)
    |> assign(:product, product)
    |> assign(:listings, listings)
    |> assign(:linked_listing_ids, linked_listing_ids)
    |> assign(:sources, sources)
    |> assign(:eans, eans)
    |> assign(:search_active, search_active?)
    |> assign(:search_result, search_result)
    |> assign(:search_products_by_id, search_products_by_id)
    |> assign(:search_chains_by_product_id, search_chains_by_product_id)
    |> assign(:search_filters, %{
      q: q,
      ean: ean,
      chain: params["chain"] || "",
      per_page: params["per_page"] || ""
    })
    |> assign(:chains, [nil | Crawler.known_chains()])
    |> assign(:page_title, product.canonical_name)
    |> render(:show)
  end

  def link_listing(conn, %{"id" => id, "listing_id" => listing_id} = params) do
    SuperBarato.Repo.get!(SuperBarato.Catalog.Product, id)
    SuperBarato.Repo.get!(SuperBarato.Catalog.ChainListing, listing_id)

    case Linker.link_admin(id, listing_id) do
      {:ok, _} -> put_flash(conn, :info, "Linked.")
      {:error, reason} -> put_flash(conn, :error, "Couldn't link: #{inspect(reason)}")
    end
    |> redirect(to: ~p"/products/#{id}?#{search_qs(params)}")
  end

  def unlink_listing(conn, %{"id" => id, "listing_id" => listing_id} = params) do
    case Linker.unlink(id, listing_id) do
      :ok -> put_flash(conn, :info, "Unlinked.")
      :not_found -> put_flash(conn, :error, "No link found.")
    end
    |> redirect(to: ~p"/products/#{id}?#{search_qs(params)}")
  end

  defp search_qs(params) do
    params
    |> Map.take(["q", "ean", "chain", "page"])
    |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
    |> Enum.into(%{})
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

  def merge_new(conn, %{"id" => id} = params) do
    source = SuperBarato.Repo.get!(SuperBarato.Catalog.Product, id)
    q = params["q"] || source.canonical_name || ""
    ean = params["ean"] || ""
    page = parse_int(params["page"], 1)

    result = Catalog.list_products_page(q: q, ean: ean, page: page, per_page: 25)
    # Don't suggest merging into self.
    candidates = Enum.reject(result.items, &(&1.id == source.id))
    eans_by_product_id =
      Catalog.eans_by_product_ids(Enum.map(candidates, & &1.id))

    conn
    |> assign(:top_nav, :products)
    |> assign(:source, source)
    |> assign(:candidates, candidates)
    |> assign(:eans_by_product_id, eans_by_product_id)
    |> assign(:result, result)
    |> assign(:filters, %{q: q, ean: ean})
    |> assign(:page_title, "Merge · #{source.canonical_name}")
    |> render(:merge_picker)
  end

  def merge_create(conn, %{"id" => source_id, "target_id" => target_id}) do
    {tid, _} = Integer.parse(target_id)
    {sid, _} = Integer.parse(source_id)

    case Linker.merge_products(tid, sid) do
      {:ok, _target} ->
        conn
        |> put_flash(:info, "Merged.")
        |> redirect(to: ~p"/products/#{tid}")

      {:error, reason} ->
        conn
        |> put_flash(:error, "Merge failed: #{inspect(reason)}")
        |> redirect(to: ~p"/products/#{sid}/merge")
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
