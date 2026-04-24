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

  describe ":weekly cadence" do
    test "fires when all 7 days + imminent time (effectively daily_at)" do
      chain = :"cron_weekly_all_#{System.unique_integer([:positive])}"
      task_sup_name = {:via, Registry, {SuperBarato.Crawler.Registry, {Task.Supervisor, chain}}}
      {:ok, _} = start_supervised({Task.Supervisor, name: task_sup_name}, id: {:wa_sup, chain})

      target =
        DateTime.utc_now()
        |> DateTime.add(1_200, :millisecond)
        |> DateTime.to_time()
        |> Time.truncate(:second)

      # Truncation rounds down; bump by 1s so the slot is actually ahead.
      target = Time.add(target, 1, :second)

      schedule = [
        {{:weekly, [:mon, :tue, :wed, :thu, :fri, :sat, :sun], [target]},
         {TestTarget, :fire, [self(), :daily]}}
      ]

      {:ok, _} =
        start_supervised(
          {Cron, chain: chain, schedule: schedule, task_sup: task_sup_name},
          id: {:wa_cron, chain}
        )

      assert_receive {:fired, :daily}, 2_500
    end

    test "fires when single day + imminent time (effectively weekly_at)" do
      chain = :"cron_weekly_single_#{System.unique_integer([:positive])}"
      task_sup_name = {:via, Registry, {SuperBarato.Crawler.Registry, {Task.Supervisor, chain}}}
      {:ok, _} = start_supervised({Task.Supervisor, name: task_sup_name}, id: {:ws_sup, chain})

      target_dt = DateTime.utc_now() |> DateTime.add(2, :second)
      dow = Date.day_of_week(DateTime.to_date(target_dt))
      day_atom = Enum.at([:mon, :tue, :wed, :thu, :fri, :sat, :sun], dow - 1)
      time = target_dt |> DateTime.to_time() |> Time.truncate(:second)

      schedule = [{{:weekly, [day_atom], [time]}, {TestTarget, :fire, [self(), :weekly]}}]

      {:ok, _} =
        start_supervised(
          {Cron, chain: chain, schedule: schedule, task_sup: task_sup_name},
          id: {:ws_cron, chain}
        )

      assert_receive {:fired, :weekly}, 3_500
    end

    test "picks the earliest (day × time) slot from the cross product" do
      chain = :"cron_weekly_cross_#{System.unique_integer([:positive])}"
      task_sup_name = {:via, Registry, {SuperBarato.Crawler.Registry, {Task.Supervisor, chain}}}
      {:ok, _} = start_supervised({Task.Supervisor, name: task_sup_name}, id: {:wc_sup, chain})

      # Near time + a time 6 hours later, every day.
      now = DateTime.utc_now()
      near = now |> DateTime.add(2, :second) |> DateTime.to_time() |> Time.truncate(:second)
      far = Time.add(near, 6 * 3600)

      schedule = [
        {{:weekly, [:mon, :tue, :wed, :thu, :fri, :sat, :sun], [far, near]},
         {TestTarget, :fire, [self(), :cross]}}
      ]

      {:ok, _} =
        start_supervised(
          {Cron, chain: chain, schedule: schedule, task_sup: task_sup_name},
          id: {:wc_cron, chain}
        )

      # Should fire at the near slot, not the far one — within 3.5s.
      assert_receive {:fired, :cross}, 3_500
    end
  end
end
