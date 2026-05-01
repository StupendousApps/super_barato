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

# Crawler: pipeline knobs.
#
# Two-layer config: `defaults: [...]` carries every tunable knob with
# its baseline value, and each entry in `chains: [...]` only carries
# the chain's overrides plus its `:schedule`. `SuperBarato.Crawler.opts_for/1`
# merges defaults with the chain block (chain wins) and returns a flat
# keyword list for the chain's Supervisor — every place that needs a
# resolved knob reads it through that single function.
#
# Defaults live here at compile time; per-chain overrides land in the
# `chains:` block below; no resolver path looks elsewhere.
config :super_barato, SuperBarato.Crawler,
  # Whether the pipeline supervisors start with the app. Off by default
  # — Mix tasks drive the crawler synchronously via handle_task/1.
  # Flip on in env-specific config (e.g. prod) when you want the Cron-
  # driven background pipeline running.
  chains_enabled: false,
  defaults: [
    # Pacing — minimum gap between successive Worker HTTP requests for
    # this chain. Lider raises to 2s in its override (Akamai-shaped).
    interval_ms: 1_000,
    # Queue depth + low-water producer-restart threshold (60% of cap).
    # Producers backpressure on the high-water mark and resume when
    # consumption drains below low-water.
    queue_capacity: 50,
    queue_low_water: 30,
    # curl-impersonate profile rotation order. Worker starts on the
    # head and rotates on :blocked. Lider needs an older-Chromium-only
    # list to slip past Akamai (override below).
    fallback_profiles: [:chrome116, :chrome107, :chrome100, :chrome99],
    # How long a chain stays "blocked" before Worker tries again after
    # the fallback list is exhausted.
    block_backoff_ms: 60_000,
    # Cloudflare front detection. cf_protected: true makes Worker push
    # a `cf_clearance` cookie obtained from FlareSolverr; cf_homepage
    # is the URL FlareSolverr probes to mint that cookie. Off by
    # default; only Tottus flips it on (or used to — see chain note).
    cf_protected: false,
    cf_homepage: nil
  ],
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
    # PersistenceServer appends every observation to PriceLog.
    #
    # Three-stage cron pattern across all chains:
    #   * stage 1 (CategoryProducer) — weekly Monday discovery.
    #   * stage 2 (ProductProducer)  — weekly Monday discovery.
    #   * stage 3 (ListingProducer)  — daily Tue–Sun price refresh.
    unimarc: [
      schedule: [
        {{:weekly, [:mon], [~T[04:00:00]]},
         {SuperBarato.Crawler.Chain.CategoryProducer, :run, [[chain: :unimarc]]}},
        {{:weekly, [:mon], [~T[05:00:00]]},
         {SuperBarato.Crawler.Chain.ProductProducer, :run, [[chain: :unimarc]]}},
        # Stage 3 refresh — re-runs ProductProducer (full leaf-category
        # walk) rather than ListingProducer (per-PDP fetch). Unimarc's
        # BFF returns price + EAN per row in the search response, so a
        # per-PDP fetch would just re-derive what the search already
        # gave us.
        {{:weekly, [:tue, :wed, :thu, :fri, :sat, :sun], [~T[05:00:00]]},
         {SuperBarato.Crawler.Chain.ProductProducer, :run, [[chain: :unimarc]]}}
      ]
    ],
    # Jumbo + Santa Isabel are Cencosud chains served from Instaleap's
    # `sm-web-api.ecomm.cencosud.com/catalog/api`, the same endpoint
    # Acuenta uses. Stage 2 + 3 both run the category-walk
    # ProductProducer (one HTTP request returns 40 priced products).
    # The legacy sitemap-driven path (Cencosud.ProductProducer) is
    # left implemented for fall-back use but no longer scheduled —
    # at 1 req/s per PDP a full Jumbo pass took ~14 h, Santa Isabel
    # ~4 h, vs. ~20 min and ~5 min through the category endpoint.
    jumbo: [
      schedule: [
        {{:weekly, [:mon], [~T[04:15:00]]},
         {SuperBarato.Crawler.Chain.CategoryProducer, :run, [[chain: :jumbo]]}},
        {{:weekly, [:mon], [~T[05:30:00]]},
         {SuperBarato.Crawler.Chain.ProductProducer, :run, [[chain: :jumbo]]}},
        {{:weekly, [:tue, :wed, :thu, :fri, :sat, :sun], [~T[05:30:00]]},
         {SuperBarato.Crawler.Chain.ProductProducer, :run, [[chain: :jumbo]]}}
      ]
    ],
    santa_isabel: [
      schedule: [
        {{:weekly, [:mon], [~T[04:30:00]]},
         {SuperBarato.Crawler.Chain.CategoryProducer, :run, [[chain: :santa_isabel]]}},
        {{:weekly, [:mon], [~T[06:00:00]]},
         {SuperBarato.Crawler.Chain.ProductProducer, :run, [[chain: :santa_isabel]]}},
        {{:weekly, [:tue, :wed, :thu, :fri, :sat, :sun], [~T[06:00:00]]},
         {SuperBarato.Crawler.Chain.ProductProducer, :run, [[chain: :santa_isabel]]}}
      ]
    ],
    # Tottus is on Cloudflare and the prod IP is banned at the edge.
    # No fingerprint rotation, FlareSolverr solve, or header tweak
    # gets past it — the only realistic fix is a CL residential
    # egress (laptop/RPi/proxy). Worker stays scheduled so manual
    # triggers can still run from a future CL-resident host; in prod
    # today every request will fail with :blocked / 403.
    tottus: [
      schedule: [
        {{:weekly, [:mon], [~T[04:30:00]]},
         {SuperBarato.Crawler.Chain.CategoryProducer, :run, [[chain: :tottus]]}},
        {{:weekly, [:mon], [~T[07:00:00]]},
         {SuperBarato.Crawler.Chain.ProductProducer, :run, [[chain: :tottus]]}},
        {{:weekly, [:tue, :wed, :thu, :fri, :sat, :sun], [~T[07:00:00]]},
         {SuperBarato.Crawler.Chain.ListingProducer, :run, [[chain: :tottus]]}}
      ]
    ],
    # Lider's Akamai blocks Chrome 110+; only older Chrome profiles
    # pass. We lead with chrome107 (confirmed working) and fall back to
    # 104/100/99 if it ever starts getting challenged.
    # Acuenta — Walmart Chile's discount banner, storefronted by
    # Instaleap. All listing data flows through a single GraphQL
    # endpoint; no Cloudflare/Akamai in front, so curl-impersonate
    # profiles are belt-and-braces (we POST JSON, no fingerprinting
    # to defeat).
    #
    # No `fetch_product_pdp` implementation — Instaleap doesn't expose
    # a per-EAN/per-SKU lookup we know of, so daily price refresh
    # re-runs ProductProducer (full leaf-category walk) instead of
    # ListingProducer. Slower but accurate; ~10k products at 1 req/s
    # ≈ 3 hours per refresh, well within a single off-peak window.
    acuenta: [
      schedule: [
        {{:weekly, [:mon], [~T[05:00:00]]},
         {SuperBarato.Crawler.Chain.CategoryProducer, :run, [[chain: :acuenta]]}},
        {{:weekly, [:mon], [~T[07:30:00]]},
         {SuperBarato.Crawler.Chain.ProductProducer, :run, [[chain: :acuenta]]}},
        {{:weekly, [:tue, :wed, :thu, :fri, :sat, :sun], [~T[07:30:00]]},
         {SuperBarato.Crawler.Chain.ProductProducer, :run, [[chain: :acuenta]]}}
      ]
    ],
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
         {SuperBarato.Crawler.Chain.CategoryProducer, :run, [[chain: :lider]]}},
        {{:weekly, [:mon], [~T[06:30:00]]},
         {SuperBarato.Crawler.Chain.ProductProducer, :run, [[chain: :lider]]}},
        # Stage 3 refresh — re-runs ProductProducer (full leaf-category
        # walk) rather than ListingProducer. Lider's `__NEXT_DATA__`
        # search response already carries price + UPC/usItemId per
        # row, so per-PDP fetch is wasted work.
        {{:weekly, [:tue, :wed, :thu, :fri, :sat, :sun], [~T[06:30:00]]},
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
