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
    headers = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body)
    follow = Keyword.get(opts, :follow_redirects, true)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    profile = Keyword.get(opts, :profile) || default_profile()
    binary = binary_for_profile(profile)

    headers_file =
      Path.join(System.tmp_dir!(), "sb_curl_#{System.unique_integer([:positive])}.hdr")

    args = build_args(method, url, headers, body, follow, timeout, headers_file)

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

  defp binary_dir do
    case Application.get_env(:super_barato, :curl_impersonate_dir) do
      nil -> Path.expand(@default_dir, File.cwd!())
      path -> path
    end
  end

  defp default_profile do
    Application.get_env(:super_barato, :curl_impersonate_profile, @default_profile)
  end

  defp build_args(method, url, headers, body, follow, timeout_ms, headers_file) do
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

    base
    |> then(&if follow, do: &1 ++ ["-L"], else: &1)
    |> Kernel.++(method_args)
    |> Kernel.++(header_args)
    |> Kernel.++([url])
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
