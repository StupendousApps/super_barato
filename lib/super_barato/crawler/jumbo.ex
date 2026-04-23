defmodule SuperBarato.Crawler.Jumbo do
  @moduledoc """
  Jumbo adapter backed by the Cencosud supermarket BFF at
  `https://sm-web-api.ecomm.cencosud.com/catalog/api`. Three stages:

    * Categories: static JSON tree at `assets.jumbo.cl/json/categories.json`
      (27 top-level, ~790 nodes, 3 levels).
    * Products: paginated `/v2/products/search/<slug>?page=N&sc=1`,
      40 items per page. Total count comes from the `resources` response
      header (`0-39/664`).
    * Product info: batched `/v1/products/skus?skuIds=<csv>&sc=1`. Jumbo
      keys on its VTEX `itemId` (our `chain_sku`), not EAN — EAN is in the
      response but not accepted as input.

  All calls require `apiKey: <key>` from the public JS bundle. Sales
  channel is numeric (`1`), not the `jumboclj512` seller id used for
  whitelabel flows.
  """

  @behaviour SuperBarato.Crawler.Chain

  alias SuperBarato.Crawler.{Category, Http, Listing, RateLimiter}

  require Logger

  @chain :jumbo
  @site_url "https://www.jumbo.cl"
  @catalog_api "https://sm-web-api.ecomm.cencosud.com/catalog/api"
  @categories_json "https://assets.jumbo.cl/json/categories.json"
  @api_key "WlVnnB7c1BblmgUPOfg"
  @sales_channel "1"
  @page_size 40
  @sku_batch_size 50

  @user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

  @api_headers [
    {"user-agent", @user_agent},
    {"accept", "application/json, text/plain, */*"},
    {"accept-language", "es-CL,es;q=0.9,en;q=0.8"},
    {"accept-encoding", "gzip, deflate, br, zstd"},
    {"apiKey", @api_key},
    {"origin", @site_url},
    {"referer", @site_url <> "/"},
    {"sec-ch-ua", ~s("Chromium";v="131", "Not_A Brand";v="24", "Google Chrome";v="131")},
    {"sec-ch-ua-mobile", "?0"},
    {"sec-ch-ua-platform", ~s("macOS")},
    {"sec-fetch-dest", "empty"},
    {"sec-fetch-mode", "cors"},
    {"sec-fetch-site", "cross-site"}
  ]

  @impl true
  def id, do: @chain

  @impl true
  def refresh_identifier, do: :chain_sku

  # Stage 1: categories

  @impl true
  def discover_categories do
    case get_json(@categories_json, :high) do
      {:ok, tree} when is_list(tree) ->
        cats = flatten_tree(tree)
        {:ok, mark_leaves(cats)}

      {:ok, _other} ->
        {:error, :malformed_category_tree}

      {:error, _} = err ->
        err
    end
  end

  defp flatten_tree(nodes, parent_slug \\ nil, level \\ 1) do
    Enum.flat_map(nodes, fn node ->
      slug = slug_from_url(node["url"])

      cat = %Category{
        chain: @chain,
        slug: slug,
        name: node["name"],
        external_id: to_string_if_present(node["id"]),
        parent_slug: parent_slug,
        level: level
      }

      children = List.wrap(node["children"])
      [cat | flatten_tree(children, slug, level + 1)]
    end)
  end

  defp slug_from_url(url) when is_binary(url) do
    # "https://jumbo.myvtex.com/lacteos-y-quesos/leches/leche-en-polvo"
    # → "lacteos-y-quesos/leches/leche-en-polvo"
    case URI.parse(url) do
      %URI{path: nil} -> ""
      %URI{path: path} -> String.trim_leading(path, "/")
    end
  end

  defp slug_from_url(_), do: ""

  defp mark_leaves(categories) do
    parent_slugs =
      categories
      |> Enum.map(& &1.parent_slug)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.map(categories, fn c ->
      %{c | is_leaf: not MapSet.member?(parent_slugs, c.slug)}
    end)
  end

  # Stage 2: products by category

  @impl true
  def discover_products(slug) when is_binary(slug) do
    list_all_pages(slug, 1, [], nil)
  end

  defp list_all_pages(slug, page, acc, total) do
    path = "/v2/products/search/#{encode_slug(slug)}?ft=&page=#{page}&sc=#{@sales_channel}"
    url = @catalog_api <> path

    case get_with_headers(url, :high) do
      {:ok, %Http.Response{status: 200, headers: hdrs, body: body}} ->
        case Jason.decode(body) do
          {:ok, products} when is_list(products) ->
            listings = Enum.map(products, &parse_listing(&1, slug))
            new_total = total || parse_resources_total(hdrs)
            new_acc = acc ++ listings

            cond do
              products == [] -> {:ok, new_acc}
              length(products) < @page_size -> {:ok, new_acc}
              is_integer(new_total) and page * @page_size >= new_total -> {:ok, new_acc}
              true -> list_all_pages(slug, page + 1, new_acc, new_total)
            end

          {:ok, _} ->
            {:ok, acc}

          {:error, _} = err ->
            err
        end

      {:ok, %Http.Response{status: s, body: b}} ->
        {:error, {:http_status, s, String.slice(b, 0, 200)}}

      {:error, _} = err ->
        err
    end
  end

  defp encode_slug(slug) do
    slug
    |> String.split("/", trim: true)
    |> Enum.map_join("/", &URI.encode_www_form/1)
  end

  defp parse_resources_total(headers) do
    case Enum.find_value(headers, fn {k, v} -> if k == "resources", do: v end) do
      nil ->
        nil

      s ->
        case Regex.run(~r{/(\d+)$}, s) do
          [_, n] -> String.to_integer(n)
          _ -> nil
        end
    end
  end

  # Stage 3: product info by chain_sku (VTEX itemId)

  @impl true
  def fetch_product_info(chain_skus) when is_list(chain_skus) do
    chain_skus
    |> Enum.chunk_every(@sku_batch_size)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      csv = Enum.join(batch, ",")

      url =
        "#{@catalog_api}/v1/products/skus?skuIds=#{URI.encode_www_form(csv)}&sc=#{@sales_channel}"

      case get_json(url, :normal) do
        {:ok, products} when is_list(products) ->
          listings = Enum.map(products, &parse_listing(&1, nil))
          {:cont, {:ok, acc ++ listings}}

        {:ok, _} ->
          {:cont, {:ok, acc}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  # Shared parser — stage 2 and stage 3 both return VTEX's classic
  # `[{productId, productName, brand, items: [{itemId, ean, sellers: [{commertialOffer: {...}}]}]}]`.
  defp parse_listing(%{} = product, category_slug) do
    item = first_item(product)
    offer = commercial_offer(item)
    {regular, promo} = prices_from_offer(offer)

    %Listing{
      chain: @chain,
      chain_sku: to_string_if_present(item["itemId"]),
      chain_product_id: to_string_if_present(product["productId"]),
      ean: blank_to_nil(item["ean"]),
      name: product["productName"] || item["name"],
      brand: product["brand"],
      image_url: first_image_url(item),
      pdp_url: pdp_url_from(product),
      category_path: category_slug,
      regular_price: regular,
      promo_price: promo,
      promotions: %{}
    }
  end

  # HTTP helpers

  defp get_json(url, priority) do
    case get_with_headers(url, priority) do
      {:ok, %Http.Response{status: 200, body: body}} ->
        Jason.decode(body)

      {:ok, %Http.Response{status: s, body: b}} ->
        {:error, {:http_status, s, String.slice(b, 0, 200)}}

      {:error, _} = err ->
        err
    end
  end

  defp get_with_headers(url, priority) do
    RateLimiter.request(@chain, priority, fn ->
      Http.get(url, headers: @api_headers)
    end)
  end

  # Parsing helpers

  defp first_item(%{"items" => [item | _]}) when is_map(item), do: item
  defp first_item(_), do: %{}

  defp commercial_offer(%{"sellers" => [%{"commertialOffer" => off} | _]}) when is_map(off),
    do: off

  defp commercial_offer(_), do: %{}

  defp prices_from_offer(offer) do
    list = price_int(offer["ListPrice"]) || price_int(offer["PriceWithoutDiscount"])
    price = price_int(offer["Price"])

    cond do
      is_integer(list) and is_integer(price) and price < list -> {list, price}
      is_integer(list) -> {list, nil}
      is_integer(price) -> {price, nil}
      true -> {nil, nil}
    end
  end

  defp first_image_url(%{"images" => [%{"imageUrl" => url} | _]}) when is_binary(url), do: url
  defp first_image_url(_), do: nil

  defp pdp_url_from(%{"linkText" => lt}) when is_binary(lt) and lt != "",
    do: @site_url <> "/" <> lt <> "/p"

  defp pdp_url_from(%{"link" => link}) when is_binary(link) and link != "",
    do: @site_url <> link

  defp pdp_url_from(_), do: nil

  defp price_int(nil), do: nil
  defp price_int(n) when is_integer(n) and n > 0, do: n
  defp price_int(n) when is_integer(n), do: nil
  defp price_int(n) when is_float(n), do: trunc(n)
  defp price_int(_), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s

  defp to_string_if_present(nil), do: nil
  defp to_string_if_present(v), do: to_string(v)
end
