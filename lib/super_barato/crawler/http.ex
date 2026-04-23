defmodule SuperBarato.Crawler.Http do
  @moduledoc """
  Thin HTTP client that shells out to `curl-impersonate` so the TLS
  `ClientHello` matches a real Chrome build. This bypasses JA3/JA4
  fingerprint blocks (e.g. Akamai Bot Manager) that reject Erlang's
  native `:ssl` signature.

  Supports `GET` and `POST` with a body, custom headers, and redirect
  following. Response headers and body are captured separately — headers
  via `-D <tempfile>`, body to stdout.

  Binary path comes from `config :super_barato, :curl_impersonate_binary`
  and defaults to `priv/bin/curl_chrome116`.
  """

  alias SuperBarato.Crawler.Http.Response

  @default_timeout_ms 30_000
  @default_binary "priv/bin/curl_chrome116"

  @doc "GET. See `request/3`."
  def get(url, opts \\ []) when is_binary(url), do: request(:get, url, opts)

  @doc """
  POST with a `:body` option (binary). Other opts mirror `get/2`.
  """
  def post(url, opts) when is_binary(url), do: request(:post, url, opts)

  @doc """
  Performs the request. Returns `{:ok, %Response{}}` on any HTTP response
  (including 4xx/5xx) or `{:error, reason}` if the transport itself fails.

    * `headers`: list of `{name, value}` tuples.
    * `body`: binary body for POST/PUT.
    * `follow_redirects`: defaults to `true`.
    * `timeout_ms`: per-request wall-clock limit, defaults to 30s.
  """
  def request(method, url, opts) when method in [:get, :post] and is_binary(url) do
    headers = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body)
    follow = Keyword.get(opts, :follow_redirects, true)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    headers_file =
      Path.join(System.tmp_dir!(), "sb_curl_#{System.unique_integer([:positive])}.hdr")

    args = build_args(method, url, headers, body, follow, timeout, headers_file)

    try do
      case System.cmd(binary_path(), args, stderr_to_stdout: false) do
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

  def binary_path do
    Application.get_env(:super_barato, :curl_impersonate_binary)
    |> case do
      nil -> Path.expand(@default_binary, File.cwd!())
      path -> path
    end
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
