defmodule SuperBarato.Crawler.Status do
  @moduledoc """
  Read-only snapshot of a chain's runtime state, for the admin UI.

  All getters degrade gracefully when the chain pipeline isn't running
  (`chains_enabled: false` in dev, or a crashed supervisor): instead
  of raising, they return `nil` / sensible defaults so the page still
  renders.
  """

  import Ecto.Query

  alias SuperBarato.Crawler
  alias SuperBarato.Crawler.{PersistenceServer, Schedules, Session}
  alias SuperBarato.Crawler.Chain.{FetcherServer, QueueServer, SchedulerServer, Supervisor}
  alias SuperBarato.Catalog.{ChainCategory, ChainListing}
  alias SuperBarato.Repo

  @doc "Returns one snapshot per known chain."
  def all do
    for chain <- Crawler.known_chains(), do: snapshot(chain)
  end

  @doc "Snapshot for a single chain."
  def snapshot(chain) when is_atom(chain) do
    %{
      chain: chain,
      running: pipeline_running?(chain),
      profile: Session.get(chain, :profile),
      queue_depth: queue_depth(chain),
      queue_capacity: queue_capacity(chain),
      scheduler_mailbox: stage_mailbox(chain, SchedulerServer),
      fetcher_mailbox: stage_mailbox(chain, FetcherServer),
      schedule_count: length(Schedules.list_for(chain)),
      listings_count: count(ChainListing, chain),
      last_priced_at: latest(ChainListing, :last_priced_at, chain),
      categories_count: count(ChainCategory, chain),
      last_seen_at: latest(ChainCategory, :last_seen_at, chain)
    }
  end

  @doc "Live snapshot of the singleton PersistenceServer."
  def persistence, do: PersistenceServer.metrics()

  defp queue_capacity(chain) do
    Crawler.opts_for(chain)[:queue_capacity]
  end

  # Mailbox depth of the per-chain GenServer registered under
  # `{Mod, chain}`. Returns nil when the pipeline isn't running.
  defp stage_mailbox(chain, mod) do
    case Registry.lookup(SuperBarato.Crawler.Registry, {mod, chain}) do
      [{pid, _}] ->
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, n} -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp pipeline_running?(chain) do
    case GenServer.whereis(supervisor_via(chain)) do
      nil -> false
      _ -> true
    end
  end

  defp supervisor_via(chain),
    do: {:via, Registry, {SuperBarato.Crawler.Registry, {Supervisor, chain}}}

  defp queue_depth(chain) do
    if pipeline_running?(chain) do
      try do
        QueueServer.size(chain)
      catch
        :exit, _ -> nil
      end
    end
  end

  defp count(schema, chain) do
    schema
    |> where([r], r.chain == ^Atom.to_string(chain))
    |> Repo.aggregate(:count)
  end

  defp latest(schema, field, chain) do
    schema
    |> where([r], r.chain == ^Atom.to_string(chain))
    |> select([r], max(field(r, ^field)))
    |> Repo.one()
  end
end
