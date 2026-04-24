defmodule SuperBarato.Crawler.Tottus do
  @moduledoc """
  Tottus adapter — Falabella-group supermarket, Next.js SSR. All three
  stages pull `<script id="__NEXT_DATA__">` out of a category / PDP
  page and navigate the JSON tree (same approach as Lider).

  URL shapes:
    * `/tottus-cl/lista/<CATID>/<slug>` — category listing. `?page=N`
      paginates (48 per page). Sub-categories appear in the response's
      `facets` array under the "Categoría" facet.
    * `/tottus-cl/articulo/<productId>/<slug>` — product detail page.

  Tottus doesn't expose EAN/barcode, so refreshes key on `chain_sku`
  (the numeric product id). Slug format is `"<CATID>/<url-segment>"`
  so the URL can be reconstructed without extra state.
  """

  @behaviour SuperBarato.Crawler.Chain

  alias SuperBarato.Crawler.{Category, Http, Listing, Session}

  require Logger

  @chain :tottus
  @site_url "https://www.tottus.cl"
  @default_profile :chrome116
  @page_size 48

  # Root category — the supermarket itself. Its "Categoría" facet
  # lists the 25 top-level departments (Despensa, Carnes, ...).
  @root_slug "CATG27054/Tottus"

  @user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36"

  @browser_headers [
    {"user-agent", @user_agent},
    {"accept",
     "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8"},
    {"accept-language", "es-CL,es;q=0.9,en;q=0.8"},
    {"accept-encoding", "gzip, deflate, br"},
    {"sec-ch-ua", ~s("Chromium";v="116", "Not;A=Brand";v="24", "Google Chrome";v="116")},
    {"sec-ch-ua-mobile", "?0"},
    {"sec-ch-ua-platform", ~s("macOS")},
    {"sec-fetch-dest", "document"},
    {"sec-fetch-mode", "navigate"},
    {"sec-fetch-site", "none"},
    {"sec-fetch-user", "?1"},
    {"upgrade-insecure-requests", "1"}
  ]

  @impl true
  def id, do: @chain

  @impl true
  def refresh_identifier, do: :chain_sku

  @impl true
  def handle_task({:discover_categories, %{parent: _}}), do: discover_categories()

  def handle_task({:discover_products, %{slug: slug}}), do: discover_products(slug)

  def handle_task({:fetch_product_info, %{identifiers: ids}}),
    do: fetch_product_info(ids)

  def handle_task(other), do: {:error, {:unsupported_task, other}}

  # Stage 1 — category tree

  defp discover_categories do
    # Walk the tree breadth-first from the root. Each category page
    # gives us the direct children via the "Categoría" facet.
    walk_tree([%{slug: @root_slug, name: "Tottus", parent_slug: nil, level: 0}], [])
  end

  defp walk_tree([], acc), do: {:ok, acc |> Enum.reverse() |> mark_leaves()}

  defp walk_tree([%{slug: slug, name: name, parent_slug: parent, level: level} | rest], acc) do
    with {:ok, html} <- fetch_html(category_url(slug, nil)),
         {:ok, data} <- extract_next_data(html),
         {:ok, children} <- children_from_next_data(data, slug, level + 1) do
      entry =
        if level == 0 do
          # Don't include the synthetic root in the output.
          []
        else
          [
            %Category{
              chain: @chain,
              slug: slug,
              name: name,
              parent_slug: parent,
              level: level,
              external_id: category_id(slug)
            }
          ]
        end

      walk_tree(rest ++ children, entry ++ acc)
    else
      :blocked ->
        :blocked

      {:error, reason} ->
        Logger.warning("[tottus] discover_categories failed at #{slug}: #{inspect(reason)}")
        # Skip this branch; keep what we have.
        walk_tree(rest, acc)
    end
  end

  @doc false
  def children_from_next_data(data, parent_slug, next_level) do
    facet =
      data
      |> get_in(["props", "pageProps", "facets"])
      |> List.wrap()
      |> Enum.find(&category_facet?/1)

    values = (facet && facet["values"]) || []

    children =
      Enum.flat_map(values, fn v ->
        case {v["id"], v["title"]} do
          {id, title} when is_binary(id) and is_binary(title) ->
            [
              %{
                slug: "#{id}/#{url_segment(title)}",
                name: title,
                parent_slug: parent_slug,
                level: next_level
              }
            ]

          _ ->
            []
        end
      end)

    {:ok, children}
  end

  defp category_facet?(%{"name" => name}) when is_binary(name),
    do: String.downcase(name) in ["categoría", "categoria"]

  defp category_facet?(_), do: false

  # Stage 2 — products in a leaf category

  defp discover_products(slug) when is_binary(slug) do
    list_pages(slug, 1, [], nil)
  end

  defp list_pages(slug, page, acc, total) do
    url = category_url(slug, page)

    with {:ok, html} <- fetch_html(url),
         {:ok, data} <- extract_next_data(html) do
      {:ok, listings, resp_total} = parse_search_from_next_data(data, slug)
      new_total = total || resp_total
      new_acc = acc ++ listings

      cond do
        length(listings) == 0 -> {:ok, new_acc}
        length(listings) < @page_size -> {:ok, new_acc}
        is_integer(new_total) and page * @page_size >= new_total -> {:ok, new_acc}
        true -> list_pages(slug, page + 1, new_acc, new_total)
      end
    end
  end

  @doc false
  def parse_search_from_next_data(data, category_slug) do
    pp = get_in(data, ["props", "pageProps"]) || %{}
    results = pp["results"] || []
    total = get_in(pp, ["pagination", "count"])

    listings =
      results
      |> Enum.map(&parse_search_item(&1, category_slug))
      |> Enum.reject(&is_nil/1)

    {:ok, listings, total}
  end

  defp parse_search_item(%{"productId" => id} = item, category_slug)
       when is_binary(id) and id != "" do
    {regular, promo} = parse_prices(item["prices"] || [])

    %Listing{
      chain: @chain,
      chain_sku: id,
      chain_product_id: to_string_if_present(item["skuId"]),
      ean: nil,
      name: item["displayName"],
      brand: item["brand"],
      image_url: first_media(item["mediaUrls"]),
      pdp_url: item["url"],
      category_path: category_slug,
      regular_price: regular,
      promo_price: promo,
      promotions: %{}
    }
  end

  defp parse_search_item(_, _), do: nil

  # Stage 3 — single-SKU refresh

  defp fetch_product_info(identifiers) when is_list(identifiers) do
    identifiers
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case fetch_single(id) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, listing} -> {:cont, {:ok, [listing | acc]}}
        :blocked -> {:halt, :blocked}
        {:error, reason} ->
          Logger.warning("[tottus] pdp fetch failed for #{id}: #{inspect(reason)}")
          {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, listings} -> {:ok, Enum.reverse(listings)}
      other -> other
    end
  end

  defp fetch_single(product_id) do
    # Tottus's product route is `/tottus-cl/articulo/<id>/<slug>`, but
    # it normalises the slug — any placeholder works.
    url = "#{@site_url}/tottus-cl/articulo/#{product_id}/x"

    with {:ok, html} <- fetch_html(url),
         {:ok, data} <- extract_next_data(html),
         {:ok, listing} <- parse_pdp_from_next_data(data) do
      {:ok, listing}
    end
  end

  @doc false
  def parse_pdp_from_next_data(data) do
    pd = get_in(data, ["props", "pageProps", "productData"])

    case pd do
      nil ->
        {:ok, nil}

      %{} ->
        variant = List.first(pd["variants"] || []) || %{}
        {regular, promo} = parse_prices(variant["prices"] || [])

        listing = %Listing{
          chain: @chain,
          chain_sku: to_string_if_present(pd["id"]),
          chain_product_id: to_string_if_present(pd["primaryVariantId"]),
          ean: nil,
          name: pd["name"],
          brand: pd["brandName"],
          image_url: first_media_url(pd["medias"]),
          pdp_url: pdp_url(pd),
          category_path: breadcrumb_slug(pd["breadCrumb"]),
          regular_price: regular,
          promo_price: promo,
          promotions: %{}
        }

        {:ok, listing}
    end
  end

  defp pdp_url(%{"id" => id, "slug" => slug}) when is_binary(id) and is_binary(slug),
    do: "#{@site_url}/tottus-cl/articulo/#{id}/#{slug}"

  defp pdp_url(%{"id" => id}) when is_binary(id),
    do: "#{@site_url}/tottus-cl/articulo/#{id}/x"

  defp pdp_url(_), do: nil

  # PDP breadCrumb entries are listed deepest-first (leaf → root), so
  # reverse them to rebuild a root-to-leaf path matching stage 2.
  defp breadcrumb_slug(path) when is_list(path) and path != [] do
    path
    |> Enum.reverse()
    |> Enum.map(fn %{"id" => id, "label" => label} -> "#{id}/#{url_segment(label)}" end)
    |> List.last()
  end

  defp breadcrumb_slug(_), do: nil

  # Helpers

  defp category_url(slug, nil), do: "#{@site_url}/tottus-cl/lista/#{slug}"
  defp category_url(slug, page), do: "#{@site_url}/tottus-cl/lista/#{slug}?page=#{page}"

  defp category_id(slug) do
    slug |> String.split("/") |> List.first()
  end

  # Turns "Carnes y Liquidos" into "Carnes-y-Liquidos" (Tottus's URL
  # segment style). Good enough for URL reconstruction — the site
  # normalises these anyway.
  defp url_segment(s) do
    s
    |> String.replace(" ", "-")
    |> String.replace(~r/[^A-Za-zÁÉÍÓÚáéíóúÑñ0-9\-]/u, "")
  end

  defp mark_leaves(cats) do
    parents = cats |> Enum.map(& &1.parent_slug) |> Enum.reject(&is_nil/1) |> MapSet.new()
    Enum.map(cats, &%{&1 | is_leaf: not MapSet.member?(parents, &1.slug)})
  end

  defp first_media([url | _]) when is_binary(url), do: url
  defp first_media(_), do: nil

  defp first_media_url([%{"url" => url} | _]) when is_binary(url), do: url
  defp first_media_url(_), do: nil

  # Price parsing: Tottus returns up to three tiered prices:
  #   * normalPrice   — list (MSRP-ish). Can be crossed-out (was).
  #   * internetPrice — online price. Promo when normalPrice is struck.
  #   * cmrPrice      — loyalty-card price. Ignored.
  @doc false
  def parse_prices(prices) when is_list(prices) do
    by_type =
      Enum.reduce(prices, %{}, fn p, acc -> Map.put(acc, p["type"], p) end)

    normal = by_type["normalPrice"]
    internet = by_type["internetPrice"]

    cond do
      # normalPrice struck through + active internetPrice = promo shape
      normal && normal["crossed"] && internet && !internet["crossed"] ->
        {price_int(normal), price_int(internet)}

      internet && !internet["crossed"] ->
        {price_int(internet), nil}

      normal && !normal["crossed"] ->
        {price_int(normal), nil}

      true ->
        {nil, nil}
    end
  end

  def parse_prices(_), do: {nil, nil}

  defp price_int(%{"price" => [s | _]}) when is_binary(s), do: price_int_from_str(s)
  defp price_int(_), do: nil

  defp price_int_from_str(s) do
    case Integer.parse(String.replace(s, ~r/[^\d]/, "")) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp to_string_if_present(nil), do: nil
  defp to_string_if_present(v), do: to_string(v)

  # HTTP

  defp fetch_html(url) do
    profile = Session.get(@chain, :profile) || @default_profile

    case Http.get(url, headers: @browser_headers, profile: profile) do
      {:ok, %Http.Response{} = resp} ->
        cond do
          Http.blocked?(resp) -> :blocked
          resp.status == 200 -> {:ok, resp.body}
          true -> {:error, {:http_status, resp.status}}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc false
  def extract_next_data(html) when is_binary(html) do
    case Regex.run(
           ~r/<script[^>]*id="__NEXT_DATA__"[^>]*>(.*?)<\/script>/s,
           html
         ) do
      [_, json] -> Jason.decode(json)
      _ -> {:error, :no_next_data}
    end
  end
end
