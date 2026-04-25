defmodule SuperBarato.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    configure_file_logging()

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

  # When `LOG_DIR` is set (only in prod, via deploy.yml's host volume),
  # add a rotating file handler alongside the default stdout one so
  # logs survive container restarts. Dev/test leave this off and use
  # stdout-only.
  defp configure_file_logging do
    case System.get_env("LOG_DIR") do
      nil ->
        :ok

      dir ->
        File.mkdir_p!(dir)
        file = dir |> Path.join("super_barato.log") |> String.to_charlist()

        :ok =
          :logger.add_handler(:file_log, :logger_disk_log_h, %{
            config: %{
              file: file,
              # Wrap at 10 MB × 5 files (~50 MB max retained on disk).
              type: :wrap,
              max_no_files: 5,
              max_no_bytes: 10_485_760
            },
            formatter:
              Logger.Formatter.new(
                format: "$time $metadata[$level] $message\n",
                metadata: [:request_id, :chain, :role]
              )
          })
    end
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
