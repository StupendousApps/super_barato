defmodule SuperBarato.Crawler do
  @moduledoc """
  High-level entry points for the two crawler processes:

    * Discovery — walks seed categories, upserts listings.
    * Price fetch — refreshes prices for active listings.

  Both paths route HTTP through the chain's shared `RateLimiter`.
  """

  require Logger

  alias SuperBarato.Catalog

  @adapters %{
    unimarc: SuperBarato.Crawler.Unimarc
  }

  def adapter(chain) when is_atom(chain), do: Map.fetch!(@adapters, chain)

  def known_chains, do: Map.keys(@adapters)

  @doc """
  Runs discovery for a chain across all its seed categories.
  Returns `{:ok, inserted_or_updated_count}`.
  """
  def run_discovery(chain) when is_atom(chain) do
    mod = adapter(chain)
    categories = mod.seed_categories()

    Logger.info("discovery: #{chain} starting (#{length(categories)} categories)")

    count =
      Enum.reduce(categories, 0, fn category, acc ->
        case mod.discover_category(category) do
          {:ok, listings} ->
            acc + persist_listings(listings)

          {:error, reason} ->
            Logger.warning(
              "discovery: #{chain} category=#{inspect(category)} failed: #{inspect(reason)}"
            )

            acc
        end
      end)

    Logger.info("discovery: #{chain} done (#{count} listings)")
    {:ok, count}
  end

  @doc """
  Refreshes prices for every active listing of `chain`.
  """
  def run_price_fetch(chain) when is_atom(chain) do
    mod = adapter(chain)
    listings = Catalog.active_listings(chain)
    by_sku = Map.new(listings, &{&1.chain_sku, &1})

    Logger.info("prices: #{chain} refreshing #{map_size(by_sku)} listings")

    case mod.fetch_prices(Map.keys(by_sku)) do
      {:ok, price_rows} ->
        updated =
          Enum.reduce(price_rows, 0, fn row, acc ->
            case Map.fetch(by_sku, row.chain_sku) do
              {:ok, listing} ->
                case Catalog.record_price(listing, row) do
                  {:ok, _} -> acc + 1
                  _ -> acc
                end

              :error ->
                acc
            end
          end)

        Logger.info("prices: #{chain} done (#{updated} updated)")
        {:ok, updated}

      {:error, reason} = err ->
        Logger.warning("prices: #{chain} failed: #{inspect(reason)}")
        err
    end
  end

  defp persist_listings(listings) do
    Enum.reduce(listings, 0, fn attrs, acc ->
      case Catalog.upsert_listing(attrs) do
        {:ok, _} ->
          acc + 1

        {:error, changeset} ->
          Logger.warning("listing upsert failed: #{inspect(changeset.errors)}")
          acc
      end
    end)
  end
end
