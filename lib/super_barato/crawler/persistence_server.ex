defmodule SuperBarato.Crawler.PersistenceServer do
  @moduledoc """
  Singleton DB writer for the entire crawler pipeline. Receives
  `{chain, task, payload}` casts from the per-chain `FetcherServer`s,
  dispatches to the right Catalog function, and runs the product-link
  step inline as plain `Linker` function calls.

  One process means one DB writer. SQLite serializes writes through a
  single lock anyway; funneling all crawler writes through one
  GenServer turns that physical bottleneck into a clean queue and
  eliminates the `Database busy` cascades we hit when six per-chain
  Results plus a separate linker GenServer all raced for the lock
  under deferred-mode upgrades.

  Fire-and-forget: the FetcherServer doesn't wait for persistence to
  finish. On a DB failure the row is lost; the SchedulerServer will
  re-queue it on the next scheduled pass because the Catalog row's
  `last_*_at` timestamp won't have been updated.
  """

  use GenServer

  require Logger

  alias SuperBarato.{Catalog, Linker, PriceLog}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Hands a completed task's payload to the persistence sink.
  Non-blocking — the caller (FetcherServer) moves on immediately.
  `chain` is carried in the cast so the singleton can resolve the
  right adapter for chain-scoped work (currently only
  `:fetch_product_info`'s `refresh_identifier`).
  """
  def record(chain, task, payload) do
    GenServer.cast(__MODULE__, {:record, chain, task, payload})
  end

  @doc """
  Live snapshot for the admin runtime view: mailbox depth, total
  records handled since boot, last-handled timestamp, and a rolling
  10-second throughput estimate (records/sec).
  """
  def metrics do
    case Process.whereis(__MODULE__) do
      nil ->
        %{alive: false, mailbox_len: 0, total_handled: 0, last_handled_at: nil, ops_per_sec: 0.0}

      pid ->
        {:message_queue_len, mbox} = Process.info(pid, :message_queue_len)
        state = :sys.get_state(pid)

        %{
          alive: true,
          mailbox_len: mbox,
          total_handled: state.total_handled,
          last_handled_at: state.last_handled_at,
          ops_per_sec: ops_per_sec(state.recent)
        }
    end
  end

  # 10-second rolling-window throughput. `recent` is a list of monotonic
  # millisecond timestamps; we evict anything older than 10 s and
  # divide by the window size.
  @window_ms 10_000

  defp ops_per_sec(recent) do
    now = System.monotonic_time(:millisecond)
    fresh = Enum.take_while(recent, &(now - &1 < @window_ms))
    length(fresh) / (@window_ms / 1000)
  end

  @impl true
  def init(_opts) do
    Logger.metadata(role: :persistence)
    {:ok, %{total_handled: 0, last_handled_at: nil, recent: []}}
  end

  @impl true
  def handle_cast({:record, chain, task, payload}, state) do
    try do
      persist(chain, task, payload, [])
    rescue
      err ->
        Logger.warning("persistence: #{chain} persist failed: #{inspect(err)}")
    end

    now_ms = System.monotonic_time(:millisecond)
    cutoff = now_ms - @window_ms
    recent = [now_ms | Enum.take_while(state.recent, &(&1 > cutoff))]

    {:noreply,
     %{
       state
       | total_handled: state.total_handled + 1,
         last_handled_at: DateTime.utc_now() |> DateTime.truncate(:second),
         recent: recent
     }}
  end

  @doc """
  Synchronous version of `record/3`. Applies the same persistence path
  (upsert + PriceLog append + product link) without going through the
  GenServer. Used by Mix tasks (`crawler.trigger`) that want a
  blocking, standalone run without a full pipeline.

  `adapter` is accepted explicitly so callers can pass a stub during
  tests; falls back to the registered adapter for `chain`.
  """
  def persist_sync(chain, adapter, task, payload) do
    persist(chain, task, payload, adapter: adapter)
  end

  # Category discovery: upsert all categories from payload.
  defp persist(_chain, {:discover_categories, _meta}, categories, _opts)
       when is_list(categories) do
    Enum.each(categories, fn cat ->
      case Catalog.upsert_category(cat) do
        {:ok, _} -> :ok
        {:error, cs} -> Logger.warning("category upsert failed: #{inspect(cs.errors)}")
      end
    end)
  end

  # Product discovery: upsert every listing and append a price
  # observation to the per-product file log.
  defp persist(chain, {:discover_products, %{slug: slug}}, listings, _opts)
       when is_list(listings) do
    Enum.each(listings, &persist_listing/1)

    # Per-category log lives at :debug because a full daily product
    # walk fires this once per leaf category (1000s of times). The
    # interesting info is the producer-level start/done summary.
    Logger.debug("[#{chain}] upserted #{length(listings)} listings for category=#{slug}")
  end

  # Sitemap-driven single-PDP fetch (Cencosud chains). The adapter
  # returns a one-element listing list; upsert it the same way the
  # category-batch path does. PriceLog.append captures the price
  # observation per call.
  defp persist(_chain, {:fetch_product_pdp, _meta}, listings, _opts)
       when is_list(listings) do
    Enum.each(listings, &persist_listing/1)
  end

  # Ad-hoc single-SKU refresh: look up existing listing by identifier,
  # update current_* and append to the log.
  defp persist(chain, {:fetch_product_info, %{identifiers: _ids}}, listings, opts)
       when is_list(listings) do
    adapter = opts[:adapter] || SuperBarato.Crawler.adapter(chain)
    field = adapter.refresh_identifier()

    Enum.each(listings, fn info ->
      with id when is_binary(id) <- Map.get(info, field),
           listing when not is_nil(listing) <- lookup_by(chain, field, id),
           {:ok, _} <- Catalog.record_product_info(listing, info) do
        log_price(info)
      else
        _ -> :skip
      end
    end)
  end

  defp persist(chain, task, payload, _opts) do
    Logger.warning(
      "[#{chain}] unknown task shape: task=#{inspect(task)} payload=#{inspect(payload, limit: 3)}"
    )
  end

  # Single point that:
  #   1. Upserts the chain_listing.
  #   2. Appends a price observation when the row carries a price.
  #   3. Runs the linker inline — plain function call into `Linker`.
  #      Idempotent; a no-op when nothing changed.
  defp persist_listing(listing) do
    case Catalog.upsert_listing(listing) do
      {:ok, action, %{id: id}} when action in [:upserted, :updated] ->
        log_price(listing)
        link_listing(id)

      {:ok, :skipped, _} ->
        # No price on the parsed listing AND no existing row to flip —
        # Catalog refused. Nothing to log, nothing to link. A future
        # refresh that observes a price will create the row cleanly.
        :ok

      {:error, :missing_category_path} ->
        Logger.warning("listing upsert rejected: missing category_path (chain=#{listing.chain} sku=#{listing.chain_sku})")

      {:error, cs} ->
        Logger.warning("listing upsert failed: #{inspect(cs.errors)}")
    end
  end

  defp link_listing(chain_listing_id) do
    Linker.link_listing(chain_listing_id)
  rescue
    err ->
      Logger.warning(
        "linker: failed for chain_listing_id=#{chain_listing_id}: #{inspect(err)}"
      )
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
