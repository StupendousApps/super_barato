defmodule SuperBarato.Crawler.ThumbnailServer do
  @moduledoc """
  Singleton thumbnail downloader. Sits at the tail of the crawler
  pipeline: PersistenceServer enqueues product_ids for which the
  Linker just produced a Product without a `thumbnail` embed;
  this server walks every linked-listing image_url until one
  succeeds, generating variants via `SuperBarato.Thumbnails`
  (a thin facade over the `:stupendous_thumbnails` library).

  One process so we don't hammer chain CDNs or R2 with concurrent
  uploads. Fire-and-forget — failures are logged and dropped; the
  next time the same Product passes through ingest (or `mix
  thumbnails.backfill`) it'll be retried.
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias SuperBarato.Catalog.{ChainListing, Product}
  alias SuperBarato.Linker.ProductListing
  alias SuperBarato.{Repo, Thumbnails}
  alias StupendousThumbnails.Image

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Hand a product_id to the thumbnail sink. Non-blocking. The server
  re-checks `thumbnail_key` and skips if another path already
  populated it (race between two listings of the same product).
  """
  def enqueue(product_id) when is_integer(product_id) do
    GenServer.cast(__MODULE__, {:enqueue, product_id})
  end

  @doc """
  Synchronous variant for tests / Mix tasks. Bypasses the GenServer
  and runs `Thumbnails.ensure/1` inline.
  """
  def enqueue_sync(product_id) when is_integer(product_id) do
    do_thumbnail(product_id)
  end

  @doc """
  Live snapshot for the admin runtime view. Mirrors
  `PersistenceServer.metrics/0`'s shape.
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

  @window_ms 10_000

  defp ops_per_sec(recent) do
    now = System.monotonic_time(:millisecond)
    fresh = Enum.take_while(recent, &(now - &1 < @window_ms))
    length(fresh) / (@window_ms / 1000)
  end

  @impl true
  def init(_opts) do
    Logger.metadata(role: :thumbnails)
    {:ok, %{total_handled: 0, last_handled_at: nil, recent: []}}
  end

  @impl true
  def handle_cast({:enqueue, product_id}, state) do
    try do
      do_thumbnail(product_id)
    rescue
      err ->
        Logger.warning("thumbnails: product=#{product_id} failed: #{inspect(err)}")
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

  defp do_thumbnail(product_id) do
    case Repo.get(Product, product_id) do
      nil ->
        :skip

      %Product{thumbnail: %Image{variants: [_ | _]}} ->
        :skip

      %Product{} = product ->
        try_candidate_urls(product, candidate_urls(product))
    end
  end

  # Walk every candidate image URL until one produces a usable
  # thumbnail. A chain CDN may return 404 / hotlink-block / a corrupt
  # body for a particular listing's image while another listing of
  # the same product serves the asset cleanly — falling through the
  # whole list dramatically improves coverage.
  defp try_candidate_urls(%Product{id: id}, []) do
    Logger.warning("thumbnails: product=#{id} has no candidate images")
    :error
  end

  defp try_candidate_urls(%Product{} = product, urls) do
    Enum.reduce_while(urls, {:error, :no_urls}, fn url, _acc ->
      case Thumbnails.use_image(product, url) do
        {:ok, _updated} ->
          {:halt, :ok}

        err ->
          Logger.debug(
            "thumbnails: product=#{product.id} url=#{url} failed: #{inspect(err)}"
          )

          {:cont, err}
      end
    end)
    |> case do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "thumbnails: product=#{product.id} no working image (last=#{inspect(reason)})"
        )

        :error
    end
  end

  # Product's own image_url first (historically the best guess —
  # it's whatever the listing seeding the product carried), then
  # every linked chain_listing's image_url. Deduped, blank-rejected.
  defp candidate_urls(%Product{id: id, image_url: pimg}) do
    listing_urls =
      Repo.all(
        from l in ChainListing,
          join: pl in ProductListing,
          on: pl.chain_listing_id == l.id,
          where:
            pl.product_id == ^id and not is_nil(l.image_url) and l.image_url != "",
          select: l.image_url
      )

    [pimg | listing_urls]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end
end
