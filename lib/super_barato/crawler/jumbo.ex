defmodule SuperBarato.Crawler.Jumbo do
  @moduledoc """
  Jumbo adapter. Categories are discovered by parsing the home page's
  `window.__renderData` blob (the menu Jumbo's SPA actually renders).
  Two earlier sources turned out to be too stale: the XML category
  sitemap (`assets.jumbo.cl/sitemap/category-0.xml`) and the BFF
  `categories.json` both keep entries for slugs that 301 to a new
  taxonomy or 410 outright. `__renderData` is the only source that
  matches what's currently displayed in the navigation menu.

  Products are still discovered via the public product sitemap and
  individual PDPs parsed for JSON-LD price data; the old VTEX
  `?sc=*` API path is gone.
  """

  @behaviour SuperBarato.Crawler.Chain

  alias SuperBarato.Crawler.{Category, Cencosud, Http, Scope}

  @home_url "https://www.jumbo.cl/"

  @config %Cencosud.Config{
    chain: :jumbo,
    site_url: "https://www.jumbo.cl",
    # Kept for completeness / Cencosud.Config's enforce_keys, but no
    # longer the source of category discovery — see `discover_categories/0`.
    categories_url: "https://assets.jumbo.cl/sitemap/category-0.xml",
    sales_channel: "1",
    sitemap_index: "https://assets.jumbo.cl/sitemap.xml"
  }

  @doc "Exposed so `Cencosud.ProductProducer` can fetch the sitemap layout."
  def cencosud_config, do: @config

  @impl true
  def id, do: @config.chain

  @impl true
  def refresh_identifier, do: :chain_sku

  @impl true
  def handle_task({:discover_categories, %{parent: _}}),
    do: discover_categories()

  def handle_task({:fetch_product_pdp, %{url: url}}),
    do: Cencosud.fetch_product_pdp(@config, url)

  def handle_task(other), do: {:error, {:unsupported_task, other}}

  # Stage 1 — categories from `window.__renderData`

  defp discover_categories do
    with {:ok, html} <- fetch_html(@home_url),
         {:ok, data} <- extract_render_data(html),
         {:ok, cats} <- categories_from_render_data(data) do
      {:ok, cats |> then(&Scope.filter(:jumbo, &1)) |> mark_leaves()}
    end
  end

  defp fetch_html(url) do
    case Http.get(url, chain: :jumbo) do
      {:ok, %Http.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Http.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, _} = err -> err
    end
  end

  @doc false
  # `window.__renderData = "<json-encoded-string>";` — parsing happens
  # twice: once to decode the JSON-string literal, then to parse the
  # actual JSON object.
  def extract_render_data(html) when is_binary(html) do
    case Regex.run(~r/window\.__renderData\s*=\s*("(?:[^"\\]|\\.)*");/s, html) do
      [_, quoted] ->
        with {:ok, inner} <- Jason.decode(quoted),
             {:ok, data} <- Jason.decode(inner) do
          {:ok, data}
        else
          _ -> {:error, :malformed_render_data}
        end

      _ ->
        {:error, :no_render_data}
    end
  end

  @doc false
  def categories_from_render_data(data) do
    case get_in(data, ["menu", "acf", "items"]) do
      items when is_list(items) -> {:ok, walk_items(items, 1, nil)}
      _ -> {:error, :no_menu}
    end
  end

  # Recursively flatten the nested `items` tree into `%Category{}`
  # records. URL-less entries are skipped.
  defp walk_items(items, level, parent_slug) do
    Enum.flat_map(items, fn item ->
      slug = url_to_slug(item["url"])
      title = item["title"]

      cond do
        not (is_binary(slug) and is_binary(title)) ->
          # Promotional shells without a usable URL — skip.
          children = item["items"] || []
          walk_items(children, level, parent_slug)

        true ->
          cat = %Category{
            chain: :jumbo,
            slug: slug,
            name: title,
            parent_slug: parent_slug,
            level: level,
            external_id: nil
          }

          [cat | walk_items(item["items"] || [], level + 1, slug)]
      end
    end)
  end

  defp url_to_slug("/" <> rest) do
    case String.split(rest, "?", parts: 2) |> List.first() do
      "" -> nil
      slug -> String.trim_trailing(slug, "/")
    end
  end

  defp url_to_slug(_), do: nil

  defp mark_leaves(cats) do
    parents = cats |> Enum.map(& &1.parent_slug) |> Enum.reject(&is_nil/1) |> MapSet.new()
    Enum.map(cats, &%{&1 | is_leaf: not MapSet.member?(parents, &1.slug)})
  end
end
