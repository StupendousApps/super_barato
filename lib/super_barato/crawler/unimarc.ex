defmodule SuperBarato.Crawler.Unimarc do
  @moduledoc """
  Unimarc adapter backed by the Next.js SSR data endpoint.

  The public VTEX catalog API (`/api/catalog_system/...`) returns 500 on
  Unimarc's deployment. Their frontend fetches category data from
  `/_next/data/<buildId>/category/<slug>.json?slug=<slug>` instead.

  On first use we GET the homepage, parse `"buildId":"<id>"` out of the
  embedded `__NEXT_DATA__` script, and cache it per chain. Subsequent
  category fetches reuse that build id.

  All HTTP goes through `Crawler.Http` (curl-impersonate) so TLS
  fingerprinting doesn't block us, and through `Crawler.RateLimiter` so
  discovery and price jobs share the politeness bucket.
  """

  @behaviour SuperBarato.Crawler.Chain

  alias SuperBarato.Crawler.{Http, Listing, Price, RateLimiter, Session}

  require Logger

  @chain :unimarc
  @base_url "https://www.unimarc.cl"

  @user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

  # Sent on the homepage warm-up (full-document navigation).
  @warmup_headers [
    {"user-agent", @user_agent},
    {"accept",
     "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7"},
    {"accept-language", "es-CL,es;q=0.9,en;q=0.8"},
    {"accept-encoding", "gzip, deflate, br, zstd"},
    {"cache-control", "no-cache"},
    {"pragma", "no-cache"},
    {"dnt", "1"},
    {"priority", "u=0, i"},
    {"sec-ch-ua", ~s("Chromium";v="131", "Not_A Brand";v="24", "Google Chrome";v="131")},
    {"sec-ch-ua-mobile", "?0"},
    {"sec-ch-ua-platform", ~s("macOS")},
    {"sec-fetch-dest", "document"},
    {"sec-fetch-mode", "navigate"},
    {"sec-fetch-site", "none"},
    {"sec-fetch-user", "?1"},
    {"upgrade-insecure-requests", "1"}
  ]

  # Sent on XHR-style API requests (the _next/data JSON).
  @api_headers [
    {"user-agent", @user_agent},
    {"accept", "*/*"},
    {"accept-language", "es-CL,es;q=0.9,en;q=0.8"},
    {"accept-encoding", "gzip, deflate, br, zstd"},
    {"cache-control", "no-cache"},
    {"pragma", "no-cache"},
    {"dnt", "1"},
    {"priority", "u=1, i"},
    {"referer", "https://www.unimarc.cl/"},
    {"sec-ch-ua", ~s("Chromium";v="131", "Not_A Brand";v="24", "Google Chrome";v="131")},
    {"sec-ch-ua-mobile", "?0"},
    {"sec-ch-ua-platform", ~s("macOS")},
    {"sec-fetch-dest", "empty"},
    {"sec-fetch-mode", "cors"},
    {"sec-fetch-site", "same-origin"},
    {"x-nextjs-data", "1"}
  ]

  @impl true
  def id, do: @chain

  @impl true
  def seed_categories do
    Application.get_env(:super_barato, __MODULE__, [])
    |> Keyword.get(:seed_categories, [])
  end

  @impl true
  def discover_category(slug) when is_binary(slug) do
    with {:ok, build_id} <- ensure_build_id(),
         {:ok, data} <- fetch_category(build_id, slug) do
      products = available_products(data)
      {:ok, Enum.map(products, &parse_listing(&1, slug))}
    end
  end

  @impl true
  def fetch_prices(_chain_skus) do
    # Unimarc's VTEX API is 500-blocked; Next.js _next/data doesn't support
    # lookup by SKU. Price refresh for this chain is best done by re-running
    # discovery (prices are in the listing payload). Kept as a no-op until we
    # either switch strategies or find a client-side API.
    {:error, :not_implemented}
  end

  # Build ID

  defp ensure_build_id do
    case Session.get(@chain, :build_id) do
      id when is_binary(id) ->
        {:ok, id}

      _ ->
        RateLimiter.request(@chain, :high, fn ->
          case Http.get(@base_url <> "/", headers: @warmup_headers) do
            {:ok, %Http.Response{status: 200, body: body} = resp} ->
              Session.absorb_response(@chain, resp)

              case extract_build_id(body) do
                nil ->
                  {:error, :build_id_not_found}

                build_id ->
                  Session.put(@chain, :build_id, build_id)
                  {:ok, build_id}
              end

            {:ok, %Http.Response{status: status}} ->
              {:error, {:homepage_status, status}}

            {:error, _} = err ->
              err
          end
        end)
    end
  end

  defp extract_build_id(html) when is_binary(html) do
    case Regex.run(~r/"buildId"\s*:\s*"([^"]+)"/, html) do
      [_, id] -> id
      _ -> nil
    end
  end

  # Category fetch

  defp fetch_category(build_id, slug) do
    url =
      "#{@base_url}/_next/data/#{build_id}/category/#{slug}.json" <>
        "?" <>
        slug_query(slug)

    RateLimiter.request(@chain, :high, fn ->
      headers = with_cookies(@api_headers)

      case Http.get(url, headers: headers) do
        {:ok, %Http.Response{status: 200, body: body} = resp} ->
          Session.absorb_response(@chain, resp)
          Jason.decode(body)

        {:ok, %Http.Response{status: 404}} ->
          # Build id likely rotated — invalidate and caller can retry.
          Session.put(@chain, :build_id, nil)
          {:error, :build_id_stale}

        {:ok, %Http.Response{status: status, body: body}} ->
          {:error, {:http_status, status, String.slice(body, 0, 200)}}

        {:error, _} = err ->
          err
      end
    end)
  end

  # Next.js catch-all [...slug] pages expect each path segment as a repeated
  # `slug` query param.
  defp slug_query(slug) do
    slug
    |> String.split("/", trim: true)
    |> Enum.map_join("&", &"slug=#{URI.encode_www_form(&1)}")
  end

  defp with_cookies(headers) do
    case Session.cookie_header(@chain) do
      nil -> headers
      cookie -> [{"cookie", cookie} | headers]
    end
  end

  # Parsing

  defp available_products(%{"pageProps" => %{"dehydratedState" => %{"queries" => queries}}})
       when is_list(queries) do
    queries
    |> Enum.flat_map(fn q ->
      get_in(q, ["state", "data", "availableProducts"]) || []
    end)
  end

  defp available_products(_), do: []

  defp parse_listing(product, category_slug) do
    seller = first_seller(product)
    {regular, promo} = prices(seller)

    %Listing{
      chain: @chain,
      chain_sku: to_string(product["sku"] || product["itemId"]),
      chain_product_id: to_string_if_present(product["productId"]),
      ean: blank_to_nil(product["ean"]),
      name: product["nameComplete"] || product["name"],
      brand: product["brand"],
      image_url: first_image_url(product),
      pdp_url: pdp_url(product),
      category_path: category_slug,
      regular_price: regular,
      promo_price: promo,
      promotions: promotions_map(product)
    }
  end

  defp first_seller(%{"sellers" => [s | _]}) when is_map(s), do: s
  defp first_seller(_), do: %{}

  defp prices(seller) do
    regular = price_int(seller["listPrice"]) || price_int(seller["priceWithoutDiscount"])
    price = price_int(seller["price"])

    cond do
      is_integer(regular) and is_integer(price) and price < regular -> {regular, price}
      is_integer(regular) -> {regular, nil}
      is_integer(price) -> {price, nil}
      true -> {nil, nil}
    end
  end

  defp first_image_url(%{"images" => [url | _]}) when is_binary(url), do: url

  defp first_image_url(%{"images" => [%{"imageUrl" => url} | _]}) when is_binary(url),
    do: url

  defp first_image_url(_), do: nil

  defp pdp_url(%{"detailUrl" => url}) when is_binary(url) and url != "",
    do: @base_url <> url

  defp pdp_url(%{"slug" => slug}) when is_binary(slug) and slug != "",
    do: @base_url <> ensure_leading_slash(slug)

  defp pdp_url(_), do: nil

  defp ensure_leading_slash("/" <> _ = s), do: s
  defp ensure_leading_slash(s), do: "/" <> s

  defp promotions_map(product) do
    detail = product["priceDetail"] || %{}

    %{
      "discount_percentage" => detail["discountPercentage"],
      "promotion_name" => detail["promotionName"],
      "promotion_type" => detail["promotionType"],
      "promotional_tag" => detail["promotionalTag"],
      "coupon" => product["coupon"]
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp price_int(nil), do: nil
  defp price_int(n) when is_integer(n) and n > 0, do: n
  defp price_int(n) when is_integer(n), do: nil
  defp price_int(n) when is_float(n), do: trunc(n)

  defp price_int(s) when is_binary(s) do
    # "$1.490" → 1490. Chilean pesos use "." as thousands separator.
    case Integer.parse(String.replace(s, ~r/[^\d]/, "")) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp price_int(_), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s

  defp to_string_if_present(nil), do: nil
  defp to_string_if_present(v), do: to_string(v)

  # Suppress unused-alias warning — Price is part of the behaviour contract
  # and will be wired back up when fetch_prices/1 is implemented.
  _ = Price
end
