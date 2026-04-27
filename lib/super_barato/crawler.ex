defmodule SuperBarato.Crawler do
  @moduledoc """
  Entry point for the crawler. Keeps the registry of chain adapters and
  exposes `adapter/1` for the pipeline (and Mix tasks) to look up a
  chain's implementation module.

  The running pipeline (Queue, Worker, Results, Cron) lives under
  `SuperBarato.Crawler.Chain.Supervisor`, one per chain, started from
  `SuperBarato.Application` when `chains_enabled` is true in config.
  """

  @adapters %{
    unimarc: SuperBarato.Crawler.Unimarc,
    jumbo: SuperBarato.Crawler.Jumbo,
    santa_isabel: SuperBarato.Crawler.SantaIsabel,
    lider: SuperBarato.Crawler.Lider,
    tottus: SuperBarato.Crawler.Tottus
  }

  def adapter(chain) when is_atom(chain), do: Map.fetch!(@adapters, chain)

  def known_chains, do: Map.keys(@adapters)

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

  @kinds ~w(discover_categories discover_products)

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

  defp do_trigger(chain, "discover_categories") do
    SuperBarato.Crawler.Chain.Queue.push(
      chain,
      {:discover_categories, %{chain: chain, parent: nil}}
    )

    :ok
  end

  defp do_trigger(chain, "discover_products") do
    {:ok, _pid} =
      Task.Supervisor.start_child(
        SuperBarato.Crawler.Chain.Supervisor.task_sup_name(chain),
        producer_for(chain),
        :run,
        [[chain: chain]]
      )

    :ok
  end

  # Per-chain dispatch: Cencosud chains discover via sitemap;
  # Lider/Unimarc keep iterating leaf categories from the DB.
  defp producer_for(:jumbo), do: SuperBarato.Crawler.Cencosud.ProductProducer
  defp producer_for(:santa_isabel), do: SuperBarato.Crawler.Cencosud.ProductProducer
  defp producer_for(_), do: SuperBarato.Crawler.Chain.ProductProducer

  @doc """
  Drops every queued task for `chain` and unblocks any parked
  producer push. Returns `{:ok, count}` where `count` is how many
  tasks were discarded, or `{:error, :pipeline_not_running}`.
  """
  def flush_queue(chain) when is_atom(chain) do
    cond do
      chain not in known_chains() -> {:error, :unknown_chain}
      not pipeline_running?(chain) -> {:error, :pipeline_not_running}
      true -> {:ok, SuperBarato.Crawler.Chain.Queue.clear(chain)}
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
