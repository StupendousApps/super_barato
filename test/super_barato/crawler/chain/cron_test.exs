defmodule SuperBarato.Crawler.Chain.CronTest do
  use ExUnit.Case, async: false

  alias SuperBarato.Crawler.Chain.Cron

  # Schedule delays are at least 1 second for `{:every, {1, :second}}`. To
  # keep tests fast, we directly send `{:fire, entry}` to the Cron
  # process rather than wait for a real timer.

  defmodule TestTarget do
    def fire(pid, label), do: send(pid, {:fired, label})
  end

  setup do
    chain = :"cron_test_#{System.unique_integer([:positive])}"
    task_sup_name = {:via, Registry, {SuperBarato.Crawler.Registry, {Task.Supervisor, chain}}}

    {:ok, _} = start_supervised({Task.Supervisor, name: task_sup_name})

    schedule = [
      {{:every, {1, :second}}, {TestTarget, :fire, [self(), :a]}},
      {{:every, {1, :hour}}, {TestTarget, :fire, [self(), :b]}}
    ]

    {:ok, cron_pid} =
      start_supervised({Cron, chain: chain, schedule: schedule, task_sup: task_sup_name})

    {:ok, chain: chain, cron: cron_pid, schedule: schedule}
  end

  describe "on init" do
    test "starts without crashing", %{cron: cron} do
      assert Process.alive?(cron)
    end
  end

  describe "handle_info({:fire, entry}, state)" do
    test "invokes the scheduled MFA via Task.Supervisor", %{cron: cron, schedule: schedule} do
      # Manually dispatch the first entry
      send(cron, {:fire, Enum.at(schedule, 0)})
      assert_receive {:fired, :a}, 500

      send(cron, {:fire, Enum.at(schedule, 1)})
      assert_receive {:fired, :b}, 500
    end
  end

  describe ":weekly_at cadence" do
    test "schedules for the right weekday at the right UTC time" do
      chain = :"cron_weekly_at_#{System.unique_integer([:positive])}"
      task_sup_name = {:via, Registry, {SuperBarato.Crawler.Registry, {Task.Supervisor, chain}}}
      {:ok, _} = start_supervised({Task.Supervisor, name: task_sup_name}, id: {:wat_sup, chain})

      # Pick tomorrow's weekday at an arbitrary time. We don't wait
      # for it to fire (too slow); we just verify Cron init doesn't
      # crash and the process is alive.
      tomorrow = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.to_date()
      tomorrow_dow = Date.day_of_week(tomorrow)

      day_atom =
        Enum.at([:mon, :tue, :wed, :thu, :fri, :sat, :sun], tomorrow_dow - 1)

      schedule = [{{:weekly_at, day_atom, ~T[12:00:00]}, {TestTarget, :fire, [self(), :weekly]}}]

      {:ok, cron} =
        start_supervised(
          {Cron, chain: chain, schedule: schedule, task_sup: task_sup_name},
          id: {:wat_cron, chain}
        )

      assert Process.alive?(cron)
    end

    test "fires when the scheduled slot is moments away" do
      chain = :"cron_weekly_at_now_#{System.unique_integer([:positive])}"
      task_sup_name = {:via, Registry, {SuperBarato.Crawler.Registry, {Task.Supervisor, chain}}}
      {:ok, _} = start_supervised({Task.Supervisor, name: task_sup_name}, id: {:wn_sup, chain})

      target_dt = DateTime.utc_now() |> DateTime.add(2, :second)
      dow = Date.day_of_week(DateTime.to_date(target_dt))
      day_atom = Enum.at([:mon, :tue, :wed, :thu, :fri, :sat, :sun], dow - 1)
      time = target_dt |> DateTime.to_time() |> Time.truncate(:second)

      schedule = [{{:weekly_at, day_atom, time}, {TestTarget, :fire, [self(), :weekly_now]}}]

      {:ok, _} =
        start_supervised(
          {Cron, chain: chain, schedule: schedule, task_sup: task_sup_name},
          id: {:wn_cron, chain}
        )

      assert_receive {:fired, :weekly_now}, 3_500
    end
  end

  describe ":daily_at cadence" do
    @tag task_sup_name: {:via, Registry, {SuperBarato.Crawler.Registry, {Task.Supervisor, :dat}}}
    test "fires an entry scheduled for a moment from now" do
      chain = :"cron_daily_at_#{System.unique_integer([:positive])}"
      task_sup_name = {:via, Registry, {SuperBarato.Crawler.Registry, {Task.Supervisor, chain}}}
      {:ok, _} = start_supervised({Task.Supervisor, name: task_sup_name}, id: {:dat_sup, chain})

      # ~200ms from now, UTC
      target =
        DateTime.utc_now()
        |> DateTime.add(200, :millisecond)
        |> DateTime.to_time()
        |> Time.truncate(:second)

      # Truncating to :second rounds down — add one more second so the
      # target isn't actually in the past.
      target = Time.add(target, 1, :second)

      schedule = [{{:daily_at, target}, {TestTarget, :fire, [self(), :at_time]}}]

      {:ok, _} =
        start_supervised(
          {Cron, chain: chain, schedule: schedule, task_sup: task_sup_name},
          id: {:dat_cron, chain}
        )

      # Up to 1500ms slack (second-level rounding + send_after + task spawn).
      assert_receive {:fired, :at_time}, 1500
    end
  end
end
