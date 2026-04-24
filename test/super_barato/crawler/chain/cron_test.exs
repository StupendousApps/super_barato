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

  describe "delay_ms/2 for :every" do
    # Use a fixed `now` so these are deterministic. Values are
    # time-independent anyway — :every doesn't look at `now`.
    @now ~U[2026-04-23 12:00:00Z]

    test ":every {N, :second}" do
      assert Cron.delay_ms({:every, {1, :second}}, @now) == 1_000
      assert Cron.delay_ms({:every, {90, :second}}, @now) == 90_000
    end

    test ":every {N, :minute}" do
      assert Cron.delay_ms({:every, {1, :minute}}, @now) == 60_000
      assert Cron.delay_ms({:every, {5, :minute}}, @now) == 5 * 60_000
    end

    test ":every {N, :hour}" do
      assert Cron.delay_ms({:every, {1, :hour}}, @now) == 3_600_000
      assert Cron.delay_ms({:every, {24, :hour}}, @now) == 24 * 3_600_000
    end

    test ":every {N, :day} and {N, :days}" do
      assert Cron.delay_ms({:every, {1, :day}}, @now) == 86_400_000
      assert Cron.delay_ms({:every, {7, :days}}, @now) == 7 * 86_400_000
    end
  end

  describe "delay_ms/2 for :weekly — single day, single time" do
    # 2026-04-23 is a Thursday (Date.day_of_week(~D[2026-04-23]) == 4).
    @thu_noon ~U[2026-04-23 12:00:00Z]

    test "target time later today (same day-of-week) returns ms until then" do
      cadence = {:weekly, [:thu], [~T[15:00:00]]}
      # 3 hours ahead
      assert Cron.delay_ms(cadence, @thu_noon) == 3 * 3_600_000
    end

    test "target time already passed today — rolls to next week" do
      cadence = {:weekly, [:thu], [~T[09:00:00]]}
      # 7 days - 3 hours (time already passed by 3h)
      expected = 7 * 86_400_000 - 3 * 3_600_000
      assert Cron.delay_ms(cadence, @thu_noon) == expected
    end

    test "target day tomorrow" do
      cadence = {:weekly, [:fri], [~T[12:00:00]]}
      # Exactly 24h ahead
      assert Cron.delay_ms(cadence, @thu_noon) == 24 * 3_600_000
    end

    test "target day yesterday (rolls forward 6 days)" do
      cadence = {:weekly, [:wed], [~T[12:00:00]]}
      # 6 days ahead (same hour-minute)
      assert Cron.delay_ms(cadence, @thu_noon) == 6 * 86_400_000
    end

    test "target 6 days later (:fri .. :wed)" do
      # Fri 12:00 → next Wed 12:00 is 5 days, sanity check
      fri = ~U[2026-04-24 12:00:00Z]
      cadence = {:weekly, [:wed], [~T[12:00:00]]}
      assert Cron.delay_ms(cadence, fri) == 5 * 86_400_000
    end

    test "target time ~1ms after now" do
      cadence = {:weekly, [:thu], [~T[12:00:00]]}
      now = ~U[2026-04-23 11:59:59.999Z]
      # delta is a few ms (with sub-second on `now`)
      ms = Cron.delay_ms(cadence, now)
      assert ms >= 0 and ms < 10
    end

    test "target time exactly == now rolls to next week" do
      cadence = {:weekly, [:thu], [~T[12:00:00]]}
      # now is the slot exactly — compare :gt is false, so +7 days
      assert Cron.delay_ms(cadence, @thu_noon) == 7 * 86_400_000
    end
  end

  describe "delay_ms/2 for :weekly — multi-day, single time" do
    @thu_noon ~U[2026-04-23 12:00:00Z]

    test "picks today when today is in the set and time still ahead" do
      cadence = {:weekly, [:mon, :thu, :sun], [~T[15:00:00]]}
      # Thu 15:00 is earliest (today, 3h ahead)
      assert Cron.delay_ms(cadence, @thu_noon) == 3 * 3_600_000
    end

    test "picks nearest future day when today's time already passed" do
      cadence = {:weekly, [:mon, :thu, :fri], [~T[09:00:00]]}
      # Thu 09:00 already passed (noon now), Fri 09:00 is tomorrow.
      # Mon is after Fri; so Fri wins.
      expected = 24 * 3_600_000 - 3 * 3_600_000
      assert Cron.delay_ms(cadence, @thu_noon) == expected
    end

    test "every day of the week (effectively daily_at)" do
      cadence = {:weekly, [:mon, :tue, :wed, :thu, :fri, :sat, :sun], [~T[15:00:00]]}
      assert Cron.delay_ms(cadence, @thu_noon) == 3 * 3_600_000
    end

    test "every day, time already passed — rolls to tomorrow (not 7d)" do
      cadence = {:weekly, [:mon, :tue, :wed, :thu, :fri, :sat, :sun], [~T[09:00:00]]}
      expected = 24 * 3_600_000 - 3 * 3_600_000
      assert Cron.delay_ms(cadence, @thu_noon) == expected
    end
  end

  describe "delay_ms/2 for :weekly — single day, multi-time" do
    @thu_noon ~U[2026-04-23 12:00:00Z]

    test "picks earliest time still ahead today" do
      cadence = {:weekly, [:thu], [~T[14:00:00], ~T[18:00:00]]}
      # Earliest is 14:00 — 2h ahead.
      assert Cron.delay_ms(cadence, @thu_noon) == 2 * 3_600_000
    end

    test "if all today's times passed, rolls to next week" do
      cadence = {:weekly, [:thu], [~T[08:00:00], ~T[09:00:00]]}
      # Both passed. Next occurrence: next Thu 08:00 = 7 days - 4h.
      expected = 7 * 86_400_000 - 4 * 3_600_000
      assert Cron.delay_ms(cadence, @thu_noon) == expected
    end

    test "mixed — one today passed, one ahead; picks ahead" do
      cadence = {:weekly, [:thu], [~T[08:00:00], ~T[18:00:00]]}
      # 18:00 today wins.
      assert Cron.delay_ms(cadence, @thu_noon) == 6 * 3_600_000
    end
  end

  describe "delay_ms/2 for :weekly — cross product" do
    @thu_noon ~U[2026-04-23 12:00:00Z]

    test "mon+tue+wed at 04:45 and 14:15 picks next-Mon 04:45 from Thu noon" do
      cadence =
        {:weekly, [:mon, :tue, :wed], [~T[04:45:00], ~T[14:15:00]]}

      # Today is Thu 12:00. Next matching day is Mon (4 days ahead).
      # Earliest Mon slot: 04:45 UTC. That's Thu 12:00 + 3d + 16h 45m.
      expected = 3 * 86_400_000 + 16 * 3_600_000 + 45 * 60_000
      assert Cron.delay_ms(cadence, @thu_noon) == expected
    end

    test "argument order (days, times) doesn't change the result" do
      a = {:weekly, [:mon, :thu, :sun], [~T[08:00:00], ~T[20:00:00]]}
      b = {:weekly, [:sun, :thu, :mon], [~T[20:00:00], ~T[08:00:00]]}
      assert Cron.delay_ms(a, @thu_noon) == Cron.delay_ms(b, @thu_noon)
    end

    test "picks the globally-earliest (day, time) pair" do
      # Thu 12:00 now. Candidates (cross product):
      #   Fri 02:00 = +14h  ← earliest
      #   Fri 04:00 = +16h
      #   Mon 02:00 = +3d 14h
      #   Mon 04:00 = +3d 16h
      cadence = {:weekly, [:fri, :mon], [~T[04:00:00], ~T[02:00:00]]}
      expected = 14 * 3_600_000
      assert Cron.delay_ms(cadence, @thu_noon) == expected
    end
  end

  describe "delay_ms/2 for :weekly — day-of-week correctness" do
    # Explicit sanity: for every weekday `d`, with now = that weekday
    # at noon and target time 15:00, expected = 3h.
    test "every weekday handles today-with-time-ahead identically" do
      weekdays = [:mon, :tue, :wed, :thu, :fri, :sat, :sun]

      # Find a real Monday-through-Sunday sequence.
      # 2026-04-20 is a Monday.
      base_monday = ~D[2026-04-20]

      for {day_atom, i} <- Enum.with_index(weekdays) do
        date = Date.add(base_monday, i)
        now = DateTime.new!(date, ~T[12:00:00], "Etc/UTC")
        cadence = {:weekly, [day_atom], [~T[15:00:00]]}
        assert Cron.delay_ms(cadence, now) == 3 * 3_600_000,
               "failed for #{day_atom}"
      end
    end

    test "every weekday handles today-with-time-passed identically" do
      weekdays = [:mon, :tue, :wed, :thu, :fri, :sat, :sun]
      base_monday = ~D[2026-04-20]

      for {day_atom, i} <- Enum.with_index(weekdays) do
        date = Date.add(base_monday, i)
        now = DateTime.new!(date, ~T[12:00:00], "Etc/UTC")
        cadence = {:weekly, [day_atom], [~T[09:00:00]]}
        expected = 7 * 86_400_000 - 3 * 3_600_000
        assert Cron.delay_ms(cadence, now) == expected,
               "failed for #{day_atom}"
      end
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
