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
  alias SuperBarato.Crawler.{Schedules, Session}
  alias SuperBarato.Crawler.Chain.{Cron, Queue, Supervisor}
  alias SuperBarato.Catalog.{Category, ChainListing}
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
      cron_epoch: cron_epoch(chain),
      schedule_count: length(Schedules.list_for(chain)),
      listings_count: count(ChainListing, chain),
      last_priced_at: latest(ChainListing, :last_priced_at, chain),
      categories_count: count(Category, chain),
      last_seen_at: latest(Category, :last_seen_at, chain)
    }
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
        Queue.size(chain)
      catch
        :exit, _ -> nil
      end
    end
  end

  defp cron_epoch(chain) do
    case GenServer.whereis(cron_via(chain)) do
      nil ->
        nil

      _pid ->
        try do
          :sys.get_state(cron_via(chain), 100).epoch
        catch
          _, _ -> nil
        end
    end
  end

  defp cron_via(chain),
    do: {:via, Registry, {SuperBarato.Crawler.Registry, {Cron, chain}}}

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
