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
    @moduledoc """
    Per-chain configuration for the shared Cencosud adapter.

    `:sitemap_index` is the entry point for sitemap-driven product
    discovery — usually a `<sitemapindex>` listing one or more
    `<sitemap><loc>...</loc></sitemap>` children, each pointing at a
    `<urlset>` of product PDP URLs. We support both the multi-file
    layout (Jumbo: `assets.jumbo.cl/sitemap.xml` → 50 sub-sitemaps)
    and the single-file layout (Santa Isabel: a Supabase-hosted
    `<urlset>` directly).
    """

    @enforce_keys [:chain, :site_url, :categories_url, :sales_channel, :sitemap_index]
    defstruct [
      :chain,
      :site_url,
      :categories_url,
      :sales_channel,
      :sitemap_index,
      profile: nil
    ]

    @type t :: %__MODULE__{
            chain: atom(),
            site_url: String.t(),
            categories_url: String.t(),
            sales_channel: String.t(),
            sitemap_index: String.t(),
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

  # Sitemap discovery — list every product PDP URL the chain
  # advertises, by walking the chain's sitemap index. Returns a flat
  # list of canonical URLs (e.g. `https://www.jumbo.cl/<slug>/p`).
  # Used by `Cencosud.SitemapProducer` to enqueue per-PDP fetch tasks
  # against the Worker's regular politeness gap.
  @spec list_sitemap_urls(Config.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_sitemap_urls(%Config{} = cfg) do
    case fetch_xml(cfg, cfg.sitemap_index) do
      {:ok, body} ->
        sub_sitemaps = extract_locs(body, "sitemap")
        product_urls = extract_locs(body, "url")

        # `<sitemapindex>` (sub-sitemaps) and `<urlset>` (PDP URLs)
        # are mutually exclusive at the spec level, but our extractor
        # is forgiving — accept whichever the index actually was.
        cond do
          sub_sitemaps != [] -> walk_sub_sitemaps(cfg, sub_sitemaps)
          product_urls != [] -> {:ok, product_urls}
          true -> {:error, :empty_sitemap}
        end

      {:error, _} = err ->
        err
    end
  end

  defp walk_sub_sitemaps(cfg, sub_sitemaps) do
    Enum.reduce_while(sub_sitemaps, {:ok, []}, fn url, {:ok, acc} ->
      case fetch_xml(cfg, url) do
        {:ok, body} ->
          {:cont, {:ok, acc ++ extract_locs(body, "url")}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  @doc """
  Lightweight `<loc>` extractor scoped to a wrapper tag (`<sitemap>`
  for indexes, `<url>` for url sets). Public for unit testing against
  real-world sitemap fixtures.

  We use regex rather than a streaming parser because the sitemap
  dialect is tiny, deterministic, and the largest file we deal with
  is ~3 MB — `Regex.scan/2` handles it in one pass.
  """
  def extract_locs(xml, wrapper) when is_binary(xml) and is_binary(wrapper) do
    # Some sitemaps inline the wrapper tag attributes (e.g. multi-line
    # entries); allow optional whitespace + attributes between `<wrap>`
    # and the inner `<loc>`.
    pattern = ~r{<#{wrapper}(?:\s[^>]*)?>\s*<loc>([^<]+)</loc>}

    Regex.scan(pattern, xml, capture: :all_but_first)
    |> Enum.map(fn [u] -> String.trim(u) end)
  end

  # CloudFront occasionally resets the TLS handshake mid-fetch (curl
  # exit 35, "Recv failure: Connection reset by peer"). The producer
  # is a one-shot and the index file is small, so retry a few times
  # with a brief backoff before giving up — much cheaper than failing
  # the whole nightly run.
  defp fetch_xml(cfg, url, attempts_left \\ 3) do
    case Http.get(url, chain: cfg.chain, headers: xml_headers(cfg)) do
      {:ok, %Http.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Http.Response{status: status}} when status in 500..599 and attempts_left > 1 ->
        Process.sleep(2_000)
        fetch_xml(cfg, url, attempts_left - 1)

      {:ok, %Http.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, _} when attempts_left > 1 ->
        Process.sleep(2_000)
        fetch_xml(cfg, url, attempts_left - 1)

      {:error, _} = err ->
        err
    end
  end

  defp xml_headers(%Config{site_url: site}) do
    [
      {"user-agent", @user_agent},
      {"accept", "application/xml,text/xml,*/*;q=0.8"},
      {"accept-language", "es-CL,es;q=0.9,en;q=0.8"},
      {"accept-encoding", "gzip, deflate, br"},
      {"referer", site <> "/"}
    ]
  end

  # PDP-driven price fetch. Replaces the old VTEX
  # `/v2/products/search/:slug` enumeration: we GET the product page,
  # extract its `<script type="application/ld+json">` Product+Offer
  # blob, and translate it into a `%Listing{}`. No `?sc=N` query —
  # robots.txt allows PDP URLs and disallows `*sc=*`.
  @spec fetch_product_pdp(Config.t(), String.t()) ::
          {:ok, [Listing.t()]} | :blocked | {:error, term()}
  def fetch_product_pdp(%Config{} = cfg, url) when is_binary(url) do
    case Http.get(url, chain: cfg.chain, headers: pdp_headers(cfg), profile: profile_for(cfg)) do
      {:ok, %Http.Response{} = resp} ->
        cond do
          Http.blocked?(resp) ->
            :blocked

          resp.status == 200 ->
            case parse_pdp(cfg, resp.body, url) do
              {:ok, %Listing{} = listing} ->
                {:ok, [listing]}

              {:error, :no_product_jsonld} ->
                # Wrap with body shape so the worker's log line names
                # the URL + size + content-encoding without needing a
                # separate diagnostic. Normal sitemap drift (Product
                # not rendered, lazy SPA, etc.) is the usual cause.
                {:error, {:no_product_jsonld, response_diag(resp)}}

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

  defp profile_for(cfg) do
    Session.get(cfg.chain, :profile) || cfg.profile
  end

  defp response_diag(%Http.Response{body: body, headers: headers}) do
    %{
      size: byte_size(body),
      ctype: header(headers, "content-type"),
      cenc: header(headers, "content-encoding")
    }
  end

  defp header(headers, key) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == key, do: v
    end)
  end

  @doc false
  # Public for the manual-probe page so the synchronous reproducer
  # uses the same headers the worker would. Not part of the stable API.
  def pdp_headers(%Config{site_url: site}) do
    [
      {"user-agent", @user_agent},
      {"accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
      {"accept-language", "es-CL,es;q=0.9,en;q=0.8"},
      {"accept-encoding", "gzip, deflate, br, zstd"},
      {"referer", site <> "/"},
      {"sec-fetch-dest", "document"},
      {"sec-fetch-mode", "navigate"},
      {"sec-fetch-site", "same-origin"}
    ]
  end

  # Parses a Cencosud PDP's JSON-LD payload. The page typically embeds
  # 2–3 `application/ld+json` blocks; the one we want has either a
  # top-level `@type: "Product"` or a `@graph` containing it. The
  # Product node carries `name`, `sku`, `gtin`/`gtin8` (EAN), `brand`,
  # `image`, and an `offers` Offer with `price` (CLP int as string)
  # and `availability`. The breadcrumb (separate `BreadcrumbList`
  # node) gives us the category path for the listing.
  @doc false
  def parse_pdp(%Config{} = cfg, html, url) when is_binary(html) and is_binary(url) do
    blocks = extract_ld_json(html)

    {product, breadcrumb} =
      Enum.reduce(blocks, {nil, nil}, fn block, {p, b} ->
        case Jason.decode(block) do
          {:ok, decoded} ->
            nodes = ld_nodes(decoded)

            new_p = p || Enum.find(nodes, &(Map.get(&1, "@type") == "Product"))
            new_b = b || Enum.find(nodes, &(Map.get(&1, "@type") == "BreadcrumbList"))
            {new_p, new_b}

          {:error, _} ->
            {p, b}
        end
      end)

    case product do
      nil ->
        {:error, :no_product_jsonld}

      %{} = node ->
        listing = listing_from_jsonld(cfg, node, breadcrumb, url)

        # Some sitemap URLs point at PDPs whose Product node has no
        # name/sku and an "undefined" price — products that were
        # delisted but stayed in the sitemap. Skip them rather than
        # persist nil-everywhere rows; sitemap drift is normal and
        # not worth a louder warning per URL.
        if listing.name in [nil, ""] do
          {:error, :stale_pdp}
        else
          {:ok, listing}
        end
    end
  end

  defp extract_ld_json(html) do
    Regex.scan(
      ~r{<script[^>]*type=["']application/ld\+json["'][^>]*>(.*?)</script>}s,
      html,
      capture: :all_but_first
    )
    |> Enum.map(fn [b] -> b end)
  end

  # Some Cencosud PDPs emit nested or empty lists inside `@graph`
  # (reviews/breadcrumb placeholders that didn't render), so we flatten
  # and drop anything that isn't a map. Also handle top-level JSON-LD
  # arrays (multiple decorations in a single block).
  defp ld_nodes(%{"@graph" => graph}) when is_list(graph),
    do: graph |> List.flatten() |> Enum.filter(&is_map/1)

  defp ld_nodes(%{} = node), do: [node]

  defp ld_nodes(list) when is_list(list),
    do: list |> List.flatten() |> Enum.filter(&is_map/1)

  defp ld_nodes(_), do: []

  defp listing_from_jsonld(%Config{} = cfg, %{} = product, breadcrumb, url) do
    offer = first_offer(product["offers"])
    price = price_int(offer["price"])

    %Listing{
      chain: cfg.chain,
      chain_sku: to_string_if_present(product["sku"]),
      chain_product_id: to_string_if_present(product["sku"]),
      ean: pick_ean(product),
      name: product["name"],
      brand: brand_name(product["brand"]),
      image_url: first_image(product["image"]),
      pdp_url: url,
      category_path: breadcrumb_path(breadcrumb),
      regular_price: price,
      promo_price: nil,
      promotions: %{}
    }
  end

  defp first_offer(%{"@type" => "Offer"} = offer), do: offer
  defp first_offer([%{} = offer | _]), do: offer
  defp first_offer(_), do: %{}

  defp pick_ean(%{"gtin13" => v}) when is_binary(v) and v != "", do: v
  defp pick_ean(%{"gtin" => v}) when is_binary(v) and v != "", do: v
  defp pick_ean(%{"gtin8" => v}) when is_binary(v) and v != "", do: v
  defp pick_ean(%{"gtin12" => v}) when is_binary(v) and v != "", do: v
  defp pick_ean(_), do: nil

  defp brand_name(%{"name" => name}) when is_binary(name), do: name
  defp brand_name(name) when is_binary(name), do: name
  defp brand_name(_), do: nil

  defp first_image([url | _]) when is_binary(url), do: url
  defp first_image(url) when is_binary(url), do: url
  defp first_image(_), do: nil

  defp breadcrumb_path(%{"itemListElement" => items}) when is_list(items) do
    items
    |> Enum.sort_by(&Map.get(&1, "position", 0))
    # Drop position 1 (the homepage) and the last entry (the product
    # itself). What's left is the category trail leading to this PDP.
    |> Enum.drop(1)
    |> Enum.drop(-1)
    |> Enum.map(&Map.get(&1, "name"))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      names -> Enum.join(names, " > ")
    end
  end

  defp breadcrumb_path(_), do: nil

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
    Http.get(url, chain: cfg.chain, headers: headers_for(cfg), profile: profile)
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

  defp price_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      {n, "."} when n > 0 -> n
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
