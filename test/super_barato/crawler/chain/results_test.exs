defmodule SuperBarato.Crawler.Chain.ResultsTest do
  use SuperBarato.DataCase, async: false

  alias SuperBarato.{Catalog, PriceLog}
  alias SuperBarato.Catalog.ChainListing
  alias SuperBarato.Crawler.Category, as: CrawlerCategory
  alias SuperBarato.Crawler.Listing
  alias SuperBarato.Crawler.Chain.Results
  alias SuperBarato.Test.StubAdapter

  setup do
    chain = :"results_test_#{System.unique_integer([:positive])}"
    StubAdapter.reset(chain)
    # StubAdapter's refresh_identifier/0 returns :ean — good for refresh tests below.
    {:ok, _pid} = start_supervised({Results, chain: chain, adapter: StubAdapter})

    # Point PriceLog at a temp dir for this test.
    log_dir =
      Path.join(System.tmp_dir!(), "sb_results_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(log_dir)
    original = Application.get_env(:super_barato, :price_log_dir)
    Application.put_env(:super_barato, :price_log_dir, log_dir)

    on_exit(fn ->
      if original do
        Application.put_env(:super_barato, :price_log_dir, original)
      else
        Application.delete_env(:super_barato, :price_log_dir)
      end

      File.rm_rf!(log_dir)
    end)

    {:ok, chain: chain}
  end

  describe "record/3 with :discover_categories task" do
    test "upserts every category from the payload", %{chain: chain} do
      cats = [
        %CrawlerCategory{chain: chain, slug: "despensa", name: "Despensa", level: 1},
        %CrawlerCategory{
          chain: chain,
          slug: "despensa/aceites",
          name: "Aceites",
          parent_slug: "despensa",
          level: 2,
          is_leaf: true
        }
      ]

      :ok = Results.record(chain, {:discover_categories, %{chain: chain, parent: nil}}, cats)

      flush_results(chain)

      assert Catalog.leaf_categories(chain) |> length() == 1
      [leaf] = Catalog.leaf_categories(chain)
      assert leaf.slug == "despensa/aceites"
      assert leaf.parent_slug == "despensa"
    end
  end

  describe "record/3 with :discover_products task" do
    test "upserts every listing AND appends each price to its log file", %{chain: chain} do
      listings = [
        %Listing{
          chain: chain,
          chain_sku: "sku-1",
          ean: "7801234567890",
          name: "Arroz 1kg",
          brand: "Marca A",
          category_path: "despensa/arroz",
          regular_price: 1490
        },
        %Listing{
          chain: chain,
          chain_sku: "sku-2",
          ean: "7809876543210",
          name: "Aceite 1L",
          brand: "Marca B",
          category_path: "despensa/aceites",
          regular_price: 2490,
          promo_price: 1990
        }
      ]

      :ok =
        Results.record(
          chain,
          {:discover_products, %{chain: chain, slug: "despensa"}},
          listings
        )

      flush_results(chain)

      # DB: both upserted with current_* columns set.
      rows =
        Repo.all(
          from l in ChainListing,
            where: l.chain == ^to_string(chain),
            order_by: l.chain_sku
        )

      assert [l1, l2] = rows
      assert l1.chain_sku == "sku-1" and l1.current_regular_price == 1490
      assert l2.chain_sku == "sku-2" and l2.current_promo_price == 1990

      # Logs: one line per product, with the right price shape.
      [{_, 1490, nil}] = PriceLog.read(chain, "sku-1")
      [{_, 2490, 1990}] = PriceLog.read(chain, "sku-2")
    end

    test "listings without a chain_sku or regular_price are skipped for the log",
         %{chain: chain} do
      listings = [
        # No price — upsert happens but no log line.
        %Listing{
          chain: chain,
          chain_sku: "sku-noprice",
          name: "X",
          regular_price: nil
        }
      ]

      :ok =
        Results.record(
          chain,
          {:discover_products, %{chain: chain, slug: "x"}},
          listings
        )

      flush_results(chain)

      assert PriceLog.read(chain, "sku-noprice") == []
    end
  end

  describe "record/3 with :fetch_product_info task (single-SKU refresh)" do
    setup %{chain: chain} do
      {:ok, existing} =
        Catalog.upsert_listing(%Listing{
          chain: chain,
          chain_sku: "123",
          ean: "7801234567890",
          name: "Arroz 1kg",
          regular_price: 1490
        })

      {:ok, existing: existing}
    end

    test "updates current_* on the listing and appends to the log", %{chain: chain} do
      refreshed = [
        %Listing{
          chain: chain,
          chain_sku: "123",
          ean: "7801234567890",
          name: "Arroz 1kg",
          regular_price: 1490,
          promo_price: 990
        }
      ]

      :ok =
        Results.record(
          chain,
          {:fetch_product_info, %{chain: chain, identifiers: ["7801234567890"]}},
          refreshed
        )

      flush_results(chain)

      [listing] = Repo.all(ChainListing)
      assert listing.current_promo_price == 990
      refute is_nil(listing.last_priced_at)

      [{_t, 1490, 990}] = PriceLog.read(chain, "123")
    end

    test "skips listings that aren't in the DB (unknown identifier)", %{chain: chain} do
      fresh = [
        %Listing{
          chain: chain,
          chain_sku: "UNKNOWN",
          ean: "0000000000000",
          name: "Unknown",
          regular_price: 100
        }
      ]

      :ok =
        Results.record(
          chain,
          {:fetch_product_info, %{chain: chain, identifiers: ["0000000000000"]}},
          fresh
        )

      flush_results(chain)

      # Nothing logged (the DB lookup failed; PriceLog isn't called).
      assert PriceLog.read(chain, "UNKNOWN") == []
    end
  end

  # Wait for the async cast to drain by round-tripping a :sys.get_state
  # through the Results GenServer.
  defp flush_results(chain) do
    :sys.get_state({:via, Registry, {SuperBarato.Crawler.Registry, {Results, chain}}})
  end
end
