defmodule SuperBarato.Crawler.Chain.ProductProducerTest do
  use SuperBarato.DataCase, async: false

  alias SuperBarato.Catalog
  alias SuperBarato.Crawler.{Category, Listing}
  alias SuperBarato.Crawler.Chain.{ProductProducer, Queue}

  # ProductProducer reads `SuperBarato.Crawler.adapter(chain).refresh_identifier()`
  # in :prices mode. Bind to the `:unimarc` adapter (which returns `:ean`).
  @chain :unimarc

  setup do
    {:ok, _} = start_supervised({Queue, chain: @chain, capacity: 100})
    :ok
  end

  describe ":products mode" do
    test "pushes one task per leaf category" do
      seed_categories([
        %{slug: "despensa", is_leaf: false},
        %{slug: "despensa/arroz", parent_slug: "despensa", is_leaf: true},
        %{slug: "despensa/pastas", parent_slug: "despensa", is_leaf: true},
        %{slug: "despensa/conservas", parent_slug: "despensa", is_leaf: false}
      ])

      ProductProducer.run(chain: @chain, mode: :products)

      assert Queue.size(@chain) == 2

      task_a = Queue.pop(@chain)
      task_b = Queue.pop(@chain)

      # Order may vary by primary-key insert order; compare as a set.
      slugs = [task_a, task_b] |> Enum.map(fn {:discover_products, %{slug: s}} -> s end)
      assert Enum.sort(slugs) == ["despensa/arroz", "despensa/pastas"]
    end

    test "pushes nothing when no leaf categories exist" do
      ProductProducer.run(chain: @chain, mode: :products)
      assert Queue.size(@chain) == 0
    end
  end

  describe ":prices mode" do
    test "chunks active identifiers into batches of 25" do
      # Insert 60 listings → should produce 3 task batches of sizes 25, 25, 10
      for n <- 1..60 do
        {:ok, _} =
          Catalog.upsert_listing(%Listing{
            chain: @chain,
            chain_sku: "sku-#{n}",
            ean: String.pad_leading(Integer.to_string(n), 13, "0"),
            name: "Product #{n}",
            regular_price: 1000
          })
      end

      ProductProducer.run(chain: @chain, mode: :prices)

      assert Queue.size(@chain) == 3

      tasks =
        for _ <- 1..3 do
          Queue.pop(@chain)
        end

      sizes = Enum.map(tasks, fn {:fetch_product_info, %{identifiers: ids}} -> length(ids) end)
      assert Enum.sort(sizes, :desc) == [25, 25, 10]

      # All tasks carry the chain and well-formed identifier batches.
      Enum.each(tasks, fn {:fetch_product_info, %{chain: c, identifiers: ids}} ->
        assert c == @chain
        assert Enum.all?(ids, &is_binary/1)
      end)
    end

    test "skips listings without the refresh identifier (EAN)" do
      {:ok, _} =
        Catalog.upsert_listing(%Listing{
          chain: @chain,
          chain_sku: "sku-only",
          ean: nil,
          name: "No EAN",
          regular_price: 100
        })

      ProductProducer.run(chain: @chain, mode: :prices)
      assert Queue.size(@chain) == 0
    end
  end

  defp seed_categories(rows) do
    Enum.each(rows, fn row ->
      cat = %Category{
        chain: @chain,
        slug: row.slug,
        name: row[:name] || row.slug,
        parent_slug: row[:parent_slug],
        level: row[:level] || String.split(row.slug, "/") |> length(),
        is_leaf: row.is_leaf
      }

      {:ok, _} = Catalog.upsert_category(cat)
    end)
  end
end
