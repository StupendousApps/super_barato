defmodule SuperBarato.Crawler.Chain.ProductProducerTest do
  use SuperBarato.DataCase, async: false

  alias SuperBarato.Catalog
  alias SuperBarato.Crawler.ChainCategory
  alias SuperBarato.Crawler.Chain.{ProductProducer, Queue}

  @chain :unimarc

  setup do
    {:ok, _} = start_supervised({Queue, chain: @chain, capacity: 100})
    :ok
  end

  describe "run/1" do
    test "pushes one :discover_products task per leaf category" do
      seed_categories([
        %{slug: "despensa", is_leaf: false},
        %{slug: "despensa/arroz", parent_slug: "despensa", is_leaf: true},
        %{slug: "despensa/pastas", parent_slug: "despensa", is_leaf: true},
        %{slug: "despensa/conservas", parent_slug: "despensa", is_leaf: false}
      ])

      ProductProducer.run(chain: @chain)

      assert Queue.size(@chain) == 2

      task_a = Queue.pop(@chain)
      task_b = Queue.pop(@chain)

      slugs = [task_a, task_b] |> Enum.map(fn {:discover_products, %{slug: s}} -> s end)
      assert Enum.sort(slugs) == ["despensa/arroz", "despensa/pastas"]
    end

    test "pushes nothing when no leaf categories exist" do
      ProductProducer.run(chain: @chain)
      assert Queue.size(@chain) == 0
    end

    test "skips non-leaf categories even if they have a slug" do
      seed_categories([
        %{slug: "a", is_leaf: false},
        %{slug: "b", is_leaf: false}
      ])

      ProductProducer.run(chain: @chain)
      assert Queue.size(@chain) == 0
    end
  end

  defp seed_categories(rows) do
    Enum.each(rows, fn row ->
      cat = %ChainCategory{
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
