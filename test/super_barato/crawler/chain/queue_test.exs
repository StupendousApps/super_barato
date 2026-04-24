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
    chain = :"queue_test_#{System.unique_integer([:positive])}"
    {:ok, _pid} = start_supervised({Queue, chain: chain, capacity: 3})
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
end
