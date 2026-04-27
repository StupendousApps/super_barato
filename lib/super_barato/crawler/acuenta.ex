defmodule SuperBarato.Crawler.Acuenta do
  @moduledoc """
  Acuenta adapter — Walmart Chile's discount supermarket banner,
  storefronted by Instaleap (separate stack from Lider despite the
  shared parent). The PDP is a Next.js SPA so HTML scraping yields
  nothing useful; all listing data comes from a single GraphQL
  endpoint.

  ## Endpoint

      POST https://nextgentheadless.instaleap.io/api/v3
      Content-Type: application/json
      (no auth header — the tenant id rides inside the GraphQL input)

  ## Operations used

    * `getCategory(getCategoryInput: {clientId, storeReference})` —
      returns a recursive category tree we walk to populate the
      `categories` table.
    * `getProductsByCategory(getProductsByCategoryInput: {clientId,
       storeReference, categoryReference, currentPage, pageSize})` —
      paginated product listings per leaf category. Returns
      `{name, brand, price, previousPrice, ean[], sku, slug,
       photosUrl[]}` per product. EAN is an **array** because
      Acuenta sometimes carries multi-EAN entries.

  ## Identifiers

    * `clientId` — `"SUPER_BODEGA"`. Acuenta's old retail brand
      ("Super Bodega aCuenta") still anchors the tenant id inside
      Instaleap.
    * `storeReference` — `"511"`. Picked from
      `getStoresNearbyByCoords(coordinates: {-33.45, -70.67})` —
      Av. San Fermin Vivaceta 827, Independencia, the closest store
      to Santiago city center. Catalog appears to be the same across
      stores so any single one works for crawling.

  ## Slug shape

  Slugs are stored as `"<segment-name>/<segment-ref>"` joined with
  `/` for nested categories — e.g.
  `"despensa/05/arroz-legumbres-y-semillas/0502/arroz/050201"`. The
  trailing reference is the unique numeric category id we feed back
  to `getProductsByCategory`. The leading name is humanized for
  display + slug-blacklist matching.

  ## Blacklist semantics

  Top-level segment matches are routed through
  `SuperBarato.Crawler.Scope` like every other chain, so adding
  `"hogar-entretencion-y-tecnologia"` to the Acuenta blacklist drops
  the whole homewares branch.
  """

  @behaviour SuperBarato.Crawler.Chain

  alias SuperBarato.Crawler.{Category, Http, Listing, Scope}
  alias SuperBarato.Linker.Identity

  require Logger

  @chain :acuenta
  @endpoint "https://nextgentheadless.instaleap.io/api/v3"
  @client_id "SUPER_BODEGA"
  @store_reference "511"
  @page_size 100

  @impl true
  def id, do: @chain

  @impl true
  def refresh_identifier, do: :ean

  @impl true
  def handle_task({:discover_categories, %{parent: _}}), do: discover_categories()

  def handle_task({:discover_products, %{slug: slug}}), do: discover_products(slug)

  def handle_task(other), do: {:error, {:unsupported_task, other}}

  ## Stage 1 — categories

  @categories_query """
  query GetCategoryTree($i: GetCategoryInput!) {
    getCategory(getCategoryInput: $i) {
      name reference slug level path hasChildren
      subCategories {
        name reference slug level path hasChildren
        subCategories {
          name reference slug level path hasChildren
          subCategories {
            name reference slug level path hasChildren
          }
        }
      }
    }
  }
  """

  defp discover_categories do
    body = encode_query(@categories_query, %{i: input(%{})})

    case Http.post(@endpoint, headers: json_headers(), body: body, chain: @chain) do
      {:ok, %Http.Response{status: 200, body: resp_body}} ->
        case Jason.decode(resp_body) do
          {:ok, %{"data" => %{"getCategory" => roots}}} when is_list(roots) ->
            {:ok, parse_category_tree(roots)}

          {:ok, %{"errors" => errs}} ->
            {:error, {:graphql_errors, errs}}

          {:error, reason} ->
            {:error, {:json_decode, reason}}
        end

      {:ok, resp} ->
        if Http.blocked?(resp), do: :blocked, else: {:error, {:http_status, resp.status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # Public for unit testing against captured fixtures.
  def parse_category_tree(roots) when is_list(roots) do
    roots
    |> Enum.flat_map(&walk_category(&1, _parent_segments = []))
    |> then(&Scope.filter(@chain, &1))
    |> mark_leaves()
  end

  defp walk_category(%{} = node, parent_segments) do
    name = Map.get(node, "name") || ""
    reference = Map.get(node, "reference") || ""

    segment = humanize_to_slug(name) <> "/" <> reference
    segments = parent_segments ++ [segment]
    slug = Enum.join(segments, "/")
    parent_slug = if parent_segments == [], do: nil, else: Enum.join(parent_segments, "/")
    level = Map.get(node, "level") || length(segments)

    self =
      %Category{
        chain: @chain,
        external_id: reference,
        slug: slug,
        name: name,
        parent_slug: parent_slug,
        level: level
      }

    children =
      case Map.get(node, "subCategories") do
        list when is_list(list) -> Enum.flat_map(list, &walk_category(&1, segments))
        _ -> []
      end

    [self | children]
  end

  # "Frescos y Lácteos" → "frescos-y-lacteos". Strips combining marks
  # (NFD) so accented characters end up as plain ASCII; non-alnum
  # characters become hyphens; comma in the rare "Hogar, …" name is
  # collapsed too.
  defp humanize_to_slug(name) when is_binary(name) do
    name
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.replace(~r/[^a-z0-9\s\-]/u, " ")
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.join("-")
  end

  defp humanize_to_slug(_), do: ""

  defp mark_leaves(categories) do
    parents =
      categories |> Enum.map(& &1.parent_slug) |> Enum.reject(&is_nil/1) |> MapSet.new()

    Enum.map(categories, fn c -> %{c | is_leaf: not MapSet.member?(parents, c.slug)} end)
  end

  ## Stage 2 — products

  @products_query """
  query GetProductsByCategory($i: GetProductsByCategoryInput!) {
    getProductsByCategory(getProductsByCategoryInput: $i) {
      category {
        name
        reference
        products {
          name brand price previousPrice
          ean sku slug photosUrl
          categoriesData { name reference path level }
        }
      }
      pagination { page pages total { value relation } }
    }
  }
  """

  defp discover_products(slug) when is_binary(slug) do
    case category_reference_from_slug(slug) do
      nil ->
        {:error, {:bad_slug, slug}}

      reference ->
        fetch_all_pages(reference, slug, _page = 1, [])
    end
  end

  defp fetch_all_pages(reference, slug, page, acc) do
    vars = %{
      i:
        input(%{
          "categoryReference" => reference,
          "currentPage" => page,
          "pageSize" => @page_size
        })
    }

    body = encode_query(@products_query, vars)

    case Http.post(@endpoint, headers: json_headers(), body: body, chain: @chain) do
      {:ok, %Http.Response{status: 200, body: resp_body}} ->
        case Jason.decode(resp_body) do
          {:ok, %{"data" => %{"getProductsByCategory" => payload}}} ->
            handle_products_page(payload, reference, slug, page, acc)

          {:ok, %{"errors" => errs}} ->
            {:error, {:graphql_errors, errs}}

          {:error, reason} ->
            {:error, {:json_decode, reason}}
        end

      {:ok, resp} ->
        if Http.blocked?(resp), do: :blocked, else: {:error, {:http_status, resp.status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_products_page(payload, reference, slug, page, acc) do
    products = get_in(payload, ["category", "products"]) || []
    pagination = Map.get(payload, "pagination") || %{}
    pages = Map.get(pagination, "pages", 1)

    listings = Enum.map(products, &parse_listing(&1, slug))
    new_acc = acc ++ listings

    cond do
      products == [] -> {:ok, new_acc}
      page >= pages -> {:ok, new_acc}
      true -> fetch_all_pages(reference, slug, page + 1, new_acc)
    end
  end

  @doc false
  # Public for unit testing against captured fixtures.
  def parse_products_response(%{"data" => %{"getProductsByCategory" => payload}}, slug) do
    products = get_in(payload, ["category", "products"]) || []
    Enum.map(products, &parse_listing(&1, slug))
  end

  defp parse_listing(%{} = product, category_slug) do
    sku = to_string_if_present(Map.get(product, "sku"))
    eans = Map.get(product, "ean") || []

    # Build identifiers from every id-shaped field — sku and any
    # EAN we received. The Linker treats this as the row's
    # identity-key contribution; multi-EAN products produce a
    # different identifiers_key than a single-EAN equivalent.
    identifiers = identifiers_for(sku, eans)

    {regular, promo} =
      pair_prices(Map.get(product, "previousPrice"), Map.get(product, "price"))

    %Listing{
      chain: @chain,
      chain_sku: sku,
      chain_product_id: sku,
      ean: List.first(eans),
      identifiers_key: Identity.encode(identifiers),
      raw: %{"product" => product},
      name: Map.get(product, "name"),
      brand: Map.get(product, "brand"),
      image_url: first_string(Map.get(product, "photosUrl")),
      pdp_url: pdp_url(Map.get(product, "slug")),
      category_path: category_slug,
      regular_price: regular,
      promo_price: promo,
      promotions: %{}
    }
  end

  # Parser stores what the chain volunteered, period. When Instaleap
  # gives us both `previousPrice` and `price`, both columns get
  # populated even if they're equal — the display layer decides
  # whether to render as a promo.
  defp pair_prices(previous, current) do
    prev = price_int(previous)
    curr = price_int(current)

    cond do
      is_integer(prev) and is_integer(curr) -> {prev, curr}
      is_integer(prev) -> {prev, nil}
      is_integer(curr) -> {curr, nil}
      true -> {nil, nil}
    end
  end

  defp identifiers_for(sku, eans) when is_list(eans) do
    base =
      case sku do
        nil -> %{}
        "" -> %{}
        s -> %{"sku" => s}
      end

    eans
    |> Enum.with_index()
    |> Enum.reduce(base, fn {ean, idx}, acc ->
      key = if idx == 0, do: "ean", else: "ean#{idx + 1}"
      Map.put(acc, key, to_string(ean))
    end)
  end

  defp pdp_url(nil), do: nil
  defp pdp_url(""), do: nil
  defp pdp_url(slug), do: "https://www.acuenta.cl/p/" <> slug

  defp first_string([s | _]) when is_binary(s) and s != "", do: s
  defp first_string(s) when is_binary(s) and s != "", do: s
  defp first_string(_), do: nil

  defp price_int(n) when is_integer(n) and n > 0, do: n
  defp price_int(n) when is_float(n) and n > 0, do: round(n)
  defp price_int(_), do: nil

  defp to_string_if_present(nil), do: nil
  defp to_string_if_present(""), do: nil
  defp to_string_if_present(s) when is_binary(s), do: s
  defp to_string_if_present(n) when is_integer(n), do: Integer.to_string(n)
  defp to_string_if_present(other), do: to_string(other)

  # Slug → trailing categoryReference. For
  # `"despensa/05/arroz-legumbres-y-semillas/0502/arroz/050201"`,
  # returns `"050201"`.
  @doc false
  def category_reference_from_slug(slug) when is_binary(slug) do
    case slug |> String.split("/", trim: true) |> List.last() do
      nil -> nil
      "" -> nil
      ref -> ref
    end
  end

  def category_reference_from_slug(_), do: nil

  ## Helpers

  defp input(extra) when is_map(extra) do
    Map.merge(
      %{
        "clientId" => @client_id,
        "storeReference" => @store_reference
      },
      extra
    )
  end

  defp encode_query(query, variables) do
    Jason.encode!(%{query: query, variables: variables})
  end

  defp json_headers do
    [
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]
  end
end
