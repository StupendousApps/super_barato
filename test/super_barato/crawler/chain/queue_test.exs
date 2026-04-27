defmodule SuperBarato.Crawler.Chain.QueueTest do
  use ExUnit.Case, async: false

  alias SuperBarato.Crawler.Chain.Queue

  # The Queue uses {:via, Registry, ...} — make sure the Registry is running.
  setup_all do
    case Registry.start_link(keys: :unique, name: SuperBarato.Crawler.Registry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  setup do
    # Fresh chain atom per test to avoid cross-test queue state.
    # `low_water: 2` keeps the historical behavior — every pop
    # unblocks one parked pusher (gate reopens at queue len 2).
    # Watermark-batching behavior gets its own setup below.
    chain = :"queue_test_#{System.unique_integer([:positive])}"
    {:ok, _pid} = start_supervised({Queue, chain: chain, capacity: 3, low_water: 2})
    {:ok, chain: chain}
  end

  describe "push/pop (basic)" do
    test "FIFO ordering", %{chain: chain} do
      :ok = Queue.push(chain, :a)
      :ok = Queue.push(chain, :b)
      :ok = Queue.push(chain, :c)

      assert Queue.pop(chain) == :a
      assert Queue.pop(chain) == :b
      assert Queue.pop(chain) == :c
    end

    test "size reflects current queue length", %{chain: chain} do
      assert Queue.size(chain) == 0
      :ok = Queue.push(chain, :a)
      assert Queue.size(chain) == 1
      :ok = Queue.push(chain, :b)
      assert Queue.size(chain) == 2
      _ = Queue.pop(chain)
      assert Queue.size(chain) == 1
    end
  end

  describe "pop blocks when empty" do
    test "pop parks until a push happens", %{chain: chain} do
      parent = self()

      popper =
        spawn_link(fn ->
          task = Queue.pop(chain)
          send(parent, {:got, task})
        end)

      # pop should be parked — no message yet
      refute_receive {:got, _}, 50

      :ok = Queue.push(chain, :delivered)
      assert_receive {:got, :delivered}, 200

      refute Process.alive?(popper)
    end
  end

  describe "push blocks when full" do
    test "push parks when queue is at capacity; unblocks after a pop", %{chain: chain} do
      # Fill to capacity (= 3)
      :ok = Queue.push(chain, :a)
      :ok = Queue.push(chain, :b)
      :ok = Queue.push(chain, :c)
      assert Queue.size(chain) == 3

      parent = self()

      pusher =
        spawn_link(fn ->
          :ok = Queue.push(chain, :d)
          send(parent, :pushed)
        end)

      refute_receive :pushed, 50
      assert Process.alive?(pusher)

      # Pop one → pending pusher should be unblocked and :d added
      assert Queue.pop(chain) == :a
      assert_receive :pushed, 200

      # Remaining order: b, c, d
      assert Queue.pop(chain) == :b
      assert Queue.pop(chain) == :c
      assert Queue.pop(chain) == :d
    end
  end

  describe "push directly hands off to a parked pop" do
    test "when pop is already waiting, push delivers without touching the queue", %{chain: chain} do
      parent = self()

      spawn_link(fn ->
        task = Queue.pop(chain)
        send(parent, {:got, task})
      end)

      # Let the pop park
      Process.sleep(30)
      assert Queue.size(chain) == 0

      :ok = Queue.push(chain, :direct)
      assert_receive {:got, :direct}, 200

      # Nothing lingering in the queue
      assert Queue.size(chain) == 0
    end
  end

  describe "requeue" do
    test "puts task at the front of the queue", %{chain: chain} do
      :ok = Queue.push(chain, :a)
      :ok = Queue.push(chain, :b)
      :ok = Queue.requeue(chain, :urgent)

      assert Queue.pop(chain) == :urgent
      assert Queue.pop(chain) == :a
      assert Queue.pop(chain) == :b
    end

    test "bypasses capacity limit", %{chain: chain} do
      # Fill to capacity
      :ok = Queue.push(chain, :a)
      :ok = Queue.push(chain, :b)
      :ok = Queue.push(chain, :c)
      assert Queue.size(chain) == 3

      # Requeue doesn't block even though we're at cap
      :ok = Queue.requeue(chain, :urgent)
      assert Queue.size(chain) == 4

      # Front-of-queue
      assert Queue.pop(chain) == :urgent
    end

    test "hands directly to a parked pop if any", %{chain: chain} do
      parent = self()

      spawn_link(fn ->
        task = Queue.pop(chain)
        send(parent, {:got, task})
      end)

      Process.sleep(30)
      :ok = Queue.requeue(chain, :direct)
      assert_receive {:got, :direct}, 200
      assert Queue.size(chain) == 0
    end
  end

  describe "high/low watermarks: parked pushes unblock in a burst" do
    setup do
      # capacity 5, low_water 2: pushes park once size hits 5, gate
      # stays closed until pops drain to 2 — at which point ALL
      # parked pushes flood back in.
      chain = :"queue_watermark_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = start_supervised({Queue, chain: chain, capacity: 5, low_water: 2})
      {:ok, chain: chain}
    end

    test "intermediate pops do NOT unblock parked pushers (gate stays closed above low_water)",
         %{chain: chain} do
      # Fill to capacity
      for t <- [:a, :b, :c, :d, :e], do: :ok = Queue.push(chain, t)
      assert Queue.size(chain) == 5

      parent = self()

      # Park 3 pushes
      for t <- [:f, :g, :h] do
        spawn_link(fn ->
          :ok = Queue.push(chain, t)
          send(parent, {:pushed, t})
        end)
      end

      # None of the parked pushes should land yet — gate is closed
      refute_receive {:pushed, _}, 50

      # Pop once: queue 5→4. Above low_water (2). Gate stays closed.
      assert Queue.pop(chain) == :a
      refute_receive {:pushed, _}, 50

      # Pop twice more: queue 4→3→2. Now at low_water.
      assert Queue.pop(chain) == :b
      assert Queue.pop(chain) == :c

      # Gate reopens, all parked pushes flood in at once
      assert_receive {:pushed, :f}, 200
      assert_receive {:pushed, :g}, 200
      assert_receive {:pushed, :h}, 200

      # FIFO order preserved
      assert Queue.pop(chain) == :d
      assert Queue.pop(chain) == :e
      assert Queue.pop(chain) == :f
      assert Queue.pop(chain) == :g
      assert Queue.pop(chain) == :h
    end

    test "drain stops at capacity if more pushes are parked than slots free",
         %{chain: chain} do
      # Fill to capacity
      for t <- [:a, :b, :c, :d, :e], do: :ok = Queue.push(chain, t)

      parent = self()

      # Park MANY more pushes than the gap between low_water and capacity
      for t <- 1..10 do
        spawn_link(fn ->
          :ok = Queue.push(chain, t)
          send(parent, {:pushed, t})
        end)
      end

      # Drain to low_water
      Queue.pop(chain)
      Queue.pop(chain)
      Queue.pop(chain)

      # Only `capacity - low_water` = 3 pushes flood in this round
      Process.sleep(50)
      received_count = collect_pushed(0)
      assert received_count == 3, "expected 3 pushes to unblock, got #{received_count}"
      assert Queue.size(chain) == 5
    end

    defp collect_pushed(n) do
      receive do
        {:pushed, _} -> collect_pushed(n + 1)
      after
        50 -> n
      end
    end
  end

  # Tagged `:stress` — excluded from `mix test` by default. Run with:
  #
  #     mix test --include stress
  #     mix test --only stress
  #
  # Validates the watermark behavior under a real producer/worker
  # pair across ~10 seconds of wall time. The unit tests above check
  # specific transitions; this one watches the queue-size trace and
  # confirms it actually oscillates between high/low instead of
  # staying pegged at one value.
  describe "@tag :stress watermark oscillation under load" do
    @describetag :stress

    setup do
      chain = :"queue_stress_#{System.unique_integer([:positive])}"
      {:ok, _pid} = start_supervised({Queue, chain: chain, capacity: 50, low_water: 30})
      {:ok, chain: chain}
    end

    test "fast producer + slow worker → queue saw-tooths between 30 and 50",
         %{chain: chain} do
      parent = self()

      # Producer: 100 tasks as fast as backpressure allows.
      _producer =
        spawn_link(fn ->
          for i <- 1..100, do: :ok = Queue.push(chain, i)
          send(parent, :producer_done)
        end)

      # Worker: pop one per 100ms (10 req/s — fast enough to keep
      # the test under 11 seconds; the watermark behavior is
      # rate-independent).
      _worker =
        spawn_link(fn ->
          received =
            Enum.map(1..100, fn _ ->
              v = Queue.pop(chain)
              Process.sleep(100)
              v
            end)

          send(parent, {:worker_done, received})
        end)

      # Sample queue size every 100ms, 11 seconds total
      sampler =
        Task.async(fn ->
          Enum.map(1..110, fn _ ->
            Process.sleep(100)
            Queue.size(chain)
          end)
        end)

      assert_receive :producer_done, 12_000
      assert_receive {:worker_done, received}, 12_000
      samples = Task.await(sampler, 12_000)

      assert received == Enum.to_list(1..100), "FIFO order broken"

      # Behavioral assertions on the trace:
      max_seen = Enum.max(samples)
      min_seen = Enum.min(samples)
      capped = Enum.count(samples, &(&1 == 50))
      drained = Enum.count(samples, &(&1 < 30))

      # Hit capacity at least a few times during the burst phases
      assert max_seen == 50, "queue never reached capacity (max=#{max_seen})"

      # Hit at-or-below the low watermark — proves the gate closed
      # and pops drained past it
      assert min_seen <= 30, "queue never dropped to low_water (min=#{min_seen})"

      # NOT pegged at capacity — the saw-tooth happened
      refute capped == length(samples), "queue stayed pegged at capacity"

      # Saw real drain phases (queue went well below low_water before
      # the next burst, or the producer ran out)
      assert drained > 0, "queue never drained meaningfully below low_water"
    end
  end
end
