defmodule SuperBarato.Crawler.Session do
  @moduledoc """
  Per-chain cookie jar. Before the first real request to a chain, the
  adapter calls `warm_up/2` which GETs the homepage (or another landing
  URL) and stashes any `Set-Cookie` values. Subsequent requests send them
  back via `cookie_header/1`, mimicking a real browser session.

  This is not enough to defeat advanced bot protection (Akamai's `_abck`
  is set by their JS), but it does handle basic session cookies that some
  endpoints rely on.
  """

  @table :crawler_cookies

  def init do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Ensures we've hit `url` at least once to pick up session cookies.
  `fetch_fn` is a 2-arity function `(url, headers) -> {:ok, response} | {:error, _}`
  where `response` is any struct the caller's HTTP adapter returns. Cookies are
  absorbed via `absorb_response/2`.
  No-ops on subsequent calls for the same chain.
  """
  def warm_up(chain, url, headers, fetch_fn)
      when is_atom(chain) and is_binary(url) and is_function(fetch_fn, 2) do
    init()

    case :ets.lookup(@table, {chain, :warmed?}) do
      [{_, true}] ->
        :ok

      _ ->
        case fetch_fn.(url, headers) do
          {:ok, resp} -> absorb_response(chain, resp)
          {:error, _} -> :ok
        end

        :ets.insert(@table, {{chain, :warmed?}, true})
        :ok
    end
  end

  @doc "Stores a value under `{chain, key}`. Overwrites any existing value."
  def put(chain, key, value) when is_atom(chain) do
    init()
    :ets.insert(@table, {{chain, key}, value})
    :ok
  end

  @doc """
  Rotates the chain's `:profile` to the next entry in `candidates`,
  cycling back to the first when the current one is at the end (or
  unknown). Returns the new profile.
  """
  def rotate_profile(chain, candidates)
      when is_atom(chain) and is_list(candidates) and candidates != [] do
    current = get(chain, :profile)
    next = next_after(candidates, current)
    put(chain, :profile, next)
    next
  end

  defp next_after(candidates, nil), do: List.first(candidates)

  defp next_after(candidates, current) do
    case Enum.split_while(candidates, &(&1 != current)) do
      {_before, [_current, next | _]} -> next
      _ -> List.first(candidates)
    end
  end

  @doc "Reads the value under `{chain, key}`, or `nil` if not set."
  def get(chain, key) when is_atom(chain) do
    init()

    case :ets.lookup(@table, {chain, key}) do
      [{_, v}] -> v
      _ -> nil
    end
  end

  @doc "Returns the merged `Cookie` header for the chain, or `nil` if empty."
  def cookie_header(chain) when is_atom(chain) do
    init()

    case :ets.lookup(@table, {chain, :cookies}) do
      [{_, map}] when map_size(map) > 0 ->
        map
        |> Enum.map_join("; ", fn {k, v} -> "#{k}=#{v}" end)

      _ ->
        nil
    end
  end

  @doc """
  Merges `Set-Cookie` values from a response into the jar. Accepts any struct
  exposing a `headers` field as a list of `{String.t(), String.t()}` tuples
  (lowercased keys).
  """
  def absorb_response(chain, resp) do
    init()
    new = parse_set_cookies(extract_set_cookies(resp))

    if new != %{} do
      existing =
        case :ets.lookup(@table, {chain, :cookies}) do
          [{_, map}] -> map
          _ -> %{}
        end

      :ets.insert(@table, {{chain, :cookies}, Map.merge(existing, new)})
    end

    resp
  end

  defp extract_set_cookies(%{headers: headers}) when is_list(headers) do
    for {k, v} <- headers, String.downcase(k) == "set-cookie", do: v
  end

  defp extract_set_cookies(_), do: []

  defp parse_set_cookies([]), do: %{}

  defp parse_set_cookies(headers) when is_list(headers) do
    Enum.reduce(headers, %{}, fn header, acc ->
      case String.split(header, ";", parts: 2) do
        [kv | _] ->
          case String.split(kv, "=", parts: 2) do
            [k, v] -> Map.put(acc, String.trim(k), String.trim(v))
            _ -> acc
          end

        _ ->
          acc
      end
    end)
  end
end
