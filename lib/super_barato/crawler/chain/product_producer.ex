defmodule SuperBarato.Crawler.Chain.ProductProducer do
  @moduledoc """
  Transient task spawned by Cron. Streams leaf categories out of the
  DB and pushes one `:discover_products` task per leaf into the
  chain's Queue. Because `Queue.push/2` blocks when the queue is full,
  memory is bounded — this process stalls when the Worker can't keep
  up.

  A single `products` run covers both "find new SKUs" and "refresh
  prices on known SKUs", since the underlying search endpoint returns
  both. Price history is appended to `SuperBarato.PriceLog` files by
  `Chain.Results` for every listing it persists.
  """

  require Logger

  alias SuperBarato.{Catalog, Repo}
  alias SuperBarato.Crawler.Chain.Queue

  @doc "Runs to completion. Spawn via Task.Supervisor."
  def run(opts) do
    chain = Keyword.fetch!(opts, :chain)
    Logger.info("[#{chain}] product producer starting")
    count = do_run(chain)
    Logger.info("[#{chain}] product producer done: pushed=#{count}")
  end

  defp do_run(chain) do
    Repo.transaction(
      fn ->
        chain
        |> Catalog.leaf_categories_query()
        |> Repo.stream(max_rows: 50)
        |> Stream.map(fn cat ->
          Queue.push(chain, {:discover_products, %{chain: chain, slug: cat.slug}})
          1
        end)
        |> Enum.sum()
      end,
      timeout: :infinity
    )
    |> case do
      {:ok, n} -> n
      {:error, _} -> 0
    end
  end
end
