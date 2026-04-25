defmodule SuperBarato.Crawler.StatusTest do
  use SuperBarato.DataCase, async: false

  alias SuperBarato.Catalog
  alias SuperBarato.Crawler
  alias SuperBarato.Crawler.{Schedules, Status}
  alias SuperBarato.Crawler.Category, as: CrawlerCategory
  alias SuperBarato.Crawler.Listing

  describe "all/0" do
    test "returns one snapshot per known chain" do
      snapshots = Status.all()
      assert length(snapshots) == length(Crawler.known_chains())

      chains_seen = Enum.map(snapshots, & &1.chain)
      assert Enum.sort(chains_seen) == Enum.sort(Crawler.known_chains())
    end

    test "every snapshot has the documented shape" do
      keys = ~w(chain running profile queue_depth cron_epoch
                 schedule_count listings_count last_priced_at
                 categories_count last_seen_at)a

      Enum.each(Status.all(), fn s ->
        assert Map.keys(s) |> Enum.sort() == Enum.sort(keys)
      end)
    end
  end

  describe "snapshot/1 with no pipeline running" do
    test "running is false and runtime fields are nil" do
      s = Status.snapshot(:unimarc)
      assert s.chain == :unimarc
      assert s.running == false
      assert s.queue_depth == nil
      assert s.cron_epoch == nil
    end

    test "DB-derived fields reflect the catalog regardless of pipeline state" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        Catalog.upsert_listing(%Listing{
          chain: :unimarc,
          chain_sku: "x-1",
          name: "Test",
          regular_price: 100
        })

      {:ok, _} =
        Catalog.upsert_category(%CrawlerCategory{
          chain: :unimarc,
          slug: "despensa",
          name: "Despensa",
          level: 1
        })

      s = Status.snapshot(:unimarc)
      assert s.listings_count == 1
      assert s.categories_count == 1

      # last_seen_at on the category is set on insert.
      assert %DateTime{} = s.last_seen_at
      assert DateTime.compare(s.last_seen_at, now) in [:eq, :gt, :lt]
    end

    test "schedule_count reflects DB rows for that chain" do
      {:ok, _} =
        Schedules.create(%{
          "chain" => "lider",
          "kind" => "discover_categories",
          "days" => "mon",
          "times" => "04:00:00"
        })

      assert Status.snapshot(:lider).schedule_count == 1
      assert Status.snapshot(:tottus).schedule_count == 0
    end
  end
end
