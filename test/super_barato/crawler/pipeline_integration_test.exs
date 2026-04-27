defmodule SuperBarato.Crawler.PipelineIntegrationTest do
  @moduledoc """
  End-to-end tests for the per-chain pipeline. Each test stands up a
  full `Chain.Supervisor` tree with a `StubAdapter` (so HTTP is
  deterministic), fires a Cron entry directly, and verifies the result
  landed in the DB via Catalog queries.

  Covers the two main paths:
    * discovery: Cron -> Task -> Queue.push(discover_categories) ->
      Worker -> StubAdapter -> Results -> categories table
    * products:  Cron -> ProductProducer -> Queue.push(discover_products)
      per leaf -> Worker -> StubAdapter -> Results -> chain_listings table
  """

  use SuperBarato.DataCase, async: false

  alias SuperBarato.Catalog
  alias SuperBarato.Catalog.ChainListing
  alias SuperBarato.Crawler.{Category, Listing}
  alias SuperBarato.Crawler.Chain.{Cron, Queue, Supervisor, ProductProducer}
  alias SuperBarato.Test.StubAdapter

  @chain :pipeline_int_test

  setup do
    StubAdapter.reset(@chain)

    # The Chain.Supervisor owns a Task.Supervisor sibling; its name uses
    # a Registry via-tuple keyed on the chain atom. Make sure the
    # Registry is available and no stale process exists for this chain.
    :ok
  end

  # Tiny schedule so we can fire entries directly from the test via
  # `send(cron_pid, {:fire, entry})`. Cadences are arbitrary — we never
  # wait on their timers.
  defp start_pipeline(schedule) do
    {:ok, sup} =
      start_supervised(
        {Supervisor,
         chain: @chain,
         adapter: StubAdapter,
         schedule: schedule,
         queue_capacity: 50,
         interval_ms: 10,
         fallback_profiles: [:chrome116],
         block_backoff_ms: 50}
      )

    # DB sandbox: every process that touches the DB needs ownership of
    # the connection. Grant to each pipeline child.
    for {_id, pid, _type, _mods} <- Elixir.Supervisor.which_children(sup), is_pid(pid) do
      Ecto.Adapters.SQL.Sandbox.allow(SuperBarato.Repo, self(), pid)

      # The chain-level supervisor has its own children — walk one level
      # deeper. Task.Supervisor-spawned tasks need ownership too, but we
      # grant that dynamically where we create them below.
    end

    sup
  end

  defp cron_pid(chain) do
    [{pid, _}] = Registry.lookup(SuperBarato.Crawler.Registry, {Cron, chain})
    pid
  end

  defp task_sup(chain),
    do: {:via, Registry, {SuperBarato.Crawler.Registry, {Task.Supervisor, chain}}}

  defp wait_until(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition never became true")

      true ->
        Process.sleep(25)
        do_wait(fun, deadline)
    end
  end

  describe "full discovery path (Cron → Queue → Worker → Results → DB)" do
    test "categories land in the DB" do
      # 1. Program the stub: responding to :discover_categories with a
      #    fake category tree.
      StubAdapter.set_response(@chain, :discover_categories, {:ok, sample_categories()})

      # 2. Define the schedule. The cadence doesn't matter because we'll
      #    fire entries directly.
      schedule = [
        {{:every, {1, :day}},
         {Queue, :push, [@chain, {:discover_categories, %{chain: @chain, parent: nil}}]}}
      ]

      _sup = start_pipeline(schedule)

      # 3. Fire the discovery entry.
      send(cron_pid(@chain), {:fire, hd(schedule)})

      # 4. Wait for persistence.
      wait_until(fn -> Repo.one(from c in Catalog.Category, select: count(c.id)) == 3 end)

      # 5. Verify the DB contents.
      cats = Repo.all(from c in Catalog.Category, order_by: c.slug)

      slugs = Enum.map(cats, & &1.slug)
      assert slugs == ["despensa", "despensa/arroz", "despensa/conservas"]

      leaves = Enum.filter(cats, & &1.is_leaf) |> Enum.map(& &1.slug)
      assert Enum.sort(leaves) == ["despensa/arroz", "despensa/conservas"]

      # Adapter received the task once
      assert length(StubAdapter.received(@chain)) == 1
    end
  end

  describe "full product-discovery path (Cron → Producer → Queue → Worker → Results → DB)" do
    test "listings land in the DB for every leaf category" do
      # 1. Seed the categories table (ProductProducer reads from here).
      seed_leaf_categories(["despensa/arroz", "despensa/conservas"])

      # 2. Program the stub: responds to :discover_products with a
      #    tiny listing for whatever slug it's asked about.
      StubAdapter.set_response(@chain, :discover_products, fn {:discover_products, %{slug: slug}} ->
        ean = "790#{:erlang.phash2(slug, 1_000_000_000)}"

        {:ok,
         [
           %Listing{
             chain: @chain,
             chain_sku: "sku-#{slug}",
             ean: ean,
             identifiers_key: "ean=#{ean},sku=sku-#{slug}",
             name: "Product for #{slug}",
             brand: "Test",
             category_path: slug,
             regular_price: 1990
           }
         ]}
      end)

      # 3. Schedule entry that spawns the producer.
      schedule = [
        {{:every, {1, :day}}, {ProductProducer, :run, [[chain: @chain]]}}
      ]

      _sup = start_pipeline(schedule)

      # 4. Fire the producer entry. Cron does
      #    Task.Supervisor.start_child(state.task_sup, fn -> apply(...) end);
      #    the spawned task calls ProductProducer.run, which streams
      #    leaf categories from the DB and pushes Queue tasks.
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), GenServer.whereis(task_sup(@chain)))

      send(cron_pid(@chain), {:fire, hd(schedule)})

      # 5. Wait for Worker to consume both product tasks and Results to persist.
      wait_until(fn ->
        Repo.one(
          from l in ChainListing, where: l.chain == ^to_string(@chain), select: count(l.id)
        ) == 2
      end)

      listings =
        Repo.all(
          from l in ChainListing,
            where: l.chain == ^to_string(@chain),
            order_by: l.chain_sku
        )

      assert [l1, l2] = listings
      assert l1.chain_sku == "sku-despensa/arroz"
      assert l2.chain_sku == "sku-despensa/conservas"
      assert Enum.all?(listings, &(&1.current_regular_price == 1990))

      # Stub received one task per leaf category
      assert length(StubAdapter.received(@chain)) == 2
    end
  end

  # -- helpers --

  defp sample_categories do
    [
      %Category{chain: @chain, slug: "despensa", name: "Despensa", level: 1, is_leaf: false},
      %Category{
        chain: @chain,
        slug: "despensa/arroz",
        name: "Arroz",
        parent_slug: "despensa",
        level: 2,
        is_leaf: true
      },
      %Category{
        chain: @chain,
        slug: "despensa/conservas",
        name: "Conservas",
        parent_slug: "despensa",
        level: 2,
        is_leaf: true
      }
    ]
  end

  defp seed_leaf_categories(slugs) do
    Enum.each(slugs, fn slug ->
      {:ok, _} =
        Catalog.upsert_category(%Category{
          chain: @chain,
          slug: slug,
          name: slug,
          parent_slug: "despensa",
          level: 2,
          is_leaf: true
        })
    end)
  end
end
