defmodule SuperBarato.Crawler.Chain.Cron do
  @moduledoc """
  Per-chain scheduler. Holds a static list of schedule entries and
  fires each one via `Task.Supervisor.start_child/2` at the configured
  cadence. Each entry is an `{mfa}` describing the side effect — either
  a direct `Queue.push` (for one-shot discovery seeds) or a
  `ProductProducer.run` call (for streaming work out of the DB).

  Cron itself never blocks. Each firing spawns a short-lived task
  under the chain's Task.Supervisor and returns immediately.
  """

  use GenServer

  require Logger

  def start_link(opts) do
    chain = Keyword.fetch!(opts, :chain)
    GenServer.start_link(__MODULE__, opts, name: via(chain))
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
    schedule = Keyword.fetch!(opts, :schedule)
    task_sup = Keyword.fetch!(opts, :task_sup)

    Enum.each(schedule, &schedule_next/1)

    {:ok, %{chain: chain, schedule: schedule, task_sup: task_sup}}
  end

  @impl true
  def handle_info({:fire, entry}, state) do
    {:cadence, _, {m, f, a}} = normalize(entry)

    Logger.info("[#{state.chain}] cron firing #{inspect({m, f})}")

    Task.Supervisor.start_child(state.task_sup, fn ->
      apply(m, f, a)
    end)

    schedule_next(entry)
    {:noreply, state}
  end

  # Schedule entries look like:
  #   {{:every, {7, :days}}, {Mod, :fun, [args]}}
  #   {{:every, {1, :hour}}, {Mod, :fun, [args]}}
  defp schedule_next({cadence, mfa}) do
    delay = delay_ms(cadence)
    Process.send_after(self(), {:fire, {cadence, mfa}}, delay)
  end

  defp normalize({cadence, mfa}), do: {:cadence, cadence, mfa}

  defp delay_ms({:every, {n, :second}}), do: n * 1_000
  defp delay_ms({:every, {n, :minute}}), do: n * 60 * 1_000
  defp delay_ms({:every, {n, :hour}}), do: n * 60 * 60 * 1_000
  defp delay_ms({:every, {n, :day}}), do: n * 24 * 60 * 60 * 1_000
  defp delay_ms({:every, {n, :days}}), do: n * 24 * 60 * 60 * 1_000
end
