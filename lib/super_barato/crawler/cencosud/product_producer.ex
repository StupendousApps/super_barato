defmodule SuperBarato.Crawler.Cencosud.ProductProducer do
  @moduledoc """
  Transient task spawned by the chain's Cron, replacing the leaf-
  category iteration the generic `Chain.ProductProducer` does for
  Lider/Unimarc.

  For Cencosud chains (Jumbo, Santa Isabel) we don't enumerate via
  the `?sc=N` API anymore — that path is `Disallow`-ed in robots.txt
  and gets gated upstream. Instead we read the chain's sitemap index
  (CloudFront/S3, no bot protection) which lists every canonical PDP
  URL the chain wants indexed, and push one `:fetch_product_pdp`
  task per URL into the chain's Queue.

  `Queue.push/2` blocks when the queue is full, so memory stays bounded
  — this process stalls naturally when the Worker can't keep up. A
  full Jumbo pass at the default 1 req/s pacing takes ~14 hours; that's
  fine for a daily run. Bump `interval_ms` in config if you want it
  faster (or slower).
  """

  require Logger

  alias SuperBarato.Crawler
  alias SuperBarato.Crawler.Cencosud
  alias SuperBarato.Crawler.Chain.Queue

  @doc "Runs to completion. Spawn via Task.Supervisor."
  def run(opts) do
    chain = Keyword.fetch!(opts, :chain)
    Logger.metadata(chain: chain, role: :producer)
    Logger.info("sitemap producer starting")

    case Crawler.adapter(chain).cencosud_config() do
      %Cencosud.Config{} = cfg ->
        case Cencosud.list_sitemap_urls(cfg) do
          {:ok, urls} ->
            count =
              Enum.reduce(urls, 0, fn url, n ->
                Queue.push(chain, {:fetch_product_pdp, %{chain: chain, url: url}})
                n + 1
              end)

            Logger.info("sitemap producer done: pushed=#{count}")

          {:error, reason} ->
            Logger.error("sitemap producer failed to list urls: #{inspect(reason)}")
        end

      _ ->
        Logger.error(
          "sitemap producer: adapter for #{inspect(chain)} doesn't expose cencosud_config/0"
        )
    end
  end
end
