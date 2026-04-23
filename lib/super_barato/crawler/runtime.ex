defmodule SuperBarato.Crawler.Runtime do
  @moduledoc """
  Helpers to boot just the crawler plumbing (Registry + RateLimiters) for
  CLI tools. Does not start Repo or Endpoint, so tasks can exercise the
  adapters without Postgres.
  """

  alias SuperBarato.Crawler.RateLimiter

  @doc """
  Starts the crawler's out-of-band dependencies for a single chain.
  Safe to call multiple times.
  """
  def ensure_started(chain) when is_atom(chain) do
    {:ok, _} = Application.ensure_all_started(:req)

    case Registry.start_link(keys: :unique, name: SuperBarato.Crawler.Registry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    opts = rate_limit_opts(chain)

    case RateLimiter.start_link(Keyword.put(opts, :chain, chain)) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp rate_limit_opts(chain) do
    :super_barato
    |> Application.get_env(SuperBarato.Crawler, [])
    |> Keyword.get(:rate_limits, [])
    |> Keyword.get(chain, [])
  end
end
