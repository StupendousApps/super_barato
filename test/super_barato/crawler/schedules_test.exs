defmodule SuperBarato.Crawler.SchedulesTest do
  use SuperBarato.DataCase, async: false

  alias SuperBarato.Crawler.{Schedule, Schedules}
  alias SuperBarato.Crawler.Chain.SchedulerServer

  describe "list/1" do
    setup do
      {:ok, _} = insert_schedule(:unimarc, "discover_categories", "mon", "04:00:00")
      {:ok, _} = insert_schedule(:unimarc, "discover_products", "mon,tue", "05:00:00")
      {:ok, _} = insert_schedule(:jumbo, "discover_categories", "mon", "04:15:00")
      :ok
    end

    test "no filters returns everything ordered by chain then kind" do
      rows = Schedules.list()
      chains = Enum.map(rows, & &1.chain)
      kinds = Enum.map(rows, & &1.kind)
      assert chains == ["jumbo", "unimarc", "unimarc"]
      assert kinds == ["discover_categories", "discover_categories", "discover_products"]
    end

    test "filters by chain (atom or string)" do
      assert Schedules.list(chain: :unimarc) |> length() == 2
      assert Schedules.list(chain: "unimarc") |> length() == 2
      assert Schedules.list(chain: :jumbo) |> length() == 1
    end

    test "filters by kind" do
      assert Schedules.list(kind: "discover_categories") |> length() == 2
      assert Schedules.list(kind: "discover_products") |> length() == 1
    end

    test "ignores empty-string filters" do
      assert Schedules.list(chain: "", kind: "") |> length() == 3
    end
  end

  describe "list_for/1" do
    test "scopes to one chain (atom or string)" do
      {:ok, _} = insert_schedule(:unimarc, "discover_categories", "mon", "04:00:00")
      {:ok, _} = insert_schedule(:jumbo, "discover_categories", "mon", "04:15:00")

      assert Schedules.list_for(:unimarc) |> length() == 1
      assert Schedules.list_for("jumbo") |> length() == 1
    end
  end

  describe "create/1, update/2, delete/1" do
    test "create inserts and returns the row" do
      attrs = %{
        "chain" => "unimarc",
        "kind" => "discover_categories",
        "days" => "mon",
        "times" => "04:00:00"
      }

      {:ok, %Schedule{} = s} = Schedules.create(attrs)
      assert s.id
      assert s.active == true
      assert Schedules.list() |> length() == 1
    end

    test "create rejects invalid attrs" do
      assert {:error, %Ecto.Changeset{}} = Schedules.create(%{"chain" => "walmart"})
    end

    test "update edits an existing row" do
      {:ok, s} = insert_schedule(:unimarc, "discover_categories", "mon", "04:00:00")
      {:ok, updated} = Schedules.update(s, %{"days" => "tue,thu"})
      assert updated.days == "tue,thu"
    end

    test "update returns a changeset error on invalid input" do
      {:ok, s} = insert_schedule(:unimarc, "discover_categories", "mon", "04:00:00")
      assert {:error, %Ecto.Changeset{}} = Schedules.update(s, %{"days" => "garbage"})
    end

    test "delete removes the row" do
      {:ok, s} = insert_schedule(:unimarc, "discover_categories", "mon", "04:00:00")
      {:ok, _} = Schedules.delete(s)
      assert Schedules.list() == []
    end
  end

  describe "cron_entries/1" do
    test "returns {cadence, mfa} tuples for active rows only" do
      {:ok, _} = insert_schedule(:unimarc, "discover_categories", "mon", "04:00:00", active: true)

      {:ok, _} =
        insert_schedule(:unimarc, "discover_products", "mon,tue", "05:00:00", active: false)

      entries = Schedules.cron_entries(:unimarc)
      assert length(entries) == 1

      [{cadence, mfa}] = entries
      assert {:weekly, [:mon], [~T[04:00:00]]} = cadence

      assert {SuperBarato.Crawler.Chain.CategoryProducer, :run, [[chain: :unimarc]]} = mfa
    end

    test "returns [] for a chain with no schedules" do
      assert Schedules.cron_entries(:tottus) == []
    end
  end

  describe "seed_from_config/0" do
    test "is idempotent — does not duplicate existing rows" do
      n = Schedules.seed_from_config()
      first_count = Schedules.list() |> length()

      ^n = Schedules.seed_from_config()
      assert Schedules.list() |> length() == first_count
    end

    test "leaves existing rows alone (admin edits aren't clobbered)" do
      Schedules.seed_from_config()
      [s | _] = Schedules.list_for(:unimarc)
      {:ok, _} = Schedules.update(s, %{"days" => "tue", "note" => "edited"})

      Schedules.seed_from_config()
      [reloaded | _] = Schedules.list_for(:unimarc)
      assert reloaded.days == "tue"
      assert reloaded.note == "edited"
    end
  end

  describe "mutations trigger SchedulerServer reload" do
    setup do
      {:ok, task_sup} = Task.Supervisor.start_link()

      cron_pid =
        start_supervised!({
          SchedulerServer,
          chain: :unimarc, schedule: Schedules.cron_entries(:unimarc), task_sup: task_sup
        })

      {:ok, cron: cron_pid}
    end

    test "create bumps the cron epoch", %{cron: cron} do
      before = :sys.get_state(cron).epoch

      {:ok, _} = insert_schedule(:unimarc, "discover_categories", "wed", "06:00:00")

      Process.sleep(50)
      assert :sys.get_state(cron).epoch == before + 1
    end

    test "update bumps the cron epoch", %{cron: cron} do
      {:ok, s} = insert_schedule(:unimarc, "discover_categories", "mon", "04:00:00")
      before = :sys.get_state(cron).epoch
      {:ok, _} = Schedules.update(s, %{"days" => "tue"})

      Process.sleep(50)
      assert :sys.get_state(cron).epoch == before + 1
    end

    test "delete bumps the cron epoch", %{cron: cron} do
      {:ok, s} = insert_schedule(:unimarc, "discover_categories", "mon", "04:00:00")
      before = :sys.get_state(cron).epoch
      {:ok, _} = Schedules.delete(s)

      Process.sleep(50)
      assert :sys.get_state(cron).epoch == before + 1
    end

    test "stale timers from before reload are dropped (no double-fire)", %{cron: cron} do
      # Manually arm a stale timer at the current epoch, then bump the
      # epoch via an update. The pre-bump :fire is now stale and
      # handle_info should drop it without dispatching.
      {:ok, s} = insert_schedule(:unimarc, "discover_categories", "mon", "04:00:00")
      before = :sys.get_state(cron).epoch

      stale_entry =
        {{:weekly, [:mon], [~T[04:00:00]]},
         {SuperBarato.Crawler.Chain.QueueServer, :push,
          [:unimarc, {:discover_categories, %{chain: :unimarc, parent: nil}}]}}

      {:ok, _} = Schedules.update(s, %{"days" => "tue"})
      Process.sleep(50)

      send(cron, {:fire, stale_entry, before})
      Process.sleep(20)

      # Process is still alive and on the new epoch.
      state = :sys.get_state(cron)
      assert state.epoch == before + 1
    end
  end

  defp insert_schedule(chain, kind, days, times, opts \\ []) do
    Schedules.create(%{
      "chain" => Atom.to_string(chain),
      "kind" => kind,
      "days" => days,
      "times" => times,
      "active" => Keyword.get(opts, :active, true)
    })
  end
end
