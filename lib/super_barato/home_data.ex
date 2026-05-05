defmodule SuperBarato.HomeData do
  @moduledoc """
  Data builders for the public home page (the index view, with no
  search query and no category filter). Produces fully-rendered
  preview maps — products with thumbnails + per-chain prices — so
  the LiveView can render them without doing any DB work itself.

  Used by `SuperBarato.HomeCache`, which calls these functions on
  a 2-minute refresh cycle and stashes the results in ETS.
  """

  alias SuperBarato.{Catalog, Linker, Thumbnails}

  @chain_names %{
    "jumbo" => "Jumbo",
    "santa_isabel" => "Santa Isabel",
    "unimarc" => "Unimarc",
    "lider" => "Líder",
    "tottus" => "Tottus",
    "acuenta" => "Acuenta"
  }

  @doc """
  Per-app_category preview bands. Each band carries up to `per_cat`
  cross-chain products with thumbnails + prices already resolved.
  Categories with zero matching products are dropped.
  """
  def category_previews(per_cat \\ 6) do
    bands = Catalog.category_previews(per_cat)
    pids = bands |> Enum.flat_map(& &1.products) |> Enum.map(& &1.id)
    listings = Linker.listings_by_product_ids(pids)

    for band <- bands do
      products =
        Enum.map(band.products, fn p ->
          %{
            id: p.id,
            name: p.canonical_name,
            brand: p.brand,
            # Cards / drag-ghost / cart all consume `image_url` —
            # ship the R2 thumbnail there. `original_image_url` is
            # the raw chain-CDN URL, only used by the product
            # detail popover for a higher-res hero image.
            image_url: Thumbnails.thumbnail_url(p),
            original_image_url: p.image_url,
            prices: product_prices(Map.get(listings, p.id, []))
          }
        end)

      %{slug: band.slug, name: band.name, products: products}
    end
  end

  @doc """
  Most-popular terms across all products — drives the suggestion
  chips on the index. Per-category and search-scoped terms are
  fetched on demand from `Catalog.popular_terms/1`.
  """
  def popular_terms(n \\ 24) do
    Catalog.popular_terms(n: n)
  end

  @doc """
  Build the per-chain price rows for one product from its linked
  listings. Drops listings with no current price, picks the cheapest
  per chain, sorts cheapest-first, and marks the lowest row when
  there are 2+ chains so the card can highlight it.
  """
  def product_prices(listings) do
    rows =
      listings
      |> Enum.reject(&is_nil(&1.current_regular_price))
      |> Enum.map(fn l ->
        reg = l.current_regular_price
        promo = l.current_promo_price
        promo? = is_integer(promo) and is_integer(reg) and promo < reg
        eff = if promo?, do: promo, else: reg
        %{chain: l.chain, price: eff, promo?: promo?, url: l.pdp_url}
      end)
      |> Enum.group_by(& &1.chain)
      |> Enum.map(fn {_chain, rows} -> Enum.min_by(rows, & &1.price) end)
      |> Enum.sort_by(& &1.price)
      |> Enum.map(fn row -> Map.put(row, :name, Map.get(@chain_names, row.chain, row.chain)) end)

    case rows do
      [_only] ->
        Enum.map(rows, &Map.put(&1, :lowest?, false))

      [] ->
        []

      _ ->
        min_price = rows |> Enum.map(& &1.price) |> Enum.min()
        Enum.map(rows, &Map.put(&1, :lowest?, &1.price == min_price))
    end
  end
end
