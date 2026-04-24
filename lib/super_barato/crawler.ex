defmodule SuperBarato.Crawler do
  @moduledoc """
  Entry point for the crawler. Keeps the registry of chain adapters and
  exposes `adapter/1` for the pipeline (and Mix tasks) to look up a
  chain's implementation module.

  The running pipeline (Queue, Worker, Results, Cron) lives under
  `SuperBarato.Crawler.Chain.Supervisor`, one per chain, started from
  `SuperBarato.Application` when `chains_enabled` is true in config.
  """

  @adapters %{
    unimarc: SuperBarato.Crawler.Unimarc,
    jumbo: SuperBarato.Crawler.Jumbo,
    santa_isabel: SuperBarato.Crawler.SantaIsabel,
    lider: SuperBarato.Crawler.Lider,
    tottus: SuperBarato.Crawler.Tottus
  }

  def adapter(chain) when is_atom(chain), do: Map.fetch!(@adapters, chain)

  def known_chains, do: Map.keys(@adapters)
end
