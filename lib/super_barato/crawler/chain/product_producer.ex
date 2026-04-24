defmodule SuperBarato.Crawler.Chain.ProductProducer do
  @moduledoc """
  Transient task spawned by Cron. Streams work out of the database and
  pushes it into the chain's Queue. Because `Queue.push/2` blocks when
  the queue is full, memory is bounded — this process stalls when the
  Worker can't keep up.

  Two modes:

    * `:products` — one task per leaf category (`:discover_products`).
    * `:prices`   — one task per batch of 25 refresh identifiers
      (`:fetch_product_info`).
  """

  require Logger

  alias SuperBarato.{Catalog, Crawler, Repo}
  alias SuperBarato.Crawler.Chain.Queue

  @batch_size 25

  @doc "Runs to completion. Spawn via Task.Supervisor."
  def run(opts) do
    chain = Keyword.fetch!(opts, :chain)
    mode = Keyword.fetch!(opts, :mode)

    Logger.info("[#{chain}] producer starting: mode=#{mode}")
    count = do_run(chain, mode)
    Logger.info("[#{chain}] producer done: mode=#{mode}, pushed=#{count}")
  end

  defp do_run(chain, :products) do
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

  defp do_run(chain, :prices) do
    field = Crawler.adapter(chain).refresh_identifier()

    Repo.transaction(
      fn ->
        chain
        |> Catalog.active_identifiers_query(field)
        |> Repo.stream(max_rows: 500)
        |> Stream.chunk_every(@batch_size)
        |> Stream.map(fn batch ->
          Queue.push(
            chain,
            {:fetch_product_info, %{chain: chain, identifiers: batch}}
          )

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
