defmodule SuperBarato.Crawler.Chain.QueueServer do
  @moduledoc """
  Bounded FIFO task queue with **high/low watermark backpressure**,
  one per chain. The FetcherServer pops; SchedulerServer, Producers,
  PersistenceServer, and (for requeue-on-block) FetcherServer itself
  push.

  Push/pop are blocking calls — `push/2` parks the caller when the
  queue is full or the gate is closed; `pop/1` parks when empty.
  Parked callers are held in internal FIFOs.

  ## Watermarks

  Naive backpressure (release one parked push per pop) keeps the
  queue at `capacity-1 ↔ capacity` in steady state — invisible
  oscillation. With watermarks the queue runs in **bursts**:

    * Producer pushes freely until `:capacity` (high watermark).
    * At `:capacity`, the gate closes; further pushes park.
    * Pops drain the queue normally, parked pushes stay parked.
    * When the queue drains to `:low_water`, the gate reopens and
      all parked pushes flood back in (up to `:capacity`).

  Default `capacity: 50`, `low_water: 30`. The producer wakes up to
  push 20 tasks at once every ~30 seconds (worker drains at 1 req/s),
  giving a much more useful queue-size signal in the dashboard.

  `requeue/2` (worker-on-block path) bypasses both the gate and the
  capacity check — it's a swap, not an add.
  """

  use GenServer

  @default_capacity 50
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
    capacity = Keyword.get(opts, :capacity, @default_capacity)
    # Allow the caller to opt into a tighter low-water than the
    # default. Clamp to (0, capacity) so a misconfig can't deadlock
    # the gate.
    low_water =
      opts
      |> Keyword.get(:low_water, default_low_water(capacity))
      |> max(0)
      |> min(capacity)

    state = %{
      chain: Keyword.fetch!(opts, :chain),
      capacity: capacity,
      low_water: low_water,
      # Gate `open?` controls whether *new* pushes go straight into
      # the queue. Closes when we hit `capacity`; reopens when pops
      # drain below `low_water`.
      open?: true,
      q: :queue.new(),
      pending_pops: :queue.new(),
      pending_pushes: :queue.new()
    }

    {:ok, state}
  end

  defp default_low_water(capacity) when capacity >= 4, do: div(capacity * 6, 10)
  defp default_low_water(_), do: 0

  # Push: hand directly to a waiting pop if any (bypasses the gate
  # entirely — that's a degenerate case where the worker is faster
  # than the producer). Otherwise, if the gate is open and the queue
  # has room, enqueue. Else park.
  @impl true
  def handle_call({:push, task}, from, state) do
    case :queue.out(state.pending_pops) do
      {{:value, pop_from}, rest} ->
        GenServer.reply(pop_from, task)
        {:reply, :ok, %{state | pending_pops: rest}}

      {:empty, _} ->
        cond do
          state.open? and :queue.len(state.q) < state.capacity ->
            new_q = :queue.in(task, state.q)
            new_open? = :queue.len(new_q) < state.capacity
            {:reply, :ok, %{state | q: new_q, open?: new_open?}}

          true ->
            {:noreply, %{state | pending_pushes: :queue.in({from, task}, state.pending_pushes)}}
        end
    end
  end

  # Requeue: front of queue, bypasses capacity AND the gate (it's a
  # swap, not an add), hand directly to waiting pop if any.
  def handle_call({:requeue, task}, _from, state) do
    case :queue.out(state.pending_pops) do
      {{:value, pop_from}, rest} ->
        GenServer.reply(pop_from, task)
        {:reply, :ok, %{state | pending_pops: rest}}

      {:empty, _} ->
        {:reply, :ok, %{state | q: :queue.in_r(task, state.q)}}
    end
  end

  # Pop: hand oldest item if any; else park. After dequeuing, if the
  # gate is closed and we've drained to `low_water`, reopen and flood
  # parked pushes into the queue (up to capacity).
  def handle_call(:pop, from, state) do
    case :queue.out(state.q) do
      {{:value, task}, rest} ->
        state = maybe_reopen_and_drain(%{state | q: rest})
        {:reply, task, state}

      {:empty, _} ->
        # Pushes only park when the gate is closed (size at capacity)
        # — at which point the queue can't be empty. So an empty
        # queue can't have parked pushes. Just park this pop.
        {:noreply, %{state | pending_pops: :queue.in(from, state.pending_pops)}}
    end
  end

  def handle_call(:size, _from, state) do
    {:reply, :queue.len(state.q), state}
  end

  # Drop everything queued + reply :ok to anyone parked in a push so
  # they can move on. Reopens the gate. Parked pops are left intact —
  # they're harmless and the next legitimate push will service them.
  def handle_call(:clear, _from, state) do
    queued = :queue.len(state.q)
    parked = :queue.len(state.pending_pushes)

    state.pending_pushes
    |> :queue.to_list()
    |> Enum.each(fn {pusher_from, _task} -> GenServer.reply(pusher_from, :ok) end)

    {:reply, queued + parked,
     %{state | q: :queue.new(), pending_pushes: :queue.new(), open?: true}}
  end

  # When a pop drops queue size to (or below) low_water, reopen the
  # gate and drain parked pushes back in until queue is at capacity
  # or no parked pushes remain.
  defp maybe_reopen_and_drain(%{open?: false} = state) do
    if :queue.len(state.q) <= state.low_water do
      drain_pending_pushes(%{state | open?: true})
    else
      state
    end
  end

  defp maybe_reopen_and_drain(state), do: state

  defp drain_pending_pushes(state) do
    cond do
      :queue.len(state.q) >= state.capacity ->
        %{state | open?: false}

      :queue.is_empty(state.pending_pushes) ->
        state

      true ->
        {{:value, {pusher_from, task}}, rest} = :queue.out(state.pending_pushes)
        GenServer.reply(pusher_from, :ok)

        new_q = :queue.in(task, state.q)
        drain_pending_pushes(%{state | q: new_q, pending_pushes: rest})
    end
  end
end
