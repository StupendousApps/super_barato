defmodule SuperBarato.Crawler do
  @moduledoc """
  High-level entry points for the three crawler stages:

    * `run_category_discovery/1` — walks the chain's category tree.
    * `run_product_discovery/1` — enumerates products in each leaf
      category persisted from stage 1.
    * `run_price_refresh/1` — refreshes prices for active listings
      using their EANs.

  All three route HTTP through the chain's `RateLimiter`, so they share
  a single politeness budget regardless of which runs when.
  """

  require Logger

  alias SuperBarato.Catalog

  @adapters %{
    unimarc: SuperBarato.Crawler.Unimarc,
    jumbo: SuperBarato.Crawler.Jumbo
  }

  def adapter(chain) when is_atom(chain), do: Map.fetch!(@adapters, chain)

  def known_chains, do: Map.keys(@adapters)

  # Stage 1

  @doc """
  Runs stage 1 for a chain. Upserts every discovered category.
  Returns `{:ok, count}`.
  """
  def run_category_discovery(chain) when is_atom(chain) do
    mod = adapter(chain)
    Logger.info("categories: #{chain} starting")

    case mod.discover_categories() do
      {:ok, categories} ->
        count = persist_categories(categories)
        Logger.info("categories: #{chain} done (#{count} upserted)")
        {:ok, count}

      {:error, reason} = err ->
        Logger.warning("categories: #{chain} failed: #{inspect(reason)}")
        err
    end
  end

  defp persist_categories(categories) do
    Enum.reduce(categories, 0, fn cat, acc ->
      case Catalog.upsert_category(cat) do
        {:ok, _} ->
          acc + 1

        {:error, changeset} ->
          Logger.warning("category upsert failed: #{inspect(changeset.errors)}")
          acc
      end
    end)
  end

  # Stage 2

  @doc """
  Runs stage 2 for a chain: walks every leaf category stored in the DB
  and upserts listings. Returns `{:ok, count}`.
  """
  def run_product_discovery(chain) when is_atom(chain) do
    mod = adapter(chain)
    leaves = Catalog.leaf_categories(chain)
    Logger.info("products: #{chain} starting (#{length(leaves)} leaf categories)")

    count =
      Enum.reduce(leaves, 0, fn cat, acc ->
        case mod.discover_products(cat.slug) do
          {:ok, listings} ->
            acc + persist_listings(listings)

          {:error, reason} ->
            Logger.warning("products: #{chain} category=#{cat.slug} failed: #{inspect(reason)}")

            acc
        end
      end)

    Logger.info("products: #{chain} done (#{count} listings)")
    {:ok, count}
  end

  defp persist_listings(listings) do
    Enum.reduce(listings, 0, fn %SuperBarato.Crawler.Listing{} = listing, acc ->
      case Catalog.upsert_listing(listing) do
        {:ok, _} ->
          acc + 1

        {:error, changeset} ->
          Logger.warning("listing upsert failed: #{inspect(changeset.errors)}")
          acc
      end
    end)
  end

  # Stage 3

  @doc """
  Runs stage 3 for a chain: fetches fresh info for active listings with
  EANs, updates current prices, appends a price snapshot per listing.
  """
  def run_price_refresh(chain) when is_atom(chain) do
    mod = adapter(chain)
    field = mod.refresh_identifier()
    listings = Catalog.active_listings_for_refresh(chain, field)
    by_id = Map.new(listings, &{Map.fetch!(&1, field), &1})
    ids = Map.keys(by_id)

    Logger.info("prices: #{chain} refreshing #{length(ids)} listings by #{field}")

    case mod.fetch_product_info(ids) do
      {:ok, infos} ->
        updated =
          Enum.reduce(infos, 0, fn %SuperBarato.Crawler.Listing{} = info, acc ->
            with id when is_binary(id) <- Map.get(info, field),
                 {:ok, listing} <- Map.fetch(by_id, id),
                 {:ok, _} <- Catalog.record_product_info(listing, info) do
              acc + 1
            else
              _ -> acc
            end
          end)

        Logger.info("prices: #{chain} done (#{updated} updated)")
        {:ok, updated}

      {:error, reason} = err ->
        Logger.warning("prices: #{chain} failed: #{inspect(reason)}")
        err
    end
  end
end
