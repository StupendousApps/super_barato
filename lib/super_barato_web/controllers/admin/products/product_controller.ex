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
    {app_category, app_subcategory, uncategorized} = parse_taxonomy(params["taxonomy"])
    sort = params["sort"] || "-updated_at"
    page = parse_int(params["page"], 1)
    per_page = parse_int(params["per_page"], 25)

    result =
      Catalog.list_products_page(
        q: q,
        ean: ean,
        app_category: app_category,
        app_subcategory: app_subcategory,
        uncategorized: uncategorized,
        sort: sort,
        page: page,
        per_page: per_page
      )

    product_ids = Enum.map(result.items, & &1.id)

    listings_by_product_id = Linker.listings_by_product_ids(product_ids)
    eans_by_product_id = Catalog.eans_by_product_ids(product_ids)
    categories_by_product_id = Catalog.categories_by_product_ids(product_ids)

    filters = %{
      q: q,
      ean: ean,
      taxonomy: params["taxonomy"] || "",
      per_page: params["per_page"] || ""
    }

    conn
    |> assign(:top_nav, :products)
    |> assign(:result, result)
    |> assign(:listings_by_product_id, listings_by_product_id)
    |> assign(:eans_by_product_id, eans_by_product_id)
    |> assign(:categories_by_product_id, categories_by_product_id)
    |> assign(:taxonomy_options, taxonomy_options())
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
    category = Catalog.categories_by_product_ids([product.id]) |> Map.get(product.id)

    # Search params. The `mode` toggle picks listings vs products —
    # listings → admin-link to this product, products → merge them
    # into this product. Page only runs a search if the admin typed
    # something, so view-only loads stay fast.
    mode = if params["mode"] == "products", do: :products, else: :listings
    q = params["q"] || ""
    chain = parse_chain(params["chain"])
    ean = params["ean"] || ""
    page = parse_int(params["page"], 1)
    per_page = parse_int(params["per_page"], 50)

    search_active? = q != "" or ean != "" or chain != nil

    search_result =
      cond do
        not search_active? ->
          nil

        mode == :listings ->
          Catalog.list_listings_page(
            q: q,
            ean: ean,
            chain: chain,
            page: page,
            per_page: per_page
          )

        mode == :products ->
          result =
            Catalog.list_products_page(q: q, ean: ean, page: page, per_page: per_page)

          # Don't suggest merging the product into itself.
          %{result | items: Enum.reject(result.items, &(&1.id == product.id))}
      end

    # Per-mode lookups for rendering. Keep the map names mode-specific
    # so the template doesn't need branching for which one to read.
    {search_products_by_id, search_chains_by_product_id, search_eans_by_product_id,
     search_price_range_by_product_id} =
      cond do
        is_nil(search_result) ->
          {%{}, %{}, %{}, %{}}

        mode == :listings ->
          listing_ids = Enum.map(search_result.items, & &1.id)
          products = Linker.products_by_listing_ids(listing_ids)
          pids = products |> Map.values() |> Enum.map(& &1.id) |> Enum.uniq()
          {products, Linker.chains_by_product_ids(pids), %{}, %{}}

        mode == :products ->
          pids = Enum.map(search_result.items, & &1.id)

          {%{}, Linker.chains_by_product_ids(pids), Catalog.eans_by_product_ids(pids),
           Linker.price_range_by_product_ids(pids)}
      end

    conn
    |> assign(:top_nav, :products)
    |> assign(:product, product)
    |> assign(:listings, listings)
    |> assign(:linked_listing_ids, linked_listing_ids)
    |> assign(:sources, sources)
    |> assign(:eans, eans)
    |> assign(:category, category)
    |> assign(:search_mode, mode)
    |> assign(:search_active, search_active?)
    |> assign(:search_result, search_result)
    |> assign(:search_products_by_id, search_products_by_id)
    |> assign(:search_chains_by_product_id, search_chains_by_product_id)
    |> assign(:search_eans_by_product_id, search_eans_by_product_id)
    |> assign(:search_price_range_by_product_id, search_price_range_by_product_id)
    |> assign(:search_filters, %{
      q: q,
      ean: ean,
      chain: params["chain"] || "",
      mode: Atom.to_string(mode),
      per_page: params["per_page"] || ""
    })
    |> assign(:chains, [nil | Crawler.known_chains()])
    |> assign(:page_title, product.canonical_name)
    |> render(:show)
  end

  def edit(conn, %{"id" => id}) do
    product = SuperBarato.Repo.get!(SuperBarato.Catalog.Product, id)
    changeset = SuperBarato.Catalog.Product.changeset(product, %{})

    conn
    |> assign(:top_nav, :products)
    |> assign(:product, product)
    |> assign(:changeset, changeset)
    |> assign(:categories, Catalog.app_categories_with_subcategories())
    |> assign(:page_title, "Edit · #{product.canonical_name}")
    |> render(:edit)
  end

  def update(conn, %{"id" => id, "product" => attrs}) do
    product = SuperBarato.Repo.get!(SuperBarato.Catalog.Product, id)

    # Empty subcategory_id from the form clears the override.
    attrs =
      case Map.get(attrs, "app_subcategory_id") do
        "" -> Map.put(attrs, "app_subcategory_id", nil)
        _ -> attrs
      end

    changeset = SuperBarato.Catalog.Product.changeset(product, attrs)

    case SuperBarato.Repo.update(changeset) do
      {:ok, _product} ->
        conn
        |> put_flash(:info, "Updated.")
        |> redirect(to: ~p"/products/#{id}")

      {:error, changeset} ->
        conn
        |> assign(:top_nav, :products)
        |> assign(:product, product)
        |> assign(:changeset, changeset)
        |> assign(:categories, Catalog.app_categories_with_subcategories())
        |> assign(:page_title, "Edit · #{product.canonical_name}")
        |> render(:edit)
    end
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

  # Single flat option list for the combined category/subcategory
  # dropdown. Each AppCategory becomes a selectable header (value
  # `c:<slug>`) and each AppSubcategory beneath it becomes a
  # subordinate row (value `s:<slug>`, indented label) — picking the
  # header filters by category, picking a child filters by
  # subcategory. parse_taxonomy/1 inverts this back into the
  # (category_slug, subcategory_slug) pair the Catalog expects.
  defp taxonomy_options do
    import Ecto.Query

    cats =
      SuperBarato.Repo.all(
        from c in SuperBarato.Catalog.AppCategory,
          order_by: [asc: c.position, asc: c.name],
          preload: [
            subcategories:
              ^from(s in SuperBarato.Catalog.AppSubcategory,
                order_by: [asc: s.position, asc: s.name]
              )
          ],
          select: c
      )

    rows =
      Enum.flat_map(cats, fn cat ->
        [{cat.name, "c:" <> cat.slug}] ++
          Enum.map(cat.subcategories, fn sub ->
            # Indent with a real non-breaking space — most browsers
            # collapse leading whitespace inside <option>.
            {"   " <> sub.name, "s:" <> sub.slug}
          end)
      end)

    [{"All", ""}, {"Uncategorized", "none"} | rows]
  end

  # Translate the combined dropdown's value back into a
  # (category, subcategory, uncategorized?) tuple. Unknown / empty
  # inputs collapse to {"", "", false} which
  # `Catalog.list_products_page/1` treats as no filter.
  defp parse_taxonomy(nil), do: {"", "", false}
  defp parse_taxonomy(""), do: {"", "", false}
  defp parse_taxonomy("none"), do: {"", "", true}
  defp parse_taxonomy("c:" <> slug), do: {slug, "", false}
  defp parse_taxonomy("s:" <> slug), do: {"", slug, false}
  defp parse_taxonomy(_), do: {"", "", false}

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
