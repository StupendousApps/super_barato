defmodule SuperBaratoWeb.Admin.ListingController do
  use SuperBaratoWeb, :controller

  alias SuperBarato.{Catalog, Crawler, Linker}

  plug :put_root_layout, html: {SuperBaratoWeb.AdminLayouts, :root}
  plug :put_layout, html: {SuperBaratoWeb.AdminLayouts, :admin}

  # "All" plus one per known chain. Rendered as a sub-nav tab strip.
  def chains, do: [nil | Crawler.known_chains()]

  def index(conn, params) do
    chain = parse_chain(params["chain"])
    q = params["q"] || ""
    ean = params["ean"] || ""
    sort = params["sort"] || "-last_priced_at"
    page = parse_int(params["page"], 1)
    per_page = parse_int(params["per_page"], 25)

    result =
      Catalog.list_listings_page(
        chain: chain,
        q: q,
        ean: ean,
        sort: sort,
        page: page,
        per_page: per_page
      )

    products_by_id =
      result.items
      |> Enum.map(& &1.id)
      |> Linker.products_by_listing_ids()

    linked_product_ids =
      products_by_id |> Map.values() |> Enum.map(& &1.id) |> Enum.uniq()

    eans_by_product_id = Catalog.eans_by_product_ids(linked_product_ids)
    chains_by_product_id = Linker.chains_by_product_ids(linked_product_ids)

    filters = %{
      chain: params["chain"] || "",
      q: q,
      ean: ean,
      per_page: params["per_page"] || ""
    }

    conn
    |> assign(:top_nav, :listings)
    |> assign(:active_chain, chain)
    |> assign(:result, result)
    |> assign(:products_by_id, products_by_id)
    |> assign(:eans_by_product_id, eans_by_product_id)
    |> assign(:chains_by_product_id, chains_by_product_id)
    |> assign(:filters, filters)
    |> assign(:sort, sort)
    |> assign(:page_title, "Listings")
    |> render(:index)
  end

  @doc """
  Picker page for `link_admin/2`. Shows the listing and a paginated
  product search; each result row has a button that POSTs back here
  to create the link.
  """
  def link_new(conn, %{"id" => id} = params) do
    listing = SuperBarato.Repo.get!(SuperBarato.Catalog.ChainListing, id)
    current_product = Linker.products_by_listing_ids([listing.id]) |> Map.get(listing.id)

    current_product_eans =
      if current_product, do: Catalog.eans_for_product(current_product.id), else: []

    current_product_listings =
      if current_product, do: Linker.listings_for_product(current_product.id), else: []

    # Default the search to the listing's brand so the picker isn't
    # empty on first render. Admin can override via the form.
    q = params["q"] || listing.brand || ""
    ean = params["ean"] || ""
    page = parse_int(params["page"], 1)

    result = Catalog.list_products_page(q: q, ean: ean, page: page, per_page: 25)

    result_product_ids = Enum.map(result.items, & &1.id)
    eans_by_product_id = Catalog.eans_by_product_ids(result_product_ids)
    chains_by_product_id = Linker.chains_by_product_ids(result_product_ids)

    conn
    |> assign(:top_nav, :listings)
    |> assign(:listing, listing)
    |> assign(:current_product, current_product)
    |> assign(:current_product_eans, current_product_eans)
    |> assign(:current_product_listings, current_product_listings)
    |> assign(:result, result)
    |> assign(:eans_by_product_id, eans_by_product_id)
    |> assign(:chains_by_product_id, chains_by_product_id)
    |> assign(:filters, %{q: q, ean: ean})
    |> assign(:page_title, "Link · #{listing.name}")
    |> render(:link_picker)
  end

  def link_create(conn, %{"id" => id, "product_id" => product_id}) do
    listing = SuperBarato.Repo.get!(SuperBarato.Catalog.ChainListing, id)
    product = SuperBarato.Repo.get!(SuperBarato.Catalog.Product, product_id)

    case Linker.link_admin(product.id, listing.id) do
      {:ok, _} ->
        conn
        |> put_flash(:info, "Linked “#{listing.name}” → “#{product.canonical_name}”.")
        |> redirect(to: ~p"/listings/#{listing.id}/link")

      {:error, cs} ->
        conn
        |> put_flash(:error, "Couldn't link: #{inspect(cs.errors)}")
        |> redirect(to: ~p"/listings/#{listing.id}/link")
    end
  end

  def link_delete(conn, %{"id" => id, "product_id" => product_id}) do
    case Linker.unlink(product_id, id) do
      :ok -> put_flash(conn, :info, "Unlinked.")
      :not_found -> put_flash(conn, :error, "No link found.")
    end
    |> redirect(to: ~p"/listings/#{id}/link")
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
