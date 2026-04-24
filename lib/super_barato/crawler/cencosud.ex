defmodule SuperBarato.Crawler.Cencosud do
  @moduledoc """
  Shared implementation for Cencosud-owned supermarket chains.

  Cencosud runs one BFF (`sm-web-api.ecomm.cencosud.com/catalog/api`)
  with one shared catalog apiKey; chains like Jumbo and Santa Isabel
  differ only in:

    * the per-chain `categories.json` URL hosted on `assets.jumbo.cl`;
    * the numeric sales channel (`sc=1` for Jumbo, `sc=6` for Santa
      Isabel);
    * the front-end `site_url` used for the `origin`/`referer` headers
      and building PDP URLs from product `linkText`.

  Adapter modules construct a `%Config{}` and delegate each `Chain`
  callback to the functions here. Rate-limiter + HTTP transport are
  still per-chain — the adapter passes its atom into `RateLimiter` so
  politeness is enforced at the chain level.
  """

  alias SuperBarato.Crawler.{Category, Http, Listing, Session}

  @catalog_api "https://sm-web-api.ecomm.cencosud.com/catalog/api"
  @api_key "WlVnnB7c1BblmgUPOfg"
  @page_size 40
  @sku_batch_size 50

  @user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

  defmodule Config do
    @moduledoc "Per-chain configuration for the shared Cencosud adapter."

    @enforce_keys [:chain, :site_url, :categories_url, :sales_channel]
    defstruct [:chain, :site_url, :categories_url, :sales_channel, profile: nil]

    @type t :: %__MODULE__{
            chain: atom(),
            site_url: String.t(),
            categories_url: String.t(),
            sales_channel: String.t(),
            profile: atom() | nil
          }
  end

  # Stage 1: categories

  @spec discover_categories(Config.t()) :: {:ok, [Category.t()]} | :blocked | {:error, term()}
  def discover_categories(%Config{} = cfg) do
    case get_json(cfg, cfg.categories_url, :high) do
      {:ok, tree} when is_list(tree) ->
        {:ok, parse_categories(cfg.chain, tree)}

      {:ok, _other} ->
        {:error, :malformed_category_tree}

      :blocked ->
        :blocked

      {:error, _} = err ->
        err
    end
  end

  @doc false
  def parse_categories(chain, tree) when is_list(tree) do
    chain
    |> flatten_tree(tree)
    |> mark_leaves()
  end

  defp flatten_tree(chain, nodes, parent_slug \\ nil, level \\ 1) do
    Enum.flat_map(nodes, fn node ->
      slug = slug_from_url(node["url"])

      cat = %Category{
        chain: chain,
        slug: slug,
        name: node["name"],
        external_id: to_string_if_present(node["id"]),
        parent_slug: parent_slug,
        level: level
      }

      children = List.wrap(node["children"])
      [cat | flatten_tree(chain, children, slug, level + 1)]
    end)
  end

  defp slug_from_url(url) when is_binary(url) do
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

  @spec discover_products(Config.t(), String.t()) ::
          {:ok, [Listing.t()]} | {:error, term()}
  def discover_products(%Config{} = cfg, slug) when is_binary(slug) do
    list_all_pages(cfg, slug, 1, [], nil)
  end

  defp list_all_pages(cfg, slug, page, acc, total) do
    path =
      "/v2/products/search/#{encode_slug(slug)}?ft=&page=#{page}&sc=#{cfg.sales_channel}"

    url = @catalog_api <> path

    case get_with_headers(cfg, url) do
      {:ok, %Http.Response{} = resp} ->
        cond do
          Http.blocked?(resp) ->
            :blocked

          resp.status == 200 ->
            case Jason.decode(resp.body) do
              {:ok, products} when is_list(products) ->
                listings = Enum.map(products, &parse_listing(cfg, &1, slug))
                new_total = total || parse_resources_total(resp.headers)
                new_acc = acc ++ listings

                cond do
                  products == [] -> {:ok, new_acc}
                  length(products) < @page_size -> {:ok, new_acc}
                  is_integer(new_total) and page * @page_size >= new_total -> {:ok, new_acc}
                  true -> list_all_pages(cfg, slug, page + 1, new_acc, new_total)
                end

              {:ok, _} ->
                {:ok, acc}

              {:error, _} = err ->
                err
            end

          true ->
            {:error, {:http_status, resp.status, String.slice(resp.body, 0, 200)}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp encode_slug(slug) do
    slug
    |> String.split("/", trim: true)
    |> Enum.map_join("/", &URI.encode_www_form/1)
  end

  @doc false
  def parse_resources_total(headers) do
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

  @spec fetch_product_info(Config.t(), [String.t()]) ::
          {:ok, [Listing.t()]} | {:error, term()}
  def fetch_product_info(%Config{} = cfg, chain_skus) when is_list(chain_skus) do
    chain_skus
    |> Enum.chunk_every(@sku_batch_size)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      csv = Enum.join(batch, ",")

      url =
        "#{@catalog_api}/v1/products/skus?skuIds=#{URI.encode_www_form(csv)}&sc=#{cfg.sales_channel}"

      case get_json(cfg, url, :normal) do
        {:ok, products} when is_list(products) ->
          listings = Enum.map(products, &parse_listing(cfg, &1, nil))
          {:cont, {:ok, acc ++ listings}}

        {:ok, _} ->
          {:cont, {:ok, acc}}

        :blocked ->
          {:halt, :blocked}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  @doc """
  Parses a decoded VTEX-classic products list (stage 2 or stage 3
  response) into `%Listing{}` structs. Exposed for unit testing.
  """
  def parse_products(%Config{} = cfg, products, category_slug \\ nil) when is_list(products) do
    Enum.map(products, &parse_listing(cfg, &1, category_slug))
  end

  # Shared parser — stage 2 and stage 3 both return VTEX classic shape:
  # [{productId, productName, brand, items: [{itemId, ean, sellers: [{commertialOffer: {Price, ListPrice, ...}}]}]}]
  defp parse_listing(cfg, %{} = product, category_slug) do
    item = first_item(product)
    offer = commercial_offer(item)
    {regular, promo} = prices_from_offer(offer)

    %Listing{
      chain: cfg.chain,
      chain_sku: to_string_if_present(item["itemId"]),
      chain_product_id: to_string_if_present(product["productId"]),
      ean: blank_to_nil(item["ean"]),
      name: product["productName"] || item["name"],
      brand: product["brand"],
      image_url: first_image_url(item),
      pdp_url: pdp_url_from(cfg, product),
      category_path: category_slug,
      regular_price: regular,
      promo_price: promo,
      promotions: %{}
    }
  end

  # HTTP

  defp get_json(cfg, url, _priority) do
    case get_with_headers(cfg, url) do
      {:ok, %Http.Response{} = resp} ->
        cond do
          Http.blocked?(resp) -> :blocked
          resp.status == 200 -> Jason.decode(resp.body)
          true -> {:error, {:http_status, resp.status, String.slice(resp.body, 0, 200)}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp get_with_headers(cfg, url) do
    profile = Session.get(cfg.chain, :profile) || cfg.profile
    Http.get(url, headers: headers_for(cfg), profile: profile)
  end

  defp headers_for(%Config{site_url: site}) do
    [
      {"user-agent", @user_agent},
      {"accept", "application/json, text/plain, */*"},
      {"accept-language", "es-CL,es;q=0.9,en;q=0.8"},
      {"accept-encoding", "gzip, deflate, br, zstd"},
      {"apiKey", @api_key},
      {"origin", site},
      {"referer", site <> "/"},
      {"sec-ch-ua", ~s("Chromium";v="131", "Not_A Brand";v="24", "Google Chrome";v="131")},
      {"sec-ch-ua-mobile", "?0"},
      {"sec-ch-ua-platform", ~s("macOS")},
      {"sec-fetch-dest", "empty"},
      {"sec-fetch-mode", "cors"},
      {"sec-fetch-site", "cross-site"}
    ]
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

  defp pdp_url_from(%Config{site_url: site}, %{"linkText" => lt})
       when is_binary(lt) and lt != "",
       do: site <> "/" <> lt <> "/p"

  defp pdp_url_from(%Config{site_url: site}, %{"link" => link})
       when is_binary(link) and link != "",
       do: site <> link

  defp pdp_url_from(_, _), do: nil

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
