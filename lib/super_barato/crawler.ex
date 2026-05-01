defmodule SuperBarato.Crawler do
  @moduledoc """
  Entry point for the crawler. Keeps the registry of chain adapters and
  exposes `adapter/1` for the pipeline (and Mix tasks) to look up a
  chain's implementation module.

  The running pipeline (Queue, Worker, Results, Cron) lives under
  `SuperBarato.Crawler.Chain.Supervisor`, one per chain, started from
  `SuperBarato.Application` when `chains_enabled` is true in config.
  """

  # Order is the public ordering of chains everywhere they're listed —
  # admin runtime page, schedule editor, listing/category/product
  # filter dropdowns, Status.all/0. Map.keys/1 doesn't guarantee a
  # stable order across BEAM versions, so we keep the order in a
  # separate list and look adapters up in the map.
  @chain_order ~w(jumbo santa_isabel unimarc lider tottus acuenta)a

  @adapters %{
    jumbo: SuperBarato.Crawler.Jumbo,
    santa_isabel: SuperBarato.Crawler.SantaIsabel,
    unimarc: SuperBarato.Crawler.Unimarc,
    lider: SuperBarato.Crawler.Lider,
    tottus: SuperBarato.Crawler.Tottus,
    acuenta: SuperBarato.Crawler.Acuenta
  }

  def adapter(chain) when is_atom(chain), do: Map.fetch!(@adapters, chain)

  def known_chains, do: @chain_order

  @doc """
  Resolved pipeline knobs for `chain` — the merge of
  `:super_barato, SuperBarato.Crawler[:defaults]` with the chain's
  entry under `[:chains, chain]`. Per-chain values win.

  Returns a flat keyword list with `:chain` injected, ready to hand
  to `Chain.Supervisor.start_link/1`. Every reader of pipeline knobs
  goes through this function so there's exactly one place that
  defines what's a knob and how defaults flow into per-chain
  overrides.
  """
  def opts_for(chain) when is_atom(chain) do
    cfg = Application.get_env(:super_barato, __MODULE__, [])
    defaults = Keyword.get(cfg, :defaults, [])
    chain_opts = cfg |> Keyword.get(:chains, []) |> Keyword.get(chain, [])

    defaults
    |> Keyword.merge(chain_opts)
    |> Keyword.put(:chain, chain)
  end

  @enabled_key {__MODULE__, :enabled}

  @doc """
  Runtime kill-switch for automated crawler activity. When `false`,
  the per-chain Cron skips firing scheduled producers — already-queued
  tasks keep running, but no new batches start.

  Manual triggers from `/crawlers/live` (the per-row buttons) ignore
  this flag — when an operator clicks a button they want it to fire.

  The flag lives in `:persistent_term`, so reads are O(1) and survive
  no DB hit. Resets to `true` on application restart unless the
  operator flips it again.
  """
  def enabled?, do: :persistent_term.get(@enabled_key, true)

  def set_enabled(bool) when is_boolean(bool) do
    :persistent_term.put(@enabled_key, bool)
    bool
  end

  @doc """
  Manually fire a discovery run for `chain` from outside the schedule
  (admin UI button, IEx, etc.). Returns `:ok` once the work is queued
  / spawned — the actual run happens asynchronously under the chain's
  Task.Supervisor + Queue + Worker.

  Kinds match the schedule rows:

    * `"discover_categories"` — pushes one task on the chain's Queue.
    * `"discover_products"` — spawns `ProductProducer.run/1`, which
      streams a task per leaf category onto the Queue.

  Returns `{:error, :pipeline_not_running}` when the chain's Supervisor
  hasn't been started (i.e. `chains_enabled: false` or the chain crashed
  hard) so the caller can surface a useful error.
  """
  require Logger

  @kinds ~w(discover_categories discover_products refresh_listings)

  def trigger(chain, kind) when is_atom(chain) do
    cond do
      chain not in known_chains() ->
        {:error, :unknown_chain}

      kind not in @kinds ->
        {:error, {:unknown_kind, kind}}

      not pipeline_running?(chain) ->
        {:error, :pipeline_not_running}

      true ->
        Logger.info("[#{chain}] manual trigger: #{kind}")
        do_trigger(chain, kind)
    end
  end

  defp do_trigger(chain, kind) do
    {:ok, _pid} =
      Task.Supervisor.start_child(
        SuperBarato.Crawler.Chain.Supervisor.task_sup_name(chain),
        producer_for(chain, kind),
        :run,
        [[chain: chain]]
      )

    :ok
  end

  # (chain, kind) → producer module. Mirrors Schedule.mfa/1's dispatch
  # so the admin trigger button and cron entries pick the same module.
  defp producer_for(_chain, "discover_categories"),
    do: SuperBarato.Crawler.Chain.CategoryProducer

  defp producer_for(:jumbo, "discover_products"),
    do: SuperBarato.Crawler.Cencosud.ProductProducer

  defp producer_for(:santa_isabel, "discover_products"),
    do: SuperBarato.Crawler.Cencosud.ProductProducer

  defp producer_for(_chain, "discover_products"),
    do: SuperBarato.Crawler.Chain.ProductProducer

  defp producer_for(_chain, "refresh_listings"),
    do: SuperBarato.Crawler.Chain.ListingProducer

  @doc """
  Drops every queued task for `chain` and unblocks any parked
  producer push. Returns `{:ok, count}` where `count` is how many
  tasks were discarded, or `{:error, :pipeline_not_running}`.
  """
  def flush_queue(chain) when is_atom(chain) do
    cond do
      chain not in known_chains() -> {:error, :unknown_chain}
      not pipeline_running?(chain) -> {:error, :pipeline_not_running}
      true -> {:ok, SuperBarato.Crawler.Chain.QueueServer.clear(chain)}
    end
  end

  defp pipeline_running?(chain) do
    case GenServer.whereis(
           {:via, Registry,
            {SuperBarato.Crawler.Registry, {SuperBarato.Crawler.Chain.Supervisor, chain}}}
         ) do
      nil -> false
      _pid -> true
    end
  end
end
