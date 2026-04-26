# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :super_barato, :scopes,
  user: [
    default: true,
    module: SuperBarato.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: SuperBarato.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :super_barato,
  ecto_repos: [SuperBarato.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :super_barato, SuperBaratoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SuperBaratoWeb.ErrorHTML, json: SuperBaratoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SuperBarato.PubSub,
  live_view: [signing_salt: "euQYomdG"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :super_barato, SuperBarato.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  super_barato: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger. Metadata includes :chain and :role so
# pipeline log lines show which supermarket and which GenServer
# produced them — the Worker/Results/Cron/Producer modules all call
# Logger.metadata(chain: ..., role: ...) in their init.
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :chain, :role]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Crawler: per-chain rate limits (shared by discovery and price fetches).
config :super_barato, SuperBarato.Crawler,
  # Whether the pipeline supervisors start with the app. Off by default
  # — Mix tasks drive the crawler synchronously via handle_task/1.
  # Flip on in env-specific config (e.g. prod) when you want the Cron-
  # driven background pipeline running.
  chains_enabled: false,
  chains: [
    # Schedules are staggered so chains don't all pound the network
    # at the same moment. Times are UTC — Chile is UTC-3 (standard) /
    # UTC-4 (DST); 05:00 UTC ≈ 02:00 CLT, well into off-hours.
    # Weekly "daily" = all 7 days; weekly one-shot = a single day.
    # Times are UTC — staggered across chains to avoid concurrent
    # bursts. CLT off-hours (02:00–06:00) = 05:00–09:00 UTC.
    #
    # `products` does both discovery and price refresh: the search
    # endpoints return current prices alongside product data, and
    # Chain.Results appends every observation to PriceLog.
    unimarc: [
      interval_ms: 1_000,
      fallback_profiles: [:chrome116, :chrome107, :chrome100, :chrome99],
      schedule: [
        # Weekly category discovery — Monday 04:00 UTC.
        {{:weekly, [:mon], [~T[04:00:00]]},
         {SuperBarato.Crawler.Chain.Queue, :push,
          [:unimarc, {:discover_categories, %{chain: :unimarc, parent: nil}}]}},
        # Daily product walk (captures prices as a side effect).
        {{:weekly, [:mon, :tue, :wed, :thu, :fri, :sat, :sun], [~T[05:00:00]]},
         {SuperBarato.Crawler.Chain.ProductProducer, :run, [[chain: :unimarc]]}}
      ]
    ],
    # Jumbo + Santa Isabel use sitemap-driven discovery: PDPs on
    # `www.<chain>.cl` are served from Cencosud's nginx (no Cloudflare,
    # reachable from prod) and the sitemaps live on CloudFront/S3
    # (also unprotected). Daily product walks use SitemapProducer
    # which streams every PDP URL into the chain Queue. At 1 req/s a
    # full Jumbo pass takes ~14 hours; Santa Isabel ~4 hours.
    jumbo: [
      interval_ms: 1_000,
      fallback_profiles: [:chrome116, :chrome107, :chrome100, :chrome99],
      schedule: [
        {{:weekly, [:mon], [~T[04:15:00]]},
         {SuperBarato.Crawler.Chain.Queue, :push,
          [:jumbo, {:discover_categories, %{chain: :jumbo, parent: nil}}]}},
        {{:weekly, [:mon, :tue, :wed, :thu, :fri, :sat, :sun], [~T[05:30:00]]},
         {SuperBarato.Crawler.Cencosud.SitemapProducer, :run, [[chain: :jumbo]]}}
      ]
    ],
    santa_isabel: [
      interval_ms: 1_000,
      fallback_profiles: [:chrome116, :chrome107, :chrome100, :chrome99],
      schedule: [
        {{:weekly, [:mon], [~T[04:30:00]]},
         {SuperBarato.Crawler.Chain.Queue, :push,
          [:santa_isabel, {:discover_categories, %{chain: :santa_isabel, parent: nil}}]}},
        {{:weekly, [:mon, :tue, :wed, :thu, :fri, :sat, :sun], [~T[06:00:00]]},
         {SuperBarato.Crawler.Cencosud.SitemapProducer, :run, [[chain: :santa_isabel]]}}
      ]
    ],
    # Tottus is on Cloudflare and the prod IP is banned at the edge.
    # No fingerprint rotation, FlareSolverr solve, or header tweak
    # gets past it — the only realistic fix is a CL residential
    # egress (laptop/RPi/proxy). Worker stays scheduled so manual
    # triggers can still run from a future CL-resident host; in prod
    # today every request will fail with :blocked / 403.
    tottus: [
      interval_ms: 1_000,
      fallback_profiles: [:chrome116, :chrome107, :chrome100, :chrome99],
      schedule: [
        {{:weekly, [:mon], [~T[04:30:00]]},
         {SuperBarato.Crawler.Chain.Queue, :push,
          [:tottus, {:discover_categories, %{chain: :tottus, parent: nil}}]}},
        {{:weekly, [:mon, :tue, :wed, :thu, :fri, :sat, :sun], [~T[07:00:00]]},
         {SuperBarato.Crawler.Chain.ProductProducer, :run, [[chain: :tottus]]}}
      ]
    ],
    # Lider's Akamai blocks Chrome 110+; only older Chrome profiles
    # pass. We lead with chrome107 (confirmed working) and fall back to
    # 104/100/99 if it ever starts getting challenged.
    lider: [
      interval_ms: 2_000,
      # Only older Chromium-family profiles slip past Akamai's JA3
      # blocklist on Lider. All Firefox and Safari profiles get
      # challenged. Verified 2026-04.
      fallback_profiles: [
        :chrome107,
        :chrome104,
        :chrome101,
        :chrome100,
        :chrome99,
        :chrome99_android,
        :edge101,
        :edge99
      ],
      schedule: [
        {{:weekly, [:mon], [~T[04:45:00]]},
         {SuperBarato.Crawler.Chain.Queue, :push,
          [:lider, {:discover_categories, %{chain: :lider, parent: nil}}]}},
        {{:weekly, [:mon, :tue, :wed, :thu, :fri, :sat, :sun], [~T[06:30:00]]},
         {SuperBarato.Crawler.Chain.ProductProducer, :run, [[chain: :lider]]}}
      ]
    ]
  ]

config :super_barato,
  # Directory containing curl-impersonate binaries (`curl_chrome116`,
  # `curl_chrome107`, `curl_ff117`, etc.).
  curl_impersonate_dir: Path.expand("../priv/bin", __DIR__),
  # Default profile for chains that don't specify their own.
  curl_impersonate_profile: :chrome116,
  # Append-only price history lives here. Prod should override to
  # something outside the release dir (e.g. `/data/prices`).
  price_log_dir: Path.expand("../priv/data/prices", __DIR__)

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
