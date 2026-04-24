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
  #   {{:weekly, [:mon, :tue], [~T[04:00:00], ~T[16:00:00]]},
  #      {Mod, :fun, [args]}}
  #
  # `:weekly` fires at every (day × time) slot, UTC. Days are atoms
  # `:mon`..`:sun`; times are `%Time{}` structs. If the earliest
  # upcoming slot is today and its time has already passed, it rolls
  # forward to the next matching (day, time) pair.
  defp schedule_next({cadence, mfa}) do
    delay = delay_ms(cadence)
    Process.send_after(self(), {:fire, {cadence, mfa}}, delay)
  end

  defp normalize({cadence, mfa}), do: {:cadence, cadence, mfa}

  @doc """
  Milliseconds from `now` until the next firing of `cadence`. Exposed
  so unit tests can freeze `now` for deterministic computation. Uses
  `DateTime.utc_now/0` when `now` isn't provided.
  """
  def delay_ms(cadence, now \\ DateTime.utc_now())

  def delay_ms({:every, {n, :second}}, _now), do: n * 1_000
  def delay_ms({:every, {n, :minute}}, _now), do: n * 60 * 1_000
  def delay_ms({:every, {n, :hour}}, _now), do: n * 60 * 60 * 1_000
  def delay_ms({:every, {n, :day}}, _now), do: n * 24 * 60 * 60 * 1_000
  def delay_ms({:every, {n, :days}}, _now), do: n * 24 * 60 * 60 * 1_000

  def delay_ms({:weekly, days, times}, now)
      when is_list(days) and is_list(times) and days != [] and times != [] do
    today = DateTime.to_date(now)
    today_dow = Date.day_of_week(today)

    candidates =
      for day <- days, time <- times do
        target_dow = day_of_week_number(day)

        days_ahead =
          cond do
            target_dow > today_dow ->
              target_dow - today_dow

            target_dow < today_dow ->
              7 - today_dow + target_dow

            # Same day-of-week — use today if time still ahead; else 7.
            true ->
              today_target = DateTime.new!(today, time, "Etc/UTC")
              if DateTime.compare(today_target, now) == :gt, do: 0, else: 7
          end

        DateTime.new!(Date.add(today, days_ahead), time, "Etc/UTC")
      end

    earliest = Enum.min_by(candidates, &DateTime.to_unix(&1, :millisecond))
    DateTime.diff(earliest, now, :millisecond)
  end

  defp day_of_week_number(:mon), do: 1
  defp day_of_week_number(:tue), do: 2
  defp day_of_week_number(:wed), do: 3
  defp day_of_week_number(:thu), do: 4
  defp day_of_week_number(:fri), do: 5
  defp day_of_week_number(:sat), do: 6
  defp day_of_week_number(:sun), do: 7
end
