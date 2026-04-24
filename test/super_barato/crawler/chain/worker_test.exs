defmodule SuperBarato.Crawler.Chain.WorkerTest do
  # Using DataCase so the Worker → Results → DB chain has a sandbox
  # connection available (shared mode — async: false).
  use SuperBarato.DataCase, async: false

  alias SuperBarato.Crawler.Chain.{Queue, Results, Worker}
  alias SuperBarato.Crawler.Session
  alias SuperBarato.Test.StubAdapter

  setup do
    chain = :"worker_test_#{System.unique_integer([:positive])}"
    Session.put(chain, :profile, nil)
    StubAdapter.reset(chain)

    {:ok, _q} = start_supervised({Queue, chain: chain, capacity: 10}, id: {:q, chain})
    {:ok, _r} = start_supervised({Results, chain: chain, adapter: StubAdapter}, id: {:r, chain})

    # Make sure any pending Results casts drain before the sandbox is
    # torn down, so we don't see spurious "ownership" warnings if a
    # happy-path test wrote through Results.
    on_exit(fn ->
      case Registry.lookup(SuperBarato.Crawler.Registry, {Results, chain}) do
        [{pid, _}] -> if Process.alive?(pid), do: :sys.get_state(pid)
        _ -> :ok
      end
    end)

    {:ok, chain: chain}
  end

  defp start_worker(chain, opts \\ []) do
    base = [
      chain: chain,
      adapter: StubAdapter,
      interval_ms: 10,
      fallback_profiles: [:chrome116, :chrome107],
      block_backoff_ms: 50
    ]

    {:ok, _w} = start_supervised({Worker, Keyword.merge(base, opts)}, id: {:w, chain})
    :ok
  end

  describe "happy path" do
    test "pops a task, dispatches to adapter, calls Results", %{chain: chain} do
      StubAdapter.set_response(chain, :discover_products, {:ok, [fake_listing(chain)]})
      :ok = start_worker(chain)

      :ok = Queue.push(chain, {:discover_products, %{chain: chain, slug: "test-cat"}})

      # Wait for worker to consume the task — adapter records receipts.
      assert_receive_task(chain, 500)

      # Queue should be empty after consumption.
      assert Queue.size(chain) == 0
    end
  end

  describe "blocked path" do
    @tag :capture_log
    test "rotates profile and requeues the task", %{chain: chain} do
      # Configure stub to always say :blocked.
      StubAdapter.set_response(chain, :discover_products, :blocked)
      :ok = start_worker(chain)

      :ok = Queue.push(chain, {:discover_products, %{chain: chain, slug: "x"}})

      # Wait for at least one rotation cycle: worker pops, gets :blocked,
      # rotates profile, requeues. With 2 profiles and a 50ms backoff,
      # it'll cycle: chrome116 (block) -> chrome107 (block) -> sleep 50ms
      # -> chrome116 again...
      Process.sleep(150)

      # Profile should have been rotated at least once.
      assert Session.get(chain, :profile) in [:chrome116, :chrome107]
    end
  end

  describe "error path" do
    @tag :capture_log
    test "errors from adapter do not requeue or rotate", %{chain: chain} do
      StubAdapter.set_response(chain, :discover_products, {:error, :boom})
      :ok = start_worker(chain)

      :ok = Queue.push(chain, {:discover_products, %{chain: chain, slug: "x"}})

      Process.sleep(50)

      # Queue drained (task was consumed), no requeue.
      assert Queue.size(chain) == 0

      # Profile untouched — stays nil (default).
      assert Session.get(chain, :profile) == nil
    end
  end

  describe "interval gap" do
    test "waits between HTTP calls", %{chain: chain} do
      parent = self()

      StubAdapter.set_response(chain, :discover_products, fn _task ->
        send(parent, {:tick, System.monotonic_time(:millisecond)})
        {:ok, [fake_listing(chain)]}
      end)

      :ok = start_worker(chain, interval_ms: 100)

      for i <- 1..3 do
        :ok = Queue.push(chain, {:discover_products, %{chain: chain, slug: "s-#{i}"}})
      end

      assert_receive {:tick, t1}, 500
      assert_receive {:tick, t2}, 500
      assert_receive {:tick, t3}, 500

      assert t2 - t1 >= 90
      assert t3 - t2 >= 90
    end
  end

  # --- helpers ---

  defp fake_listing(chain) do
    %SuperBarato.Crawler.Listing{
      chain: chain,
      chain_sku: "sku-#{System.unique_integer([:positive])}",
      name: "Test",
      regular_price: 100
    }
  end

  # Busy-wait until the stub sees any task for this chain. Tests use
  # this as the cheap "did the worker do anything?" signal.
  defp assert_receive_task(chain, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_task(chain, deadline)
  end

  defp do_wait_task(chain, deadline) do
    cond do
      StubAdapter.received(chain) != [] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("stub never received a task for #{inspect(chain)}")

      true ->
        Process.sleep(10)
        do_wait_task(chain, deadline)
    end
  end
end
