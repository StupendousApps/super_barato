defmodule SuperBarato.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        SuperBaratoWeb.Telemetry,
        SuperBarato.Repo,
        {DNSCluster, query: Application.get_env(:super_barato, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: SuperBarato.PubSub},
        {Registry, keys: :unique, name: SuperBarato.Crawler.Registry}
      ] ++
        chain_pipeline_specs() ++
        [SuperBaratoWeb.Endpoint]

    opts = [strategy: :one_for_one, name: SuperBarato.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SuperBaratoWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Per-chain pipeline supervisors (Queue, Worker, Results, Cron, TaskSup).
  # Gated by `chains_enabled` so tests and IEx can skip the network workers.
  defp chain_pipeline_specs do
    crawler_cfg = Application.get_env(:super_barato, SuperBarato.Crawler, [])

    if Keyword.get(crawler_cfg, :chains_enabled, false) do
      crawler_cfg
      |> Keyword.get(:chains, [])
      |> Enum.map(fn {chain, chain_opts} ->
        # Pacing + fallback profiles still come from config; the
        # schedule is loaded from the DB inside Chain.Supervisor.init/1
        # (deferred so Repo is started by the time we hit it).
        opts =
          chain_opts
          |> Keyword.delete(:schedule)
          |> Keyword.put(:chain, chain)

        Supervisor.child_spec(
          {SuperBarato.Crawler.Chain.Supervisor, opts},
          id: {SuperBarato.Crawler.Chain.Supervisor, chain}
        )
      end)
    else
      []
    end
  end
end
