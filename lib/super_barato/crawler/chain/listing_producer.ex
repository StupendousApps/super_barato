defmodule SuperBarato.Crawler.Chain.ListingProducer do
  @moduledoc """
  Stage-3 producer: refreshes prices on already-known chain_listings
  for the chain. Streams `chain_listings.pdp_url` from the DB and
  pushes one `:fetch_product_pdp` task per row into the chain's
  Queue.

  Shared across chains — anything that persists a `pdp_url` on its
  listings can use this without modification, since the worker's
  `:fetch_product_pdp` clause already dispatches to the right adapter.

  Backpressure via `QueueServer.push/2`'s blocking call: the producer
  stalls when the queue is full, so memory stays bounded regardless
  of the listing count. A full Jumbo refresh at 1 req/s is ~14 hours,
  matching the original sitemap walk but without the discovery cost.
  """

  import Ecto.Query
  require Logger

  alias SuperBarato.Catalog.ChainListing
  alias SuperBarato.Crawler.Chain.QueueServer
  alias SuperBarato.Repo

  @doc "Runs to completion. Spawn via Task.Supervisor."
  def run(opts) do
    chain = Keyword.fetch!(opts, :chain)
    Logger.metadata(chain: chain, role: :producer)
    Logger.info("listing producer starting")

    {:ok, count} =
      Repo.transaction(
        fn ->
          chain
          |> active_pdp_urls_query()
          |> Repo.stream(max_rows: 200)
          |> Stream.map(fn url ->
            QueueServer.push(chain, {:fetch_product_pdp, %{chain: chain, url: url}})
            1
          end)
          |> Enum.sum()
        end,
        timeout: :infinity
      )

    Logger.info("listing producer done: pushed=#{count}")
  end

  defp active_pdp_urls_query(chain) do
    from(l in ChainListing,
      where:
        l.chain == ^to_string(chain) and l.active == true and not is_nil(l.pdp_url),
      select: l.pdp_url
    )
  end
end
