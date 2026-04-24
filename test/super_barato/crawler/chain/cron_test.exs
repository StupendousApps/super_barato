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
end
