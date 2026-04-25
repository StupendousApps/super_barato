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

        # Retention is bounded by file count × file size. Tune via
        # LOG_MAX_FILES + LOG_MAX_BYTES env vars (deploy.yml). Defaults
        # cap on-disk usage at ~50 MB, plenty for the volume of crawler
        # traffic we generate.
        max_files = env_int("LOG_MAX_FILES", 5)
        max_bytes = env_int("LOG_MAX_BYTES", 10_485_760)

        :ok =
          :logger.add_handler(:file_log, :logger_disk_log_h, %{
            config: %{
              file: file,
              type: :wrap,
              max_no_files: max_files,
              max_no_bytes: max_bytes
            },
            formatter:
              Logger.Formatter.new(
                format: "$time $metadata[$level] $message\n",
                metadata: [:request_id, :chain, :role]
              )
          })
    end
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil ->
        default

      "" ->
        default

      v ->
        case Integer.parse(v) do
          {n, _} when n > 0 -> n
          _ -> default
        end
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
