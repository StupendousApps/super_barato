defmodule SuperBarato.HomeCache do
  @moduledoc """
  Keeps the public home page's data warm in an ETS table so each
  HomeLive mount serves it without any DB work.

  Refreshes both `category_previews` and the global `popular_terms`
  every 2 minutes. The ETS table is `:public, :read_concurrency:
  true` so LiveView processes can read it directly without a
  GenServer round-trip.

  Lookups before the first refresh has completed return the empty
  defaults — HomeLive renders a clean (but empty) index until the
  first warm-up finishes a moment after boot.
  """
  use GenServer
  require Logger

  alias SuperBarato.HomeData

  @table :home_cache
  @refresh_interval :timer.minutes(2)

  ## ── Public API ───────────────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Cached category preview bands. `[]` until first refresh."
  def category_previews, do: lookup(:category_previews, [])

  @doc "Cached global popular terms. `[]` until first refresh."
  def popular_terms, do: lookup(:popular_terms, [])

  @doc "Force a synchronous refresh — useful from a console or test."
  def refresh, do: GenServer.call(__MODULE__, :refresh, 30_000)

  ## ── GenServer ────────────────────────────────────────────────

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    send(self(), :refresh)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:refresh, state) do
    do_refresh()
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    do_refresh()
    {:reply, :ok, state}
  end

  ## ── Internals ────────────────────────────────────────────────

  defp do_refresh do
    started = System.monotonic_time(:millisecond)

    try do
      previews = HomeData.category_previews(6)
      :ets.insert(@table, {:category_previews, previews})

      terms = HomeData.popular_terms(48)
      :ets.insert(@table, {:popular_terms, terms})

      ms = System.monotonic_time(:millisecond) - started
      Logger.debug("home_cache refreshed in #{ms}ms")
    rescue
      e -> Logger.warning("home_cache refresh failed: #{Exception.message(e)}")
    end
  end

  defp lookup(key, default) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      _ -> default
    end
  rescue
    ArgumentError -> default
  end
end
