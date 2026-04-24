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
  #   {{:daily_at, ~T[06:00:00]}, {Mod, :fun, [args]}}  — UTC time-of-day
  #   {{:weekly_at, :mon, ~T[05:00:00]}, {Mod, :fun, [args]}}  — UTC day+time
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

  # Milliseconds until the next occurrence of `time` in UTC. If the
  # time already passed today, schedule for the same time tomorrow.
  # UTC is used deliberately to avoid a tzdata dependency; Chilean
  # off-hours (02:00–06:00 CLT) translate to 05:00–09:00 UTC
  # (UTC-3 standard time, UTC-4 during DST).
  defp delay_ms({:daily_at, %Time{} = time}) do
    now = DateTime.utc_now()

    today_target =
      now
      |> DateTime.to_date()
      |> DateTime.new!(time, "Etc/UTC")

    target =
      case DateTime.compare(today_target, now) do
        :gt -> today_target
        _ -> DateTime.add(today_target, 1, :day)
      end

    DateTime.diff(target, now, :millisecond)
  end

  # Milliseconds until the next `day` (`:mon`..`:sun`) at `time` (UTC).
  # If we're already past the slot for this week, schedule for next.
  defp delay_ms({:weekly_at, day, %Time{} = time}) when is_atom(day) do
    target_dow = day_of_week_number(day)
    now = DateTime.utc_now()
    today = DateTime.to_date(now)
    today_dow = Date.day_of_week(today)

    days_ahead =
      cond do
        target_dow > today_dow ->
          target_dow - today_dow

        target_dow < today_dow ->
          7 - today_dow + target_dow

        # Same day-of-week — only today if time still ahead; else in 7.
        true ->
          today_target = DateTime.new!(today, time, "Etc/UTC")
          if DateTime.compare(today_target, now) == :gt, do: 0, else: 7
      end

    target = DateTime.new!(Date.add(today, days_ahead), time, "Etc/UTC")
    DateTime.diff(target, now, :millisecond)
  end

  defp day_of_week_number(:mon), do: 1
  defp day_of_week_number(:tue), do: 2
  defp day_of_week_number(:wed), do: 3
  defp day_of_week_number(:thu), do: 4
  defp day_of_week_number(:fri), do: 5
  defp day_of_week_number(:sat), do: 6
  defp day_of_week_number(:sun), do: 7
end
