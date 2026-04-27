defmodule SuperBarato.Crawler.Unimarc do
  @moduledoc """
  Unimarc adapter backed by their BFF at
  `https://bff-unimarc-ecommerce.unimarc.cl`. Three stages:

    * Categories: term-fanout on `/catalog/product/facets` + fallback
      constant for top-level departments. Subtrees come from a single
      facets call per top-level (response includes `category1/2/3`).
    * Products: paginated `/catalog/product/search` by category slug.
      Page size 50; response `resource` field is the total count.
    * Product info: batched `/catalog/product/search/by-identifier` by
      EAN, 25 per call. Returns a nested `{item, price, ...}` shape.

  Required BFF headers: `source: web`, `version: <semver>`,
  `channel: UNIMARC`.
  """

  @behaviour SuperBarato.Crawler.Chain

  alias SuperBarato.Crawler.{Category, Http, Listing, Session}
  alias SuperBarato.Linker.Identity

  require Logger

  @chain :unimarc
  @bff_url "https://bff-unimarc-ecommerce.unimarc.cl"
  @site_url "https://www.unimarc.cl"
  @page_size 50

  @user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

  @bff_headers [
    {"user-agent", @user_agent},
    {"accept", "application/json, text/plain, */*"},
    {"accept-language", "es-CL,es;q=0.9,en;q=0.8"},
    {"accept-encoding", "gzip, deflate, br, zstd"},
    {"content-type", "application/json"},
    {"source", "web"},
    {"version", "1.0.0"},
    {"channel", "UNIMARC"},
    {"origin", @site_url},
    {"referer", @site_url <> "/"},
    {"sec-ch-ua", ~s("Chromium";v="131", "Not_A Brand";v="24", "Google Chrome";v="131")},
    {"sec-ch-ua-mobile", "?0"},
    {"sec-ch-ua-platform", ~s("macOS")},
    {"sec-fetch-dest", "empty"},
    {"sec-fetch-mode", "cors"},
    {"sec-fetch-site", "same-site"}
  ]

  # Union of `category1` results across these terms gets us all 14
  # top-level departments. If that fails (or gets fewer than
  # @min_top_levels), we merge with the fallback below.
  @discovery_terms ~w(a e i o u leche pan agua arroz aceite queso carne pollo pescado jabon champu papel cerveza helado yogurt)

  @min_top_levels 10

  @fallback_top_level_categories [
    %{slug: "carnes", name: "Carnes", external_id: "349"},
    %{slug: "frutas-y-verduras", name: "Frutas y Verduras", external_id: "350"},
    %{
      slug: "lacteos-huevos-y-refrigerados",
      name: "Lácteos, Huevos y Refrigerados",
      external_id: "351"
    },
    %{slug: "quesos-y-fiambres", name: "Quesos y Fiambres", external_id: "352"},
    %{slug: "panaderia-y-pasteleria", name: "Panadería y Pastelería", external_id: "353"},
    %{slug: "congelados", name: "Congelados", external_id: "354"},
    %{slug: "despensa", name: "Despensa", external_id: "355"},
    %{slug: "desayuno-y-dulces", name: "Desayuno y Dulces", external_id: "356"},
    %{slug: "bebidas-y-licores", name: "Bebidas y Licores", external_id: "357"},
    %{slug: "limpieza", name: "Limpieza", external_id: "358"},
    %{slug: "perfumeria", name: "Perfumería", external_id: "359"},
    %{slug: "bebes-y-ninos", name: "Bebés y Niños", external_id: "360"},
    %{slug: "mascotas", name: "Mascotas", external_id: "361"},
    %{slug: "hogar", name: "Hogar", external_id: "362"}
  ]

  @impl true
  def id, do: @chain

  @impl true
  def refresh_identifier, do: :ean

  @impl true
  def handle_task({:discover_categories, %{parent: nil}}), do: discover_categories()

  def handle_task({:discover_products, %{slug: slug}}), do: discover_products(slug)

  def handle_task({:fetch_product_info, %{identifiers: ids}}),
    do: fetch_product_info(ids)

  def handle_task(other), do: {:error, {:unsupported_task, other}}

  # Stage 1: categories

  defp discover_categories do
    case top_level_categories() do
      :blocked ->
        :blocked

      top_levels when is_list(top_levels) ->
        result =
          Enum.reduce_while(top_levels, {:ok, []}, fn top, {:ok, acc} ->
            case fetch_subtree(top.slug) do
              {:ok, subs} ->
                {:cont, {:ok, acc ++ subs}}

              :blocked ->
                {:halt, :blocked}

              {:error, reason} ->
                Logger.warning("unimarc subtree for #{top.slug} failed: #{inspect(reason)}")
                {:cont, {:ok, acc}}
            end
          end)

        case result do
          :blocked ->
            :blocked

          {:ok, children} ->
            all = Enum.uniq_by(top_levels ++ children, & &1.slug)
            {:ok, mark_leaves(all)}
        end
    end
  end

  # Always union fanout + fallback. Fanout is the authoritative source
  # for "what exists today"; fallback is a floor so a single bad day
  # of fanout never loses a department. If fanout is unusually small,
  # warn — it means fanout broke and we're running on stale data.
  defp top_level_categories do
    case term_fanout() do
      :blocked ->
        :blocked

      found when is_map(found) ->
        if map_size(found) < @min_top_levels do
          Logger.warning(
            "unimarc term-fanout returned only #{map_size(found)} top-levels (< #{@min_top_levels}); fallback will carry the load"
          )
        end

        fallback =
          Enum.reduce(@fallback_top_level_categories, %{}, fn fb, acc ->
            Map.put(acc, fb.slug, %Category{
              chain: @chain,
              slug: fb.slug,
              name: fb.name,
              parent_slug: nil,
              external_id: fb.external_id,
              level: 1
            })
          end)

        fallback
        |> Map.merge(found)
        |> Map.values()
    end
  end

  defp term_fanout do
    Enum.reduce_while(@discovery_terms, %{}, fn term, acc ->
      body = %{"categories" => "", "categoryLevel" => "1", "searching" => term}

      case post_facets(body) do
        {:ok, %{"category1" => c1} = _data} when is_list(c1) ->
          acc =
            Enum.reduce(c1, acc, fn raw, a ->
              Map.put_new(a, raw["value"], to_category(raw, level: 1, parent: nil))
            end)

          {:cont, acc}

        :blocked ->
          {:halt, :blocked}

        _ ->
          {:cont, acc}
      end
    end)
  end

  defp fetch_subtree(top_slug) do
    body = %{"categories" => top_slug, "categoryLevel" => "1"}

    case post_facets(body) do
      {:ok, data} ->
        c2 =
          (data["category2"] || [])
          |> Enum.map(&to_category(&1, level: 2, parent: nil))

        c3 =
          (data["category3"] || [])
          |> Enum.map(&to_category(&1, level: 3, parent: nil))

        {:ok, c2 ++ c3}

      :blocked ->
        :blocked

      err ->
        err
    end
  end

  # Build a Category from a facet row. `categoryTree` holds the full
  # slug path; parent_slug is the path minus the last segment.
  defp to_category(raw, opts) do
    slug = raw["categoryTree"] || raw["value"]
    level = Keyword.get(opts, :level) || infer_level(raw["level"])

    %Category{
      chain: @chain,
      slug: slug,
      name: raw["name"],
      parent_slug: parent_of(slug),
      external_id: to_string_if_present(raw["id"]),
      level: level
    }
  end

  defp infer_level(nil), do: nil

  defp infer_level(s) when is_binary(s) do
    case Regex.run(~r/^C(\d+):/, s) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  defp parent_of(slug) when is_binary(slug) do
    case String.split(slug, "/", trim: true) do
      [_] -> nil
      parts -> parts |> Enum.drop(-1) |> Enum.join("/")
    end
  end

  defp parent_of(_), do: nil

  defp mark_leaves(categories) do
    parent_slugs =
      categories
      |> Enum.map(& &1.parent_slug)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.map(categories, fn cat ->
      %{cat | is_leaf: not MapSet.member?(parent_slugs, cat.slug)}
    end)
  end

  # Stage 2: products by category

  defp discover_products(slug) when is_binary(slug) do
    list_all_pages(slug, 0, [], nil)
  end

  defp list_all_pages(slug, from, acc, resource_total) do
    to = from + @page_size - 1
    body = %{"from" => to_string(from), "to" => to_string(to), "categories" => slug}

    case post_json(@bff_url <> "/catalog/product/search", body) do
      {:ok, %{"availableProducts" => products} = resp} ->
        total = resource_total || parse_resource(resp["resource"])
        listings = Enum.map(products, &parse_listing(&1, slug))
        new_acc = acc ++ listings

        cond do
          length(products) < @page_size -> {:ok, new_acc}
          is_integer(total) and from + @page_size >= total -> {:ok, new_acc}
          true -> list_all_pages(slug, from + @page_size, new_acc, total)
        end

      {:ok, _other} ->
        {:ok, acc}

      :blocked ->
        :blocked

      {:error, _} = err ->
        err
    end
  end

  defp parse_resource(nil), do: nil

  defp parse_resource(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp parse_resource(n) when is_integer(n), do: n
  defp parse_resource(_), do: nil

  # Stage 3: product info by EAN

  defp fetch_product_info(eans) when is_list(eans) do
    eans
    |> Enum.chunk_every(25)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      body = %{"field" => "ean", "values" => batch, "salesChannel" => "UNIMARC"}

      case post_json(@bff_url <> "/catalog/product/search/by-identifier", body) do
        {:ok, %{"availableProducts" => products}} ->
          listings = Enum.map(products, &parse_listing(&1, nil))
          {:cont, {:ok, acc ++ listings}}

        :blocked ->
          {:halt, :blocked}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  @doc """
  Parses a decoded `availableProducts` list (stage 2 or stage 3
  response) into `%Listing{}` structs. Exposed for unit testing.
  """
  def parse_products(products, category_slug \\ nil) when is_list(products) do
    products
    |> Enum.map(&parse_listing(&1, category_slug))
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Parses a decoded `postFacets` response into the subtree's category
  list: the category1 filter itself plus its category2 and category3
  children. Exposed for unit testing.
  """
  def parse_subtree(data) when is_map(data) do
    c1 = (data["category1"] || []) |> Enum.map(&to_category(&1, level: 1, parent: nil))
    c2 = (data["category2"] || []) |> Enum.map(&to_category(&1, level: 2, parent: nil))
    c3 = (data["category3"] || []) |> Enum.map(&to_category(&1, level: 3, parent: nil))
    mark_leaves(c1 ++ c2 ++ c3)
  end

  # Shared parser — postProductsSearch and by-identifier both return the
  # same nested `{item, price, promotion, priceDetail, coupon}` shape.
  defp parse_listing(%{"item" => item} = outer, category_slug) when is_map(item) do
    price = outer["price"] || %{}
    {regular, promo} = prices_from_price_obj(price)

    identifiers =
      %{
        "sku" => item["sku"],
        "itemId" => item["itemId"],
        "productId" => item["productId"],
        "ean" => item["ean"],
        "referenceCode" => item["referenceCode"]
      }
      |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
      |> Map.new()

    %Listing{
      chain: @chain,
      chain_sku: to_string(item["sku"] || item["itemId"]),
      chain_product_id: to_string_if_present(item["productId"]),
      ean: blank_to_nil(item["ean"]),
      identifiers_key: Identity.encode(identifiers),
      raw: %{"item" => item, "price" => price, "promotion" => outer["promotion"]},
      name: item["nameComplete"] || item["name"],
      brand: item["brand"],
      image_url: first_image_url(item),
      pdp_url: pdp_url_from(item),
      category_path: category_slug || item["categorySlug"],
      regular_price: regular,
      promo_price: promo,
      promotions: promotions_map(outer)
    }
  end

  defp parse_listing(_, _), do: nil

  # HTTP helpers

  defp post_facets(body) do
    defaults = %{"salesChannel" => "UNIMARC", "searching" => "", "promotionsOnly" => false}
    body = Map.merge(defaults, body)
    post_json(@bff_url <> "/catalog/product/facets", body)
  end

  defp post_json(url, body) when is_map(body) do
    json = Jason.encode!(body)
    profile = Session.get(@chain, :profile)

    case Http.post(url, headers: @bff_headers, body: json, profile: profile) do
      {:ok, %Http.Response{} = resp} ->
        cond do
          Http.blocked?(resp) -> :blocked
          resp.status in 200..299 -> Jason.decode(resp.body)
          true -> {:error, {:http_status, resp.status, String.slice(resp.body, 0, 300)}}
        end

      {:error, _} = err ->
        err
    end
  end

  # Shared parsing helpers

  defp prices_from_price_obj(%{} = price) do
    regular = price_int(price["listPrice"]) || price_int(price["priceWithoutDiscount"])
    current = price_int(price["price"])
    decide_prices(regular, current)
  end

  defp decide_prices(regular, current) do
    cond do
      is_integer(regular) and is_integer(current) and current < regular -> {regular, current}
      is_integer(regular) -> {regular, nil}
      is_integer(current) -> {current, nil}
      true -> {nil, nil}
    end
  end

  defp first_image_url(%{"images" => [url | _]}) when is_binary(url), do: url
  defp first_image_url(%{"images" => [%{"imageUrl" => url} | _]}) when is_binary(url), do: url
  defp first_image_url(_), do: nil

  defp pdp_url_from(%{"detailUrl" => url}) when is_binary(url) and url != "" do
    @site_url <> url
  end

  defp pdp_url_from(%{"slug" => slug}) when is_binary(slug) and slug != "" do
    @site_url <> ensure_leading_slash(slug)
  end

  defp pdp_url_from(_), do: nil

  defp ensure_leading_slash("/" <> _ = s), do: s
  defp ensure_leading_slash(s), do: "/" <> s

  defp promotions_map(outer) do
    promotion = outer["promotion"] || %{}
    detail = outer["priceDetail"] || %{}

    %{
      "discount_percentage" => detail["discountPercentage"],
      "promotion_name" => promotion["name"] || detail["promotionName"],
      "promotion_type" => promotion["type"] || detail["promotionType"],
      "promotional_tag" => detail["promotionalTag"],
      "description_message" => promotion["descriptionMessage"],
      "coupon" => outer["coupon"]
    }
    |> compact()
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" or v == %{} end)
    |> Map.new()
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

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s

  defp to_string_if_present(nil), do: nil
  defp to_string_if_present(v), do: to_string(v)
end
