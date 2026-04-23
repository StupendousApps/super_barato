defmodule SuperBarato.Crawler.RateLimiter do
  @moduledoc """
  Per-chain token serializer. Enforces a minimum gap between outbound
  requests so discovery and price jobs share the same politeness bucket.

  Callers get a token via `request/3` with either `:high` or `:normal`
  priority; high-priority jobs are dispatched first when both are queued.
  Caller priority only affects ordering inside this process — requests
  from different callers are fully serialized.

  One in-flight request at a time. If a caller crashes before releasing
  its token, the monitor clears the busy flag.
  """

  use GenServer

  require Logger

  @default_interval_ms 1_000

  # Public API

  @doc """
  Runs `fun` once the chain's rate limiter grants a token. Blocks the
  caller until dispatched; returns whatever `fun` returns. Use `:high`
  for discovery, `:normal` for price fetches.
  """
  def request(chain, priority \\ :normal, fun)
      when is_atom(chain) and priority in [:high, :normal] and is_function(fun, 0) do
    :ok = GenServer.call(via(chain), {:acquire, priority}, :infinity)

    try do
      fun.()
    after
      GenServer.cast(via(chain), {:release, self()})
    end
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

  def start_link(opts) do
    chain = Keyword.fetch!(opts, :chain)
    GenServer.start_link(__MODULE__, opts, name: via(chain))
  end

  defp via(chain),
    do: {:via, Registry, {SuperBarato.Crawler.Registry, {__MODULE__, chain}}}

  # Server

  @impl true
  def init(opts) do
    state = %{
      chain: Keyword.fetch!(opts, :chain),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      queue_high: :queue.new(),
      queue_normal: :queue.new(),
      last_sent_at:
        System.monotonic_time(:millisecond) -
          Keyword.get(opts, :interval_ms, @default_interval_ms),
      busy: false,
      holder: nil,
      tick_scheduled: false
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, priority}, {caller_pid, _tag} = from, state) do
    ref = Process.monitor(caller_pid)

    state =
      case priority do
        :high -> %{state | queue_high: :queue.in({from, ref}, state.queue_high)}
        :normal -> %{state | queue_normal: :queue.in({from, ref}, state.queue_normal)}
      end

    {:noreply, maybe_dispatch(state)}
  end

  @impl true
  def handle_cast({:release, pid}, state) do
    state =
      case state.holder do
        {^pid, ref} ->
          Process.demonitor(ref, [:flush])
          %{state | busy: false, holder: nil}

        _ ->
          state
      end

    {:noreply, maybe_dispatch(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    {:noreply, maybe_dispatch(%{state | tick_scheduled: false})}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    # If the holder died, free the slot.
    state =
      case state.holder do
        {^pid, ^ref} -> %{state | busy: false, holder: nil}
        _ -> state
      end

    # Also drop any queued entries for this pid.
    state = %{
      state
      | queue_high: drop_from_queue(state.queue_high, ref),
        queue_normal: drop_from_queue(state.queue_normal, ref)
    }

    {:noreply, maybe_dispatch(state)}
  end

  defp drop_from_queue(q, ref) do
    q
    |> :queue.to_list()
    |> Enum.reject(fn {_from, r} -> r == ref end)
    |> :queue.from_list()
  end

  defp maybe_dispatch(%{busy: true} = state), do: state

  defp maybe_dispatch(state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.last_sent_at

    cond do
      elapsed < state.interval_ms ->
        schedule_tick(state, state.interval_ms - elapsed)

      true ->
        case dequeue(state) do
          {nil, state} ->
            state

          {{from, ref}, state} ->
            {pid, _tag} = from
            GenServer.reply(from, :ok)
            %{state | busy: true, holder: {pid, ref}, last_sent_at: now}
        end
    end
  end

  defp dequeue(state) do
    case :queue.out(state.queue_high) do
      {{:value, item}, q} ->
        {item, %{state | queue_high: q}}

      {:empty, _} ->
        case :queue.out(state.queue_normal) do
          {{:value, item}, q} -> {item, %{state | queue_normal: q}}
          {:empty, _} -> {nil, state}
        end
    end
  end

  defp schedule_tick(%{tick_scheduled: true} = state, _delay), do: state

  defp schedule_tick(state, delay) do
    Process.send_after(self(), :tick, delay)
    %{state | tick_scheduled: true}
  end
end
