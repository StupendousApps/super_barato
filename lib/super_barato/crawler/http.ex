defmodule SuperBarato.Crawler.Http do
  @moduledoc """
  Thin HTTP client that shells out to `curl-impersonate` so the TLS
  `ClientHello` matches a real browser build. This bypasses JA3/JA4
  fingerprint blocks (e.g. Akamai Bot Manager) that reject Erlang's
  native `:ssl` signature.

  ## Browser profile switching

  Different targets' bot-protection settings accept different browsers.
  Akamai on Lider, for example, blocks Chrome 110+ and all Firefox but
  still lets Chrome 99–107 through. Callers pass `profile: :chromeNNN`
  (or `:ffNNN`, `:safari15_5`, etc.); the binary resolved is
  `<dir>/curl_<profile>`.

  Defaults:

    * `curl_impersonate_dir` — directory containing the curl-impersonate
      binaries. Defaults to `priv/bin/`.
    * `curl_impersonate_profile` — profile used when a call doesn't
      pass `:profile`. Defaults to `:chrome116`.

  Both are normal `Application.get_env/3` lookups, so environments can
  override them without redeploying code.
  """

  alias SuperBarato.Crawler.Http.Response

  @default_timeout_ms 30_000
  @default_profile :chrome116
  @default_dir "priv/bin"

  # The set of profiles curl-impersonate v0.6.1 ships. Callers pass
  # these atoms; they're just documentation + guard — the real check is
  # whether `<dir>/curl_<profile>` exists at call time.
  @known_profiles ~w(
    chrome99 chrome99_android chrome100 chrome101 chrome104 chrome107
    chrome110 chrome116
    edge99 edge101
    ff91esr ff95 ff98 ff100 ff102 ff109 ff117
    safari15_3 safari15_5
  )a

  def known_profiles, do: @known_profiles

  # User-Agent strings the curl-impersonate v0.6.1 wrappers inject by
  # default — extracted directly from `priv/bin/curl_<profile>`. The
  # wrapper *should* set this header itself (and locally it does), but
  # we observed prod requests landing at Instaleap with no UA and
  # being rejected with INVALID_HEADERS. Belt-and-braces: when the
  # caller hasn't pinned a UA and the session hasn't stashed one
  # either, we set the canonical UA matching the chosen TLS profile
  # before invoking the binary, so what the server sees can't drift
  # from the fingerprint regardless of how the wrapper happens to
  # behave on the host.
  @profile_user_agents %{
    chrome99:
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/99.0.4844.51 Safari/537.36",
    chrome99_android:
      "Mozilla/5.0 (Linux; Android 12; Pixel 6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/99.0.4844.58 Mobile Safari/537.36",
    chrome100:
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.75 Safari/537.36",
    chrome101:
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/101.0.4951.67 Safari/537.36",
    chrome104:
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/104.0.0.0 Safari/537.36",
    chrome107:
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36",
    chrome110:
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36",
    chrome116:
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36",
    edge99:
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/99.0.4844.51 Safari/537.36 Edg/99.0.1150.30",
    edge101:
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/101.0.4951.64 Safari/537.36 Edg/101.0.1210.47",
    ff91esr: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:91.0) Gecko/20100101 Firefox/91.0",
    ff95: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:95.0) Gecko/20100101 Firefox/95.0",
    ff98: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:98.0) Gecko/20100101 Firefox/98.0",
    ff100: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:100.0) Gecko/20100101 Firefox/100.0",
    ff102: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:102.0) Gecko/20100101 Firefox/102.0",
    ff109: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/109.0",
    ff117: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/117.0",
    safari15_3:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.3 Safari/605.1.15",
    safari15_5:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15"
  }

  @doc "Canonical User-Agent that matches `profile`'s TLS fingerprint."
  def user_agent_for_profile(profile) when is_atom(profile),
    do: Map.get(@profile_user_agents, profile)

  def user_agent_for_profile(_), do: nil

  @doc "GET. See `request/3`."
  def get(url, opts \\ []) when is_binary(url), do: request(:get, url, opts)

  @doc """
  POST with a `:body` option (binary). Other opts mirror `get/2`.
  """
  def post(url, opts) when is_binary(url), do: request(:post, url, opts)

  @doc """
  Performs the request. Returns `{:ok, %Response{}}` on any HTTP response
  (including 4xx/5xx) or `{:error, reason}` if the transport itself fails.

  Options:

    * `:headers` — list of `{name, value}` tuples.
    * `:body` — binary body for POST/PUT.
    * `:profile` — curl-impersonate profile atom (e.g. `:chrome107`).
      Defaults to the app-wide `:curl_impersonate_profile`.
    * `:follow_redirects` — defaults to `true`.
    * `:timeout_ms` — per-request wall-clock limit, defaults to 30 s.
  """
  def request(method, url, opts) when method in [:get, :post] and is_binary(url) do
    chain = Keyword.get(opts, :chain)
    {headers, profile} = enrich_from_session(chain, opts)
    headers = ensure_profile_user_agent(headers, profile)
    body = Keyword.get(opts, :body)
    follow = Keyword.get(opts, :follow_redirects, true)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    proxy_url = Keyword.get(opts, :proxy_url) || chain_proxy_url(chain)
    binary = binary_for_profile(profile)

    headers_file =
      Path.join(System.tmp_dir!(), "sb_curl_#{System.unique_integer([:positive])}.hdr")

    args = build_args(method, url, headers, body, follow, timeout, headers_file, proxy_url)

    try do
      case System.cmd(binary, args, stderr_to_stdout: false) do
        {resp_body, 0} ->
          header_data = File.read!(headers_file)
          {status, resp_headers} = parse_headers(header_data)
          {:ok, %Response{status: status, headers: resp_headers, body: resp_body}}

        {stderr, code} ->
          {:error, {:curl_exit, code, String.trim(stderr)}}
      end
    after
      _ = File.rm(headers_file)
    end
  end

  @doc """
  Resolves a profile atom (e.g. `:chrome107`) to an absolute binary path.
  Pass-through if a string is given.
  """
  def binary_for_profile(profile) when is_atom(profile) do
    Path.join(binary_dir(), "curl_" <> Atom.to_string(profile))
  end

  def binary_for_profile(path) when is_binary(path), do: path

  @doc """
  Heuristic: does this response look like a bot-block challenge rather
  than a real answer from the target? Different chains have different
  block signals but these catch Akamai's common ones (the 307 redirect
  to /blocked, 403/429/503 statuses, and HTML challenge bodies).

  Adapters can layer their own checks on top when a chain uses a
  non-standard marker.
  """
  def blocked?(%Response{status: status}) when status in [307, 403, 429, 503], do: true

  def blocked?(%Response{status: 200, body: body}) when is_binary(body) do
    String.contains?(body, "Robot or human?") or
      String.contains?(body, "Access Denied") or
      String.starts_with?(body, "blocked - redirecting")
  end

  def blocked?(_), do: false

  # If a `:chain` is given, layer the chain's stashed Cookie header and
  # FlareSolverr-minted User-Agent on top of any caller-supplied headers
  # (caller wins on collision), and use the chain's pinned profile when
  # the caller didn't pass one explicitly. Without `:chain`, behaves
  # exactly like before.
  defp enrich_from_session(nil, opts) do
    headers = Keyword.get(opts, :headers, [])
    profile = Keyword.get(opts, :profile) || default_profile()
    {headers, profile}
  end

  defp enrich_from_session(chain, opts) when is_atom(chain) do
    caller_headers = Keyword.get(opts, :headers, [])
    cookie = SuperBarato.Crawler.Session.cookie_header(chain)
    cf_ua = SuperBarato.Crawler.Session.get(chain, :cf_user_agent)

    headers =
      caller_headers
      |> override_header("user-agent", if(is_binary(cf_ua) and cf_ua != "", do: cf_ua))
      |> override_header("cookie", cookie)

    profile =
      Keyword.get(opts, :profile) ||
        SuperBarato.Crawler.Session.get(chain, :profile) ||
        default_profile()

    {headers, profile}
  end

  # If neither caller nor session pinned a User-Agent, fall back to
  # the canonical UA for the profile we're about to invoke. Caller-
  # or session-provided UAs always win — they're explicit overrides.
  defp ensure_profile_user_agent(headers, profile) do
    has_ua? = Enum.any?(headers, fn {k, _} -> String.downcase(k) == "user-agent" end)
    if has_ua?, do: headers, else: override_header(headers, "user-agent", user_agent_for_profile(profile))
  end

  # Replace any existing `name` header (case-insensitive) with `value`,
  # or append it if absent. Skips when `value` is nil/empty.
  defp override_header(headers, _name, nil), do: headers
  defp override_header(headers, _name, ""), do: headers

  defp override_header(headers, name, value) do
    lower = String.downcase(name)
    stripped = Enum.reject(headers, fn {k, _} -> String.downcase(k) == lower end)
    [{name, value} | stripped]
  end

  defp binary_dir do
    case Application.get_env(:super_barato, :curl_impersonate_dir) do
      nil -> Path.expand(@default_dir, File.cwd!())
      path -> path
    end
  end

  defp default_profile do
    Application.get_env(:super_barato, :curl_impersonate_profile, @default_profile)
  end

  defp build_args(method, url, headers, body, follow, timeout_ms, headers_file, proxy_url) do
    header_args = Enum.flat_map(headers, fn {k, v} -> ["-H", "#{k}: #{v}"] end)

    method_args =
      case method do
        :get ->
          []

        :post ->
          ["-X", "POST"] ++ if(body, do: ["--data-binary", body], else: [])
      end

    base = [
      "-sS",
      "--compressed",
      "--max-time",
      Integer.to_string(div(timeout_ms, 1000)),
      "-D",
      headers_file
    ]

    proxy_args =
      case proxy_url do
        nil -> []
        "" -> []
        url -> ["--proxy", url]
      end

    base
    |> then(&if follow, do: &1 ++ ["-L"], else: &1)
    |> Kernel.++(proxy_args)
    |> Kernel.++(method_args)
    |> Kernel.++(header_args)
    |> Kernel.++([url])
  end

  # Per-chain proxy URL, populated from `:chain_proxies` config at
  # boot. The map is `%{chain_atom => "http://user:pass@host:port"}`
  # — empty by default, prod populates Tottus from `TOTTUS_PROXY_URL`
  # so its requests egress through a CL residential IP. Other chains
  # stay direct (no proxy = nil = no `--proxy` flag).
  defp chain_proxy_url(nil), do: nil

  defp chain_proxy_url(chain) when is_atom(chain) do
    case Application.get_env(:super_barato, :chain_proxies, %{}) do
      %{} = m -> Map.get(m, chain)
      _ -> nil
    end
  end

  # `-D` writes every response block when following redirects. Keep only the
  # last block — that's the final response's headers.
  defp parse_headers(data) do
    blocks =
      data
      |> String.split(~r/\r?\n\r?\n/, trim: true)
      |> Enum.reject(&(&1 == ""))

    case List.last(blocks) do
      nil -> {0, []}
      final -> parse_block(final)
    end
  end

  defp parse_block(block) do
    [status_line | header_lines] = String.split(block, ~r/\r?\n/, trim: true)

    status =
      case Regex.run(~r/^HTTP\/[\d.]+\s+(\d+)/, status_line) do
        [_, code] -> String.to_integer(code)
        _ -> 0
      end

    headers =
      header_lines
      |> Enum.flat_map(fn line ->
        case String.split(line, ":", parts: 2) do
          [k, v] -> [{String.downcase(String.trim(k)), String.trim(v)}]
          _ -> []
        end
      end)

    {status, headers}
  end
end
