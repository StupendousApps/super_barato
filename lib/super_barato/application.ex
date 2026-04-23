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
        rate_limiter_specs() ++
        [SuperBaratoWeb.Endpoint]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
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

  defp rate_limiter_specs do
    :super_barato
    |> Application.get_env(SuperBarato.Crawler, [])
    |> Keyword.get(:rate_limits, [])
    |> Enum.map(fn {chain, opts} ->
      Supervisor.child_spec(
        {SuperBarato.Crawler.RateLimiter, Keyword.put(opts, :chain, chain)},
        id: {SuperBarato.Crawler.RateLimiter, chain}
      )
    end)
  end
end
