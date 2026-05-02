import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/super_barato start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :super_barato, SuperBaratoWeb.Endpoint, server: true
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      Example: /data/super_barato.db
      """

  # Each chain's Results worker hits the DB on every listing, plus
  # the streaming Linker opens its own transaction per link.
  # With pool_size=5 we hit `:queue_timeout` immediately when several
  # chains crawl in parallel. SQLite WAL handles writers single-file
  # via `busy_timeout` anyway, so the connection pool here is mostly
  # about queue depth, not parallelism.
  #
  # `busy_timeout` math (worst case, single batch):
  #   chains × batch_size × link_tx_ms
  #   = N × 44      × ~500ms
  #   = N × 22_000ms
  #
  # With six chains today that's ~132s in the absolute worst burst,
  # but in practice batches stagger across the cron window and only
  # one or two chains overlap at a time — observed real bursts have
  # all fit under 60s. 60s gives ~3 chains of headroom; budget
  # higher via `SQLITE_BUSY_TIMEOUT` if a future cron landing puts
  # 4+ chains writing simultaneously, or shard the Linker
  # to lift the underlying single-writer bottleneck. The 5s default
  # timed out under sustained crawler load and produced linker
  # error storms — never go back below 30s.
  config :super_barato, SuperBarato.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "20"),
    queue_target: 1_000,
    queue_interval: 5_000,
    journal_mode: :wal,
    busy_timeout: String.to_integer(System.get_env("SQLITE_BUSY_TIMEOUT") || "60000")

  # Crawler runtime paths. Both must be on a host volume in prod so
  # the price-log history and the curl-impersonate binary cache
  # survive container restarts and image upgrades.
  if dir = System.get_env("PRICE_LOG_DIR") do
    config :super_barato, price_log_dir: dir
  end

  if dir = System.get_env("CURL_IMPERSONATE_DIR") do
    config :super_barato, curl_impersonate_dir: dir
  end

  # FlareSolverr — used by the Worker to solve Cloudflare challenges
  # for cf_protected chains. Off when the env var is unset (worker
  # falls back to plain profile rotation).
  if url = System.get_env("FLARESOLVERR_URL") do
    config :super_barato, :flaresolverr, url: url
  end

  # Master switch for the crawler pipeline. Off-by-default in
  # config/config.exs; flip on per-deploy via env var.
  if System.get_env("CHAINS_ENABLED") in ~w(true 1) do
    config :super_barato, SuperBarato.Crawler, chains_enabled: true
  end

  # Per-chain HTTP proxy. Currently used to route Tottus through a
  # Chilean residential IP (the prod IP gets banned at Cloudflare's
  # edge). Format: `http://user:pass@host:port` or `socks5://...`.
  # Other chains stay direct unless their env var is set.
  chain_proxies =
    [
      {:tottus, System.get_env("TOTTUS_PROXY_URL")},
      {:lider, System.get_env("LIDER_PROXY_URL")},
      {:jumbo, System.get_env("JUMBO_PROXY_URL")},
      {:santa_isabel, System.get_env("SANTA_ISABEL_PROXY_URL")},
      {:unimarc, System.get_env("UNIMARC_PROXY_URL")},
      {:acuenta, System.get_env("ACUENTA_PROXY_URL")}
    ]
    |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
    |> Map.new()

  if map_size(chain_proxies) > 0 do
    config :super_barato, :chain_proxies, chain_proxies
  end

  # Cloudflare R2 — used by SuperBarato.Thumbnails to host
  # ~400px WebP thumbnails of product images. The endpoint is the
  # account-scoped S3 endpoint; the public base is the URL the home
  # cards point at (custom domain or pub-XXX.r2.dev). All five must
  # be set for thumbnail generation to run; missing config makes the
  # module a no-op and the cards fall back to raw `image_url`.
  if System.get_env("R2_ACCOUNT_ID") not in [nil, ""] do
    config :super_barato, :r2,
      account_id: System.get_env("R2_ACCOUNT_ID"),
      bucket: System.get_env("R2_BUCKET"),
      access_key_id: System.get_env("R2_ACCESS_KEY_ID"),
      secret_access_key: System.get_env("R2_SECRET_ACCESS_KEY"),
      public_base: System.get_env("R2_PUBLIC_BASE")
  end

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :super_barato, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # We serve the apex (`superbarato.cl`), `www.`, and the admin
  # subdomain off the same Phoenix endpoint, so the LiveView socket
  # has to accept Origin headers from all three. Without this, Phoenix
  # rejects the WS handshake from `admin.<host>` with
  # "Could not check origin for Phoenix.Socket transport" and the
  # client falls back to longpoll forever.
  config :super_barato, SuperBaratoWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: [
      "https://#{host}",
      "https://www.#{host}",
      "https://admin.#{host}"
    ],
    http: [
      # Enable IPv6 and bind on all interfaces. Port stays at the
      # Phoenix default 4000; Kamal's proxy fronts it.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :super_barato, SuperBaratoWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :super_barato, SuperBaratoWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # SendGrid — required for the signup confirmation flow. Without an
  # API key the mailer falls back to the local in-memory adapter so dev
  # and integration tests still work, but live signups would silently
  # drop confirmation emails. Fail fast in prod instead.
  sendgrid_api_key =
    System.get_env("SENDGRID_API_KEY") ||
      raise """
      environment variable SENDGRID_API_KEY is missing.
      Generate one at https://app.sendgrid.com/settings/api_keys with
      "Mail Send" permission.
      """

  config :super_barato, SuperBarato.Mailer,
    adapter: Swoosh.Adapters.Sendgrid,
    api_key: sendgrid_api_key

  # Verified sender — must match a SendGrid Single Sender or an address
  # on a domain whose DNS has been authenticated in SendGrid. SendGrid
  # rejects sends whose `from` doesn't pass one of those checks.
  config :super_barato,
         :mail_from,
         {
           System.get_env("MAIL_FROM_NAME") || "Super Barato (cl)",
           System.get_env("MAIL_FROM_ADDRESS") || "hola@superbarato.cl"
         }
end
