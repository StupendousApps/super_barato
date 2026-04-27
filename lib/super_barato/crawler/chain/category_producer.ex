defmodule SuperBarato.Crawler.Chain.CategoryProducer do
  @moduledoc """
  Stage-1 producer: pushes a single `:discover_categories` task into
  the chain's Queue. Worker resolves it via the chain adapter's
  `handle_task/1`.

  Today the work is one URL per chain (the categories endpoint or
  category sitemap), so the producer is a thin wrapper. Lives in this
  module for symmetry with the other two producers — every cron entry
  goes through a `…Producer.run/1` MFA, regardless of stage.
  """

  require Logger

  alias SuperBarato.Crawler.Chain.Queue

  @doc "Runs to completion. Spawn via Task.Supervisor."
  def run(opts) do
    chain = Keyword.fetch!(opts, :chain)
    Logger.metadata(chain: chain, role: :producer)
    Logger.info("category producer starting")
    Queue.push(chain, {:discover_categories, %{chain: chain, parent: nil}})
    Logger.info("category producer done")
  end
end
