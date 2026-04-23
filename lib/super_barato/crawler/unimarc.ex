defmodule SuperBarato.Crawler.Unimarc do
  @moduledoc """
  Unimarc adapter backed by the VTEX public catalog API.

    * Listings: /api/catalog_system/pub/products/search/?fq=C:<categoryId>
    * Single product: /api/catalog_system/pub/products/search/?fq=productId:<id>

  Unimarc exposes 13-digit EANs at `items[0].ean`, so we read them directly.
  """

  @behaviour SuperBarato.Crawler.Chain

  alias SuperBarato.Crawler.RateLimiter

  @chain :unimarc
  @base_url "https://www.unimarc.cl"
  @page_size 50
  @user_agent "super-barato/0.1 (+https://github.com/stupendous/super-barato)"

  @impl true
  def id, do: @chain

  @impl true
  def seed_categories do
    Application.get_env(:super_barato, __MODULE__, [])
    |> Keyword.get(:seed_categories, [])
  end

  @impl true
  def discover_category(category_id) do
    with {:ok, raw} <- list_all_pages(category_id) do
      {:ok, Enum.map(raw, &parse_listing/1)}
    end
  end

  @impl true
  def fetch_prices(chain_skus) when is_list(chain_skus) do
    chain_skus
    |> Enum.chunk_every(25)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      case search(sku_filter_params(batch)) do
        {:ok, raw} -> {:cont, {:ok, acc ++ Enum.map(raw, &parse_price/1)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # Internals

  defp list_all_pages(category_id, from \\ 0, acc \\ []) do
    to = from + @page_size - 1

    params = [
      {"fq", "C:#{category_id}"},
      {"_from", to_string(from)},
      {"_to", to_string(to)}
    ]

    case search(params) do
      {:ok, []} ->
        {:ok, acc}

      {:ok, items} when length(items) < @page_size ->
        {:ok, acc ++ items}

      {:ok, items} ->
        list_all_pages(category_id, from + @page_size, acc ++ items)

      {:error, _} = err ->
        err
    end
  end

  defp sku_filter_params(skus) do
    Enum.map(skus, fn sku -> {"fq", "skuId:#{sku}"} end)
  end

  defp search(params) do
    url = "#{@base_url}/api/catalog_system/pub/products/search/"

    RateLimiter.request(@chain, priority_for(params), fn ->
      case Req.get(url,
             params: params,
             headers: [{"user-agent", @user_agent}, {"accept", "application/json"}],
             retry: :transient
           ) do
        {:ok, %{status: 200, body: body}} when is_list(body) ->
          {:ok, body}

        {:ok, %{status: 206, body: body}} when is_list(body) ->
          {:ok, body}

        {:ok, %{status: status, body: body}} ->
          {:error, {:http_status, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp priority_for(params) when is_list(params) do
    Enum.find_value(params, :normal, fn
      {"fq", "C:" <> _} -> :high
      _ -> nil
    end)
  end

  # Parsers

  defp parse_listing(%{} = product) do
    item = first_item(product)
    offer = commercial_offer(item)

    %{
      chain: to_string(@chain),
      chain_sku: item["itemId"],
      chain_product_id: product["productId"],
      ean: blank_to_nil(item["ean"]),
      name: product["productName"],
      brand: product["brand"],
      image_url: first_image_url(item),
      pdp_url: product["link"] && @base_url <> product["link"],
      category_path: product["categories"] |> List.wrap() |> List.first(),
      current_regular_price: price_int(offer["ListPrice"]),
      current_promo_price: promo_price(offer),
      current_promotions: %{
        "teasers" => offer["Teasers"] || [],
        "discount_highlights" => offer["DiscountHighLight"] || []
      }
    }
  end

  defp parse_price(%{} = product) do
    item = first_item(product)
    offer = commercial_offer(item)

    %{
      chain_sku: item["itemId"],
      regular_price: price_int(offer["ListPrice"]),
      promo_price: promo_price(offer),
      promotions: %{
        "teasers" => offer["Teasers"] || [],
        "discount_highlights" => offer["DiscountHighLight"] || []
      }
    }
  end

  defp first_item(%{"items" => [item | _]}), do: item
  defp first_item(_), do: %{}

  defp commercial_offer(%{"sellers" => [%{"commertialOffer" => offer} | _]}) when is_map(offer),
    do: offer

  defp commercial_offer(_), do: %{}

  defp first_image_url(%{"images" => [%{"imageUrl" => url} | _]}), do: url
  defp first_image_url(_), do: nil

  defp price_int(nil), do: nil
  defp price_int(n) when is_integer(n), do: n
  defp price_int(n) when is_float(n), do: trunc(n)

  defp promo_price(%{"Price" => price, "ListPrice" => list}) when price != list,
    do: price_int(price)

  defp promo_price(_), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s
end
