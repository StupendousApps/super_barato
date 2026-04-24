defmodule SuperBarato.Crawler.Lider do
  @moduledoc """
  Lider adapter — Walmart Chile's supermarket, Next.js SSR + Akamai.

  All three stages work by fetching HTML pages and pulling
  `<script id="__NEXT_DATA__">` out of them, then navigating the JSON
  tree. Lider's Akamai blocks Chrome 110+ and all Firefox/Safari, but
  lets older Chrome profiles (99–107) through — so this chain pins
  `profile: :chrome107` in its config.

    * Stage 1: homepage — `pageProps.bootstrapData.header.data
      .contentLayout.modules[GlobalHeaderMenu].configs.departments`
      exposes the full mega-menu (25 top-levels, ~1200 subs).
    * Stage 2: `/browse/<slug>/<id-chain>?page=N` — products at
      `pageProps.initialData.searchResult.itemStacks[0].items`, total
      at `searchResult.aggregatedCount`.
    * Stage 3: `/ip/_/_/<usItemId>` — Lider redirects to the canonical
      PDP URL regardless of the other path segments, so the
      placeholders work. Full product at
      `pageProps.initialData.data.product`.

  Lider's `usItemId` is a 14-digit GTIN (leading zeros on a 13-digit
  EAN-13). We store it as `chain_sku` and key refreshes on it.
  """

  @behaviour SuperBarato.Crawler.Chain

  alias SuperBarato.Crawler.{Category, Http, Listing, Session}

  require Logger

  @chain :lider
  @site_url "https://www.lider.cl"
  @default_profile :chrome107
  @page_size 46

  @user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36"

  @browser_headers [
    {"user-agent", @user_agent},
    {"accept",
     "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8"},
    {"accept-language", "es-CL,es;q=0.9,en;q=0.8"},
    {"accept-encoding", "gzip, deflate, br"},
    {"sec-ch-ua", ~s("Chromium";v="107", "Not;A=Brand";v="24", "Google Chrome";v="107")},
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

  # Stage 1

  defp discover_categories do
    with {:ok, html} <- fetch_html(@site_url <> "/"),
         {:ok, data} <- extract_next_data(html),
         {:ok, cats} <- parse_categories_from_next_data(data) do
      {:ok, cats}
    end
  end

  @doc false
  def parse_categories_from_next_data(data) do
    departments =
      get_in(data, [
        "props",
        "pageProps",
        "bootstrapData",
        "header",
        "data",
        "contentLayout",
        "modules"
      ])
      |> List.wrap()
      |> Enum.find(&(&1["type"] == "GlobalHeaderMenu"))
      |> case do
        nil -> nil
        mod -> get_in(mod, ["configs", "departments"])
      end

    case departments do
      list when is_list(list) ->
        {:ok, extract_categories(list) |> mark_leaves()}

      _ ->
        {:error, :no_nav_module}
    end
  end

  defp extract_categories(departments) do
    Enum.flat_map(departments, fn dep ->
      case build_category(dep["name"], cta_url(dep["cta"]), nil, 1) do
        nil ->
          []

        top ->
          subs =
            for group <- dep["subCategoryGroup"] || [],
                linksgroup <- group["subCategoryLinksGroup"] || [],
                link = linksgroup["subCategoryLink"],
                cat = build_category(link["title"], cta_url(link["clickThrough"]), top.slug, 2),
                !is_nil(cat),
                do: cat

          [top | subs]
      end
    end)
  end

  defp cta_url(%{"clickThrough" => %{"value" => v}}) when is_binary(v), do: v
  defp cta_url(%{"value" => v}) when is_binary(v), do: v
  defp cta_url(_), do: nil

  defp build_category(_, nil, _, _), do: nil

  defp build_category(name, url, parent_slug, level) when is_binary(url) do
    case url_to_slug(url) do
      nil ->
        nil

      slug ->
        %Category{
          chain: @chain,
          slug: slug,
          name: name,
          parent_slug: parent_slug,
          level: level,
          external_id: extract_id(slug)
        }
    end
  end

  # Lider URLs come in two shapes:
  #   /browse/<path>/<id-chain>  — leaf-category listings (used by stage 2)
  #   /content/<slug>/<id>       — department landing pages
  # Top-level departments mostly use /content/; their sub-categories
  # use /browse/. Accept both so the tree is complete; ProductProducer
  # only crawls leaves anyway, and leaves are always /browse/*.
  defp url_to_slug("/browse/" <> rest), do: rest |> String.split("?") |> List.first()
  defp url_to_slug("/content/" <> rest), do: rest |> String.split("?") |> List.first()
  defp url_to_slug(_), do: nil

  defp extract_id(slug) do
    slug
    |> String.split("/")
    |> List.last()
    |> String.split("_")
    |> List.last()
  end

  defp mark_leaves(cats) do
    parents = cats |> Enum.map(& &1.parent_slug) |> Enum.reject(&is_nil/1) |> MapSet.new()
    Enum.map(cats, &%{&1 | is_leaf: not MapSet.member?(parents, &1.slug)})
  end

  # Stage 2

  defp discover_products(slug) when is_binary(slug) do
    list_pages(slug, 1, [], nil)
  end

  defp list_pages(slug, page, acc, total) do
    url = "#{@site_url}/browse/#{slug}?page=#{page}"

    with {:ok, html} <- fetch_html(url),
         {:ok, data} <- extract_next_data(html) do
      case parse_search_from_next_data(data, slug) do
        {:ok, listings, resp_total} ->
          new_total = total || resp_total
          new_acc = acc ++ listings

          cond do
            length(listings) == 0 -> {:ok, new_acc}
            length(listings) < @page_size -> {:ok, new_acc}
            is_integer(new_total) and page * @page_size >= new_total -> {:ok, new_acc}
            true -> list_pages(slug, page + 1, new_acc, new_total)
          end

        {:error, _} = err ->
          err
      end
    end
  end

  @doc false
  def parse_search_from_next_data(data, category_slug) do
    sr = get_in(data, ["props", "pageProps", "initialData", "searchResult"])

    case sr do
      nil ->
        {:error, :no_search_result}

      %{} ->
        items = get_in(sr, ["itemStacks", Access.at(0), "items"]) || []
        total = sr["aggregatedCount"]

        listings =
          items
          |> Enum.map(&parse_search_item(&1, category_slug))
          |> Enum.reject(&is_nil/1)

        {:ok, listings, total}
    end
  end

  defp parse_search_item(%{"usItemId" => usItemId} = item, category_slug)
       when is_binary(usItemId) and usItemId != "" do
    price_info = item["priceInfo"] || %{}
    image_info = item["imageInfo"] || %{}

    {regular, promo} = parse_search_prices(price_info)

    %Listing{
      chain: @chain,
      chain_sku: usItemId,
      chain_product_id: to_string_if_present(item["id"]),
      ean: ean_from_upc(item["upc"] || usItemId),
      name: item["name"],
      brand: item["brand"],
      image_url: image_info["thumbnailUrl"],
      pdp_url: item["canonicalUrl"] && @site_url <> item["canonicalUrl"],
      category_path: category_slug,
      regular_price: regular,
      promo_price: promo,
      promotions: %{}
    }
  end

  # Sponsored cards, banners, and other non-product items in itemStacks
  # don't have a `usItemId` — drop them.
  defp parse_search_item(_, _), do: nil

  # Search-result priceInfo is a flatter, string-formatted shape
  # ("$22.200") than the PDP's structured one. Parse both.
  defp parse_search_prices(%{"currentPrice" => %{"price" => n}} = pi)
       when is_integer(n) and n > 0 do
    was = price_int(get_in(pi, ["wasPrice", "price"]))
    decide_prices(was || n, n)
  end

  defp parse_search_prices(%{"linePrice" => s} = pi) when is_binary(s) and s != "" do
    current = price_int(s)
    was = price_int(pi["wasPrice"])
    decide_prices(was || current, current)
  end

  defp parse_search_prices(_), do: {nil, nil}

  # Stage 3

  defp fetch_product_info(identifiers) when is_list(identifiers) do
    # One request per identifier. Lider has no batched lookup; stage 2
    # re-runs are cheaper for bulk refreshes. Worker's rate limiter
    # paces these, so 50k ids / 1 rps = ~14h full refresh.
    identifiers
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case fetch_single(id) do
        {:ok, nil} ->
          {:cont, {:ok, acc}}

        {:ok, listing} ->
          {:cont, {:ok, [listing | acc]}}

        :blocked ->
          {:halt, :blocked}

        {:error, reason} ->
          Logger.warning("[lider] pdp fetch failed for #{id}: #{inspect(reason)}")
          {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, listings} -> {:ok, Enum.reverse(listings)}
      other -> other
    end
  end

  defp fetch_single(usItemId) do
    # Lider accepts /ip/<anything>/<anything>/<usItemId> and redirects
    # to the canonical URL; we use placeholders.
    url = "#{@site_url}/ip/p/p/#{usItemId}"

    with {:ok, html} <- fetch_html(url),
         {:ok, data} <- extract_next_data(html),
         {:ok, listing} <- parse_pdp_from_next_data(data) do
      {:ok, listing}
    end
  end

  @doc false
  def parse_pdp_from_next_data(data) do
    product = get_in(data, ["props", "pageProps", "initialData", "data", "product"])

    case product do
      nil ->
        {:ok, nil}

      %{} ->
        pi = product["priceInfo"] || %{}
        current = price_int(get_in(pi, ["currentPrice", "price"]))
        was = price_int(get_in(pi, ["wasPrice", "price"]))
        {regular, promo} = decide_prices(was || current, current)

        imgs = product["imageInfo"] || %{}

        listing = %Listing{
          chain: @chain,
          chain_sku: to_string_if_present(product["usItemId"]),
          chain_product_id: to_string_if_present(product["id"]),
          ean: ean_from_upc(product["upc"] || product["usItemId"]),
          name: product["name"],
          brand: product["brand"],
          image_url: imgs["thumbnailUrl"],
          pdp_url: @site_url <> "/ip/p/p/#{product["usItemId"]}",
          category_path: category_slug_from_path(product["category"]),
          regular_price: regular,
          promo_price: promo,
          promotions: %{}
        }

        {:ok, listing}
    end
  end

  # Lider's PDP exposes `category.path` as a breadcrumb list of
  # {name, url}. The last entry's url is the leaf-category URL; we
  # pull the slug out of it to match the shape stage 2 stores.
  defp category_slug_from_path(%{"path" => path}) when is_list(path) do
    case List.last(path) do
      %{"url" => url} -> url_to_slug(url)
      _ -> nil
    end
  end

  defp category_slug_from_path(_), do: nil

  # HTTP helpers

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

  # Parsing helpers

  defp ean_from_upc(nil), do: nil
  defp ean_from_upc(""), do: nil

  defp ean_from_upc(upc) when is_binary(upc) do
    # Strip leading zeros on GTIN-14 to get EAN-13 (or less, on EAN-8
    # padded to 14). Minimum 8 digits — shorter means non-EAN.
    trimmed = String.trim_leading(upc, "0")
    if String.length(trimmed) >= 8, do: trimmed, else: nil
  end

  defp ean_from_upc(_), do: nil

  defp decide_prices(regular, current) do
    cond do
      is_integer(regular) and is_integer(current) and current < regular -> {regular, current}
      is_integer(regular) -> {regular, nil}
      is_integer(current) -> {current, nil}
      true -> {nil, nil}
    end
  end

  defp price_int(nil), do: nil
  defp price_int(n) when is_integer(n) and n > 0, do: n
  defp price_int(n) when is_integer(n), do: nil
  defp price_int(n) when is_float(n), do: trunc(n)

  defp price_int(s) when is_binary(s) do
    case Integer.parse(String.replace(s, ~r/[^\d]/, "")) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp price_int(_), do: nil

  defp to_string_if_present(nil), do: nil
  defp to_string_if_present(v), do: to_string(v)
end
