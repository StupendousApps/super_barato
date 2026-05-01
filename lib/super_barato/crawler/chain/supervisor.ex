defmodule SuperBarato.Crawler.Chain.Supervisor do
  @moduledoc """
  One supervisor per supermarket chain. Hosts the per-chain pipeline
  GenServers (QueueServer, FetcherServer, SchedulerServer) plus a
  Task.Supervisor for the short-lived tasks the SchedulerServer fires.

  The DB sink is a global singleton — `Crawler.PersistenceServer` —
  supervised at the application level. Every per-chain FetcherServer
  funnels writes into it, so SQLite never sees write-write contention
  from the crawler.

  Strategy is `:rest_for_one`: if QueueServer dies, FetcherServer /
  TaskSup / SchedulerServer all restart — the pipeline is reset and
  the SchedulerServer re-seeds from its schedule.

  Child order (this is the `:rest_for_one` reset order):

    1. QueueServer       (central pipe)
    2. FetcherServer     (depends on QueueServer + global PersistenceServer)
    3. Task.Supervisor   (for transient SchedulerServer tasks)
    4. SchedulerServer   (fires via Task.Supervisor, pushes to QueueServer)
  """

  use Supervisor

  alias SuperBarato.Crawler.Chain.{FetcherServer, QueueServer, SchedulerServer}

  def start_link(opts) do
    chain = Keyword.fetch!(opts, :chain)
    Supervisor.start_link(__MODULE__, opts, name: via(chain))
  end

  def child_spec(opts) do
    chain = Keyword.fetch!(opts, :chain)

    %{
      id: {__MODULE__, chain},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent
    }
  end

  defp via(chain),
    do: {:via, Registry, {SuperBarato.Crawler.Registry, {__MODULE__, chain}}}

  @impl true
  def init(opts) do
    chain = Keyword.fetch!(opts, :chain)

    # Tests pass an explicit `:schedule` (StubAdapter integration);
    # production boot omits it and we read from the DB here, after
    # Repo has started.
    schedule =
      Keyword.get_lazy(opts, :schedule, fn ->
        SuperBarato.Crawler.Schedules.cron_entries(chain)
      end)

    # Knobs come from `Crawler.opts_for/1` already merged with the
    # defaults block in config.exs. The `Keyword.get` defaults below
    # are only the safety net for tests that hand-roll opts without
    # going through the resolver.
    queue_capacity = Keyword.get(opts, :queue_capacity, 50)
    queue_low_water = Keyword.get(opts, :queue_low_water, div(queue_capacity * 6, 10))
    interval_ms = Keyword.get(opts, :interval_ms, 1_000)
    fallback_profiles = Keyword.get(opts, :fallback_profiles, [:chrome116])
    block_backoff_ms = Keyword.get(opts, :block_backoff_ms, 60_000)
    cf_protected = Keyword.get(opts, :cf_protected, false)
    cf_homepage = Keyword.get(opts, :cf_homepage)
    adapter = Keyword.get(opts, :adapter)

    task_sup_name = task_sup_name(chain)

    children = [
      {QueueServer, chain: chain, capacity: queue_capacity, low_water: queue_low_water},
      {FetcherServer,
       chain: chain,
       adapter: adapter,
       interval_ms: interval_ms,
       fallback_profiles: fallback_profiles,
       block_backoff_ms: block_backoff_ms,
       cf_protected: cf_protected,
       cf_homepage: cf_homepage},
      {Task.Supervisor, name: task_sup_name},
      {SchedulerServer, chain: chain, schedule: schedule, task_sup: task_sup_name}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def task_sup_name(chain),
    do: {:via, Registry, {SuperBarato.Crawler.Registry, {Task.Supervisor, chain}}}
end
