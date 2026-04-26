defmodule SuperBarato.Crawler.Chain.Supervisor do
  @moduledoc """
  One supervisor per supermarket chain. Hosts the four long-lived
  GenServers that make up the chain's pipeline, plus a Task.Supervisor
  for the short-lived tasks Cron fires.

  Strategy is `:rest_for_one`: if Queue dies, Worker/TaskSup/Cron all
  restart — the pipeline is reset and Cron re-seeds from its schedule.

  Child order (this is the `:rest_for_one` reset order):

    1. Results          (sink — depends on nothing)
    2. Queue            (central pipe)
    3. Worker           (depends on Queue + Results)
    4. Task.Supervisor  (for transient Cron tasks)
    5. Cron             (fires via Task.Supervisor, pushes to Queue)
  """

  use Supervisor

  alias SuperBarato.Crawler.Chain.{Cron, Queue, Results, Worker}

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

    queue_capacity = Keyword.get(opts, :queue_capacity, 200)
    interval_ms = Keyword.get(opts, :interval_ms, 1_000)
    fallback_profiles = Keyword.get(opts, :fallback_profiles, [:chrome116])
    block_backoff_ms = Keyword.get(opts, :block_backoff_ms, 60_000)
    cf_protected = Keyword.get(opts, :cf_protected, false)
    cf_homepage = Keyword.get(opts, :cf_homepage)
    adapter = Keyword.get(opts, :adapter)

    task_sup_name = task_sup_name(chain)

    children = [
      {Results, chain: chain, adapter: adapter},
      {Queue, chain: chain, capacity: queue_capacity},
      {Worker,
       chain: chain,
       adapter: adapter,
       interval_ms: interval_ms,
       fallback_profiles: fallback_profiles,
       block_backoff_ms: block_backoff_ms,
       cf_protected: cf_protected,
       cf_homepage: cf_homepage},
      {Task.Supervisor, name: task_sup_name},
      {Cron, chain: chain, schedule: schedule, task_sup: task_sup_name}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def task_sup_name(chain),
    do: {:via, Registry, {SuperBarato.Crawler.Registry, {Task.Supervisor, chain}}}
end
