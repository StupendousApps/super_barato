# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

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

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  super_barato: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

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
    unimarc: [
      interval_ms: 1_000,
      fallback_profiles: [:chrome116, :chrome107, :chrome100, :chrome99],
      schedule: [
        # One-shot discovery push, weekly
        {{:every, {7, :days}},
         {SuperBarato.Crawler.Chain.Queue, :push,
          [:unimarc, {:discover_categories, %{chain: :unimarc, parent: nil}}]}},
        # Product walk: leaf categories from DB → per-category tasks
        {{:every, {1, :day}},
         {SuperBarato.Crawler.Chain.ProductProducer, :run, [[chain: :unimarc, mode: :products]]}},
        # Price refresh: active identifiers → 25-EAN batches (daily
        # cadence for now; can be tightened to hourly later).
        {{:every, {1, :day}},
         {SuperBarato.Crawler.Chain.ProductProducer, :run, [[chain: :unimarc, mode: :prices]]}}
      ]
    ],
    jumbo: [
      interval_ms: 1_000,
      fallback_profiles: [:chrome116, :chrome107, :chrome100, :chrome99],
      schedule: [
        {{:every, {7, :days}},
         {SuperBarato.Crawler.Chain.Queue, :push,
          [:jumbo, {:discover_categories, %{chain: :jumbo, parent: nil}}]}},
        {{:every, {1, :day}},
         {SuperBarato.Crawler.Chain.ProductProducer, :run, [[chain: :jumbo, mode: :products]]}},
        {{:every, {1, :day}},
         {SuperBarato.Crawler.Chain.ProductProducer, :run, [[chain: :jumbo, mode: :prices]]}}
      ]
    ],
    santa_isabel: [
      interval_ms: 1_000,
      fallback_profiles: [:chrome116, :chrome107, :chrome100, :chrome99],
      schedule: [
        {{:every, {7, :days}},
         {SuperBarato.Crawler.Chain.Queue, :push,
          [:santa_isabel, {:discover_categories, %{chain: :santa_isabel, parent: nil}}]}},
        {{:every, {1, :day}},
         {SuperBarato.Crawler.Chain.ProductProducer, :run,
          [[chain: :santa_isabel, mode: :products]]}},
        {{:every, {1, :day}},
         {SuperBarato.Crawler.Chain.ProductProducer, :run,
          [[chain: :santa_isabel, mode: :prices]]}}
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
        {{:every, {7, :days}},
         {SuperBarato.Crawler.Chain.Queue, :push,
          [:lider, {:discover_categories, %{chain: :lider, parent: nil}}]}},
        {{:every, {1, :day}},
         {SuperBarato.Crawler.Chain.ProductProducer, :run, [[chain: :lider, mode: :products]]}},
        {{:every, {1, :day}},
         {SuperBarato.Crawler.Chain.ProductProducer, :run, [[chain: :lider, mode: :prices]]}}
      ]
    ]
  ]

config :super_barato,
  # Directory containing curl-impersonate binaries (`curl_chrome116`,
  # `curl_chrome107`, `curl_ff117`, etc.).
  curl_impersonate_dir: Path.expand("../priv/bin", __DIR__),
  # Default profile for chains that don't specify their own.
  curl_impersonate_profile: :chrome116

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
