defmodule SuperBarato.Crawler.Chain.Results do
  @moduledoc """
  Persistence sink for a chain. Receives `{task, payload}` casts from
  the Worker, dispatches to the right Catalog function based on task
  type, and (for discovery) enqueues follow-up tasks if the adapter's
  tree walk needs more than one request.

  Fire-and-forget: the Worker doesn't wait for persistence to finish.
  On a DB failure the row is lost; Cron will re-queue it on the next
  scheduled pass because the Catalog row's `last_*_at` timestamp won't
  have been updated.
  """

  use GenServer

  require Logger

  alias SuperBarato.{Catalog, PriceLog}
  alias SuperBarato.Linker

  def start_link(opts) do
    chain = Keyword.fetch!(opts, :chain)
    GenServer.start_link(__MODULE__, opts, name: via(chain))
  end

  @doc """
  Hands a completed task's payload to the Results sink. Non-blocking —
  Worker moves on immediately.
  """
  def record(chain, task, payload) do
    GenServer.cast(via(chain), {:record, task, payload})
  end

  def child_spec(opts) do
    chain = Keyword.fetch!(opts, :chain)

    %{
      id: {__MODULE__, chain},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  defp via(chain),
    do: {:via, Registry, {SuperBarato.Crawler.Registry, {__MODULE__, chain}}}

  @impl true
  def init(opts) do
    chain = Keyword.fetch!(opts, :chain)
    adapter = Keyword.get(opts, :adapter) || SuperBarato.Crawler.adapter(chain)
    Logger.metadata(chain: chain, role: :results)
    {:ok, %{chain: chain, adapter: adapter}}
  end

  @impl true
  def handle_cast({:record, task, payload}, state) do
    try do
      persist(state, task, payload)
    rescue
      err ->
        Logger.warning("results: #{state.chain} persist failed: #{inspect(err)}")
    end

    {:noreply, state}
  end

  @doc """
  Synchronous version of `record/3`. Applies the same persistence path
  (upsert + PriceLog append) without going through the GenServer. Used
  by Mix tasks (`crawler.trigger`) that want a blocking, standalone
  run without a full pipeline.
  """
  def persist_sync(chain, adapter, task, payload) do
    persist(%{chain: chain, adapter: adapter}, task, payload)
  end

  # Category discovery: upsert all categories from payload.
  defp persist(_state, {:discover_categories, _meta}, categories) when is_list(categories) do
    Enum.each(categories, fn cat ->
      case Catalog.upsert_category(cat) do
        {:ok, _} -> :ok
        {:error, cs} -> Logger.warning("category upsert failed: #{inspect(cs.errors)}")
      end
    end)
  end

  # Product discovery: upsert every listing and append a price
  # observation to the per-product file log.
  defp persist(state, {:discover_products, %{slug: slug}}, listings)
       when is_list(listings) do
    Enum.each(listings, &persist_listing/1)

    # Per-category log lives at :debug because a full daily product
    # walk fires this once per leaf category (1000s of times). The
    # interesting info is the producer-level start/done summary.
    Logger.debug("[#{state.chain}] upserted #{length(listings)} listings for category=#{slug}")
  end

  # Sitemap-driven single-PDP fetch (Cencosud chains). The adapter
  # returns a one-element listing list; upsert it the same way the
  # category-batch path does. PriceLog.append captures the price
  # observation per call.
  defp persist(_state, {:fetch_product_pdp, _meta}, listings) when is_list(listings) do
    Enum.each(listings, &persist_listing/1)
  end

  # Ad-hoc single-SKU refresh: look up existing listing by identifier,
  # update current_* and append to the log.
  defp persist(state, {:fetch_product_info, %{identifiers: _ids}}, listings)
       when is_list(listings) do
    field = state.adapter.refresh_identifier()

    Enum.each(listings, fn info ->
      with id when is_binary(id) <- Map.get(info, field),
           listing when not is_nil(listing) <- lookup_by(state.chain, field, id),
           {:ok, _} <- Catalog.record_product_info(listing, info) do
        log_price(info)
      else
        _ -> :skip
      end
    end)
  end

  defp persist(state, task, payload) do
    Logger.warning(
      "[#{state.chain}] unknown task shape: task=#{inspect(task)} payload=#{inspect(payload, limit: 3)}"
    )
  end

  # Single point that:
  #   1. Upserts the chain_listing.
  #   2. Appends a price observation when the row carries a price.
  #   3. Notifies the Linker on inserts (not updates) so it can
  #      attach this listing to a Product. Updates don't fire — the
  #      link, if any, was decided when the row was first inserted;
  #      EAN drift handling is a separate concern.
  defp persist_listing(listing) do
    case Catalog.upsert_listing(listing) do
      {:ok, :inserted, %{id: id}} ->
        log_price(listing)
        Linker.Worker.link_listing(id)

      {:ok, :updated, _row} ->
        log_price(listing)

      {:error, cs} ->
        Logger.warning("listing upsert failed: #{inspect(cs.errors)}")
    end
  end

  # Appends a `<unix> <regular> [<promo>]` line to the product's log
  # when the listing carries a usable price. No-op for rows without
  # chain_sku or regular_price (partial payloads shouldn't pollute
  # history).
  defp log_price(%{chain: chain, chain_sku: sku, regular_price: regular} = listing)
       when is_binary(sku) and is_integer(regular) do
    promo =
      case listing do
        %_{promo_price: p} -> p
        %{promo_price: p} -> p
        _ -> nil
      end

    case PriceLog.append(chain, sku, regular, promo) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("price log append failed: #{inspect(reason)}")
    end
  end

  defp log_price(_), do: :skip

  defp lookup_by(chain, :chain_sku, id), do: Catalog.get_listing(chain, id)

  defp lookup_by(chain, :ean, ean) do
    import Ecto.Query
    alias SuperBarato.Catalog.ChainListing
    alias SuperBarato.Repo

    ChainListing
    |> where([l], l.chain == ^to_string(chain) and l.ean == ^ean)
    |> Repo.one()
  end
end
