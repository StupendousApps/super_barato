defmodule SuperBarato.Crawler.Flaresolverr do
  @moduledoc """
  Thin client for [FlareSolverr](https://github.com/FlareSolverr/FlareSolverr),
  a small HTTP service that wraps a headless Chromium and solves
  Cloudflare's "Bot Fight" / managed challenges on demand.

  We don't proxy every request through it (Chromium is slow and RAM-
  hungry). Instead the worker calls `solve/1` once when a CF-protected
  chain gets blocked, harvests the resulting `cf_clearance` + `__cf_bm`
  cookies, and replays them on subsequent curl-impersonate requests
  until they expire or CF re-challenges.

  The endpoint URL comes from `Application.get_env(:super_barato,
  :flaresolverr)[:url]` (set in `config/runtime.exs` from
  `FLARESOLVERR_URL`). When unset, `solve/1` returns `{:error, :disabled}`
  so the worker can fall back to plain profile rotation in dev/test.
  """

  require Logger

  @default_timeout_ms 60_000

  @type cookie :: %{name: String.t(), value: String.t(), domain: String.t()}

  @type solution :: %{
          cookies: [cookie()],
          user_agent: String.t(),
          status: integer(),
          body: String.t()
        }

  @doc """
  Asks FlareSolverr to solve `url`. On success returns the cookies and
  User-Agent its Chromium presented during the solve, plus the final
  page status + body (we usually only care about the cookies).

  Options:

    * `:timeout_ms` — how long to wait for FlareSolverr (default 60s).
      Solves typically finish in 5–15s; the timeout guards against
      Chromium hangs.
  """
  @spec solve(String.t(), keyword()) :: {:ok, solution()} | {:error, term()}
  def solve(url, opts \\ []) when is_binary(url) do
    case endpoint() do
      nil ->
        {:error, :disabled}

      base_url ->
        timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
        do_solve(base_url, url, timeout)
    end
  end

  defp do_solve(base_url, url, timeout) do
    body = %{
      cmd: "request.get",
      url: url,
      maxTimeout: timeout
    }

    # Req's :receive_timeout has to outlive FlareSolverr's own maxTimeout
    # by a margin or we kill the connection while it's still solving.
    req_opts = [
      url: base_url <> "/v1",
      json: body,
      receive_timeout: timeout + 10_000,
      retry: false
    ]

    case Req.post(req_opts) do
      {:ok, %Req.Response{status: 200, body: %{"status" => "ok", "solution" => sol}}} ->
        {:ok, parse_solution(sol)}

      {:ok, %Req.Response{status: 200, body: %{"status" => "error", "message" => msg}}} ->
        {:error, {:flaresolverr_error, msg}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp parse_solution(%{} = sol) do
    %{
      cookies:
        for c <- Map.get(sol, "cookies", []) do
          %{
            name: Map.get(c, "name"),
            value: Map.get(c, "value"),
            domain: Map.get(c, "domain", "")
          }
        end,
      user_agent: Map.get(sol, "userAgent", ""),
      status: Map.get(sol, "status", 0),
      body: Map.get(sol, "response", "")
    }
  end

  @doc """
  Maps a Chromium User-Agent string to the closest curl-impersonate
  profile we ship. CF binds the clearance cookie to the JA3/JA4 of the
  TLS connection that solved the challenge, so the curl profile we
  replay with should mimic the same Chrome major. We don't ship
  profiles >116, so anything newer is pinned to chrome116.
  """
  @spec profile_for_user_agent(String.t()) :: atom()
  def profile_for_user_agent(ua) when is_binary(ua) do
    case Regex.run(~r{Chrome/(\d+)\.}, ua) do
      [_, major] ->
        case String.to_integer(major) do
          n when n >= 116 -> :chrome116
          n when n >= 110 -> :chrome110
          n when n >= 107 -> :chrome107
          n when n >= 104 -> :chrome104
          n when n >= 101 -> :chrome101
          n when n >= 100 -> :chrome100
          _ -> :chrome99
        end

      _ ->
        :chrome116
    end
  end

  def profile_for_user_agent(_), do: :chrome116

  @doc "Whether FlareSolverr is configured. Used by the worker to gate the CF branch."
  @spec enabled?() :: boolean()
  def enabled?, do: endpoint() != nil

  defp endpoint do
    case Application.get_env(:super_barato, :flaresolverr, []) do
      cfg when is_list(cfg) -> Keyword.get(cfg, :url)
      _ -> nil
    end
  end
end
