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

  alias SuperBarato.Catalog

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

  # Category discovery: upsert all categories from payload.
  defp persist(_state, {:discover_categories, _meta}, categories) when is_list(categories) do
    Enum.each(categories, fn cat ->
      case Catalog.upsert_category(cat) do
        {:ok, _} -> :ok
        {:error, cs} -> Logger.warning("category upsert failed: #{inspect(cs.errors)}")
      end
    end)
  end

  # Product discovery: upsert all listings returned for this category.
  defp persist(state, {:discover_products, %{slug: slug}}, listings)
       when is_list(listings) do
    Enum.each(listings, fn listing ->
      case Catalog.upsert_listing(listing) do
        {:ok, _} -> :ok
        {:error, cs} -> Logger.warning("listing upsert failed: #{inspect(cs.errors)}")
      end
    end)

    Logger.info("[#{state.chain}] upserted #{length(listings)} listings for category=#{slug}")
  end

  # Price refresh: look up existing listing by identifier, record snapshot.
  defp persist(state, {:fetch_product_info, %{identifiers: _ids}}, listings)
       when is_list(listings) do
    field = state.adapter.refresh_identifier()

    Enum.each(listings, fn info ->
      with id when is_binary(id) <- Map.get(info, field),
           listing when not is_nil(listing) <- lookup_by(state.chain, field, id) do
        Catalog.record_product_info(listing, info)
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
