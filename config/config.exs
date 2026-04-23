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
  rate_limits: [
    unimarc: [interval_ms: 1_000]
  ]

config :super_barato,
  # curl-impersonate binary path. Override via env-specific config if needed.
  curl_impersonate_binary: Path.expand("../priv/bin/curl_chrome116", __DIR__)

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
