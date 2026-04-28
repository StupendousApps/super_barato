defmodule SuperBarato.Crawler.Chain.Worker do
  @moduledoc """
  The one process that actually makes HTTP requests for a chain.

  Pops tasks from the chain's Queue, enforces the politeness gap by
  sleeping between iterations, dispatches to the chain's adapter
  (`handle_task/1`), and routes results:

    * `{:ok, payload}` — casts to Results for persistence
    * `:blocked` — rotates the chain's curl-impersonate profile and
      requeues the task at the front of the queue
    * `{:error, reason}` — logs and moves on (fire and forget)

  No timers. The loop is a tight `handle_info(:work, state)` → pop →
  sleep → dispatch → `send(self(), :work)` cycle. The blocking `pop`
  means we park when there's no work; the sleep enforces pacing.
  """

  use GenServer

  require Logger

  alias SuperBarato.Crawler
  alias SuperBarato.Crawler.Chain.{Queue, Results}
  alias SuperBarato.Crawler.{Flaresolverr, Session}

  @default_interval_ms 1_000

  def start_link(opts) do
    chain = Keyword.fetch!(opts, :chain)
    GenServer.start_link(__MODULE__, opts, name: via(chain))
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

  @impl true
  def init(opts) do
    chain = Keyword.fetch!(opts, :chain)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    Logger.metadata(chain: chain, role: :worker)

    state = %{
      chain: chain,
      adapter: Keyword.get(opts, :adapter) || Crawler.adapter(chain),
      interval_ms: interval_ms,
      # Seed to `now() - interval_ms` so the very first iteration doesn't sleep.
      # Erlang monotonic time can be negative, so 0 is not a safe sentinel.
      last_call_at: now() - interval_ms,
      consecutive_blocks: 0,
      fallback_profiles: Keyword.get(opts, :fallback_profiles, [:chrome116]),
      # Used only in tests to shorten the all-profiles-blocked backoff.
      block_backoff_ms: Keyword.get(opts, :block_backoff_ms, 60_000),
      # FlareSolverr-backed Cloudflare bypass — see handle_blocked/3.
      cf_protected: Keyword.get(opts, :cf_protected, false),
      cf_homepage: Keyword.get(opts, :cf_homepage)
    }

    send(self(), :work)
    {:ok, state}
  end

  @impl true
  def handle_info(:work, state) do
    task = Queue.pop(state.chain)
    state = apply_gap(state)
    state = dispatch(task, state)
    send(self(), :work)
    {:noreply, state}
  end

  # Dispatch to adapter, route the result.
  #
  # We log the task at :debug on entry and at :info / :warning when it
  # finishes. A discovery task can keep the worker busy for minutes
  # (synchronous BFS over a chain's category tree); without these
  # bookends a hung worker is invisible — successful tasks would
  # otherwise emit nothing.
  defp dispatch(task, state) do
    started_at = now()
    Logger.debug("[#{state.chain}] task start #{format_task_for_log(task)}")

    case safe_handle_task(state.adapter, task) do
      {:ok, payload} ->
        Results.record(state.chain, task, payload)
        log_task_done(state, task, payload, now() - started_at)
        %{state | last_call_at: now(), consecutive_blocks: 0}

      :blocked ->
        Queue.requeue(state.chain, task)
        state = handle_blocked(state)
        %{state | last_call_at: now()}

      {:error, reason} ->
        log_task_error(state, task, reason, now() - started_at)
        %{state | last_call_at: now(), consecutive_blocks: 0}
    end
  end

  # One-line summary so `bin/kamal logs` shows progress for long-running
  # tasks. Payload size is the most useful signal — empty results are a
  # clear "something is wrong" hint without paging through the body.
  defp log_task_done(state, task, payload, elapsed_ms) do
    size =
      case payload do
        l when is_list(l) -> length(l)
        nil -> 0
        _ -> 1
      end

    Logger.info(
      "[#{state.chain}] task ok n=#{size} t=#{elapsed_ms}ms #{format_task_for_log(task)}"
    )
  end

  # `:stale_pdp` (Product JSON-LD has nil name) and HTTP 410 (Cencosud
  # explicitly says the URL is gone) are normal sitemap drift — a few
  # percent of every full pass. They're noise at :warning level. Real
  # surprises (transport errors, unexpected statuses, parser bugs)
  # stay at :warning so they're still findable in `bin/kamal logs`.
  defp log_task_error(state, task, reason, elapsed_ms) do
    suffix = format_task_for_log(task)
    line = "[#{state.chain}] task failed: #{inspect(reason)} t=#{elapsed_ms}ms #{suffix}"

    if expected_drift?(reason) do
      Logger.debug(line)
    else
      Logger.warning(line)
    end
  end

  defp expected_drift?(:stale_pdp), do: true
  defp expected_drift?({:http_status, 410, _}), do: true
  defp expected_drift?({:http_status, 404, _}), do: true
  defp expected_drift?(_), do: false

  # Compact "url=…" / "slug=…" suffix so a log grep gives us the failing
  # input without having to hunt the request_id across other lines.
  defp format_task_for_log({:fetch_product_pdp, %{url: url}}), do: "url=#{url}"
  defp format_task_for_log({:discover_products, %{slug: slug}}), do: "slug=#{slug}"
  defp format_task_for_log({:fetch_product_info, %{identifiers: ids}}),
    do: "identifiers=#{length(ids)}"
  defp format_task_for_log({:discover_categories, %{parent: nil}}), do: ""
  defp format_task_for_log({:discover_categories, %{parent: p}}), do: "parent=#{p}"
  defp format_task_for_log(_), do: ""

  # On `:blocked`, the requeued task is about to be retried. Decide what
  # to change between the failed attempt and the next one:
  #
  #   * For Cloudflare-protected chains, try FlareSolverr first. A
  #     successful solve mints fresh `cf_clearance` + `__cf_bm` cookies
  #     and pins the matching curl-impersonate profile — the next
  #     attempt should sail through, and we don't burn a profile slot.
  #     Re-solves are only attempted when the cached session is
  #     missing/expired or when CF re-challenged us anyway.
  #
  #   * Otherwise, rotate to the next curl-impersonate profile. After
  #     the whole list has cycled without success, back off so we don't
  #     hammer a target that's actively rejecting us.
  defp handle_blocked(state) do
    cond do
      state.cf_protected and Flaresolverr.enabled?() and state.cf_homepage != nil ->
        case solve_cf_session(state) do
          :ok -> %{state | consecutive_blocks: 0}
          :error -> rotate_and_maybe_backoff(state)
        end

      true ->
        rotate_and_maybe_backoff(state)
    end
  end

  defp solve_cf_session(state) do
    # If we already have a non-expired CF session, the cookies are
    # presumably still good; fall back to profile rotation rather than
    # burning a Chromium solve. CF only re-challenges when it has a
    # reason to, so a re-solve is the right move next time around once
    # `clear_cf_session/1` runs (we drop the session when the rotated
    # request fails too — see below).
    if Session.cf_session_valid?(state.chain) do
      Logger.warning("[#{state.chain}] CF cookies still valid but blocked — clearing for re-solve")
      Session.clear_cf_session(state.chain)
    end

    case Flaresolverr.solve(state.cf_homepage) do
      {:ok, %{cookies: cookies, user_agent: ua, status: status}} ->
        profile = Flaresolverr.profile_for_user_agent(ua)
        Session.put_cf_session(state.chain, cookies, profile, ua)

        Logger.info(
          "[#{state.chain}] CF challenge solved — status=#{status}, profile=#{profile}, cookies=#{length(cookies)}"
        )

        :ok

      {:error, reason} ->
        Logger.warning("[#{state.chain}] CF solve failed: #{inspect(reason)}")
        :error
    end
  end

  defp rotate_and_maybe_backoff(state) do
    new_profile = Session.rotate_profile(state.chain, state.fallback_profiles)
    blocks = state.consecutive_blocks + 1

    Logger.warning(
      "[#{state.chain}] task blocked — rotated profile to #{new_profile} (block ##{blocks})"
    )

    if blocks >= length(state.fallback_profiles) do
      Logger.warning(
        "[#{state.chain}] all profiles blocked — sleeping #{state.block_backoff_ms}ms"
      )

      Process.sleep(state.block_backoff_ms)
      %{state | consecutive_blocks: 0}
    else
      %{state | consecutive_blocks: blocks}
    end
  end

  defp safe_handle_task(mod, task) do
    mod.handle_task(task)
  rescue
    err ->
      {:error, {:exception, err}}
  end

  # Sleep so that we don't exceed the configured interval between calls.
  defp apply_gap(state) do
    elapsed = now() - state.last_call_at
    wait = state.interval_ms - elapsed
    if wait > 0, do: Process.sleep(wait)
    state
  end

  defp now, do: System.monotonic_time(:millisecond)
end
