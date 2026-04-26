defmodule SuperBarato.Crawler.ScheduleTest do
  use ExUnit.Case, async: true

  alias SuperBarato.Crawler.Schedule

  describe "parse_days/1" do
    test "accepts a single day" do
      assert {:ok, [:mon]} = Schedule.parse_days("mon")
    end

    test "accepts every day in any order, ignoring whitespace" do
      assert {:ok, atoms} = Schedule.parse_days("mon, tue,wed , thu,fri,sat,sun")
      assert atoms == [:mon, :tue, :wed, :thu, :fri, :sat, :sun]
    end

    test "rejects unknown day tokens" do
      assert {:error, ["xx"]} = Schedule.parse_days("mon,xx")
      assert {:error, bad} = Schedule.parse_days("foo,bar,mon")
      assert "foo" in bad and "bar" in bad
    end

    test "errors on an empty string" do
      assert {:error, ["(empty)"]} = Schedule.parse_days("")
    end
  end

  describe "parse_times/1" do
    test "accepts canonical HH:MM:SS" do
      assert {:ok, [~T[04:00:00]]} = Schedule.parse_times("04:00:00")
    end

    test "accepts HH:MM (what the time picker submits) by appending :00" do
      assert {:ok, [~T[04:30:00]]} = Schedule.parse_times("04:30")
    end

    test "accepts a comma-separated mix of HH:MM and HH:MM:SS" do
      assert {:ok, [~T[04:00:00], ~T[14:30:00]]} = Schedule.parse_times("04:00,14:30:00")
    end

    test "rejects malformed times" do
      assert {:error, ["nope"]} = Schedule.parse_times("nope")
      assert {:error, ["25:99"]} = Schedule.parse_times("25:99")
    end

    test "errors on an empty string" do
      assert {:error, ["(empty)"]} = Schedule.parse_times("")
    end
  end

  describe "changeset/2" do
    @valid %{
      "chain" => "unimarc",
      "kind" => "discover_categories",
      "days" => "mon",
      "times" => "04:00:00",
      "active" => true
    }

    test "is valid with the canonical attrs" do
      assert Schedule.changeset(%Schedule{}, @valid).valid?
    end

    test "rejects unknown chain" do
      cs = Schedule.changeset(%Schedule{}, Map.put(@valid, "chain", "walmart"))
      refute cs.valid?
      assert {"must be one of: " <> _, _} = cs.errors[:chain]
    end

    test "rejects unknown kind" do
      cs = Schedule.changeset(%Schedule{}, Map.put(@valid, "kind", "discover_prices"))
      refute cs.valid?
      assert cs.errors[:kind]
    end

    test "rejects malformed days" do
      cs = Schedule.changeset(%Schedule{}, Map.put(@valid, "days", "monday,tu"))
      refute cs.valid?
      {msg, _} = cs.errors[:days]
      assert String.contains?(msg, "monday")
    end

    test "rejects malformed times" do
      cs = Schedule.changeset(%Schedule{}, Map.put(@valid, "times", "nope"))
      refute cs.valid?
      {msg, _} = cs.errors[:times]
      assert String.contains?(msg, "nope")
    end

    test "requires chain, kind, days, times" do
      cs = Schedule.changeset(%Schedule{}, %{})
      refute cs.valid?

      Enum.each([:chain, :kind, :days, :times], fn field ->
        assert cs.errors[field], "expected required error on #{field}"
      end)
    end
  end

  describe "to_cron_entry/1" do
    test "skips inactive schedules" do
      s = %Schedule{
        chain: "unimarc",
        kind: "discover_categories",
        days: "mon",
        times: "04:00:00",
        active: false
      }

      assert Schedule.to_cron_entry(s) == :skip
    end

    test "discover_categories renders a Queue.push MFA" do
      s = %Schedule{
        chain: "unimarc",
        kind: "discover_categories",
        days: "mon",
        times: "04:00:00",
        active: true
      }

      assert {:ok, {{:weekly, [:mon], [~T[04:00:00]]},
              {SuperBarato.Crawler.Chain.Queue, :push,
               [:unimarc, {:discover_categories, %{chain: :unimarc, parent: nil}}]}}} =
               Schedule.to_cron_entry(s)
    end

    test "discover_products for jumbo renders a Cencosud SitemapProducer MFA" do
      s = %Schedule{
        chain: "jumbo",
        kind: "discover_products",
        days: "mon,tue,wed,thu,fri,sat,sun",
        times: "05:00:00",
        active: true
      }

      assert {:ok, {{:weekly, days, [~T[05:00:00]]},
              {SuperBarato.Crawler.Cencosud.SitemapProducer, :run, [[chain: :jumbo]]}}} =
               Schedule.to_cron_entry(s)

      assert days == [:mon, :tue, :wed, :thu, :fri, :sat, :sun]
    end

    test "discover_products for non-Cencosud chains keeps the original ProductProducer" do
      s = %Schedule{
        chain: "unimarc",
        kind: "discover_products",
        days: "mon",
        times: "05:00:00",
        active: true
      }

      assert {:ok, {_,
              {SuperBarato.Crawler.Chain.ProductProducer, :run, [[chain: :unimarc]]}}} =
               Schedule.to_cron_entry(s)
    end
  end

  describe "string round-trip helpers" do
    test "days_to_string/1 + parse_days/1 round-trip" do
      atoms = [:mon, :wed, :fri]
      s = Schedule.days_to_string(atoms)
      assert {:ok, ^atoms} = Schedule.parse_days(s)
    end

    test "times_to_string/1 + parse_times/1 round-trip" do
      times = [~T[04:00:00], ~T[14:30:00]]
      s = Schedule.times_to_string(times)
      assert {:ok, ^times} = Schedule.parse_times(s)
    end
  end
end
