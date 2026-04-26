defmodule SuperBarato.Crawler.Chain.Queue do
  @moduledoc """
  Bounded FIFO task queue, one per chain. The Worker pops; Cron,
  Producer, Results, and (for requeue-on-block) Worker itself push.

  Push/pop are blocking calls — `push/2` blocks the caller when the
  queue is full; `pop/1` blocks when empty. Parked callers are held in
  internal FIFOs and serviced when the other side makes progress, so
  the queue is the backpressure primitive for the whole pipeline.

  `requeue/2` (for the Worker-on-block path) puts a task back at the
  front of the queue and bypasses the capacity check — it's a swap,
  not an add, so it shouldn't deadlock a full queue.
  """

  use GenServer

  @default_capacity 200
  @call_timeout :infinity

  # Public API

  def start_link(opts) do
    chain = Keyword.fetch!(opts, :chain)
    GenServer.start_link(__MODULE__, opts, name: via(chain))
  end

  @doc "Enqueues a task. Blocks when the queue is at capacity."
  def push(chain, task) do
    GenServer.call(via(chain), {:push, task}, @call_timeout)
  end

  @doc "Puts a task back at the front of the queue; bypasses capacity."
  def requeue(chain, task) do
    GenServer.call(via(chain), {:requeue, task}, @call_timeout)
  end

  @doc "Pops the next task. Blocks when the queue is empty."
  def pop(chain) do
    GenServer.call(via(chain), :pop, @call_timeout)
  end

  @doc "Non-blocking: current queue length."
  def size(chain) do
    GenServer.call(via(chain), :size)
  end

  @doc """
  Drops every task currently queued AND every task parked in a pending
  push. Returns the count discarded. Used by the admin "Flush queue"
  button so a runaway producer (e.g. firing 50k tasks against a broken
  parser) can be stopped without restarting the container or letting
  it drain in real time. Pending pushes get `:ok` replies so the
  producer process unblocks and exits naturally.
  """
  def clear(chain) do
    GenServer.call(via(chain), :clear)
  end

  def child_spec(opts) do
    chain = Keyword.fetch!(opts, :chain)

    %{
      id: {__MODULE__, chain},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  defp via(chain),
    do: {:via, Registry, {SuperBarato.Crawler.Registry, {__MODULE__, chain}}}

  # Server

  @impl true
  def init(opts) do
    state = %{
      chain: Keyword.fetch!(opts, :chain),
      capacity: Keyword.get(opts, :capacity, @default_capacity),
      q: :queue.new(),
      pending_pops: :queue.new(),
      pending_pushes: :queue.new()
    }

    {:ok, state}
  end

  # Push: hand directly to a waiting pop if any; else enqueue if room; else park.
  @impl true
  def handle_call({:push, task}, from, state) do
    case :queue.out(state.pending_pops) do
      {{:value, pop_from}, rest} ->
        GenServer.reply(pop_from, task)
        {:reply, :ok, %{state | pending_pops: rest}}

      {:empty, _} ->
        if :queue.len(state.q) < state.capacity do
          {:reply, :ok, %{state | q: :queue.in(task, state.q)}}
        else
          {:noreply, %{state | pending_pushes: :queue.in({from, task}, state.pending_pushes)}}
        end
    end
  end

  # Requeue: front of queue, bypasses capacity, hand directly to waiting pop if any.
  def handle_call({:requeue, task}, _from, state) do
    case :queue.out(state.pending_pops) do
      {{:value, pop_from}, rest} ->
        GenServer.reply(pop_from, task)
        {:reply, :ok, %{state | pending_pops: rest}}

      {:empty, _} ->
        {:reply, :ok, %{state | q: :queue.in_r(task, state.q)}}
    end
  end

  # Pop: hand oldest item if any; else park. When we pop, also wake a parked pusher if any.
  def handle_call(:pop, from, state) do
    case :queue.out(state.q) do
      {{:value, task}, rest} ->
        state = maybe_accept_pending_push(%{state | q: rest})
        {:reply, task, state}

      {:empty, _} ->
        # If someone is parked in push but queue is empty, that can't happen
        # (pushes only park when queue is full). Just park this pop.
        {:noreply, %{state | pending_pops: :queue.in(from, state.pending_pops)}}
    end
  end

  def handle_call(:size, _from, state) do
    {:reply, :queue.len(state.q), state}
  end

  # Drop everything queued + reply :ok to anyone parked in a push so
  # they can move on. Parked pops are left intact — they're harmless
  # and the next legitimate push will service them.
  def handle_call(:clear, _from, state) do
    queued = :queue.len(state.q)
    parked = :queue.len(state.pending_pushes)

    state.pending_pushes
    |> :queue.to_list()
    |> Enum.each(fn {pusher_from, _task} -> GenServer.reply(pusher_from, :ok) end)

    {:reply, queued + parked,
     %{state | q: :queue.new(), pending_pushes: :queue.new()}}
  end

  # After a pop frees a slot, service one parked pusher if any.
  defp maybe_accept_pending_push(state) do
    case :queue.out(state.pending_pushes) do
      {{:value, {pusher_from, task}}, rest} ->
        GenServer.reply(pusher_from, :ok)
        %{state | q: :queue.in(task, state.q), pending_pushes: rest}

      {:empty, _} ->
        state
    end
  end
end
