import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :super_barato, SuperBarato.Repo,
  database:
    Path.expand(
      "../priv/data/super_barato_test#{System.get_env("MIX_TEST_PARTITION")}.db",
      __DIR__
    ),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5,
  # SQLite only allows one writer at a time; WAL lets readers proceed
  # while a writer holds the lock, and busy_timeout makes parallel
  # sandbox checkouts wait instead of raising SQLITE_BUSY.
  journal_mode: :wal,
  busy_timeout: 5_000

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :super_barato, SuperBaratoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4103],
  secret_key_base: "tUeg5nsolwXz9pUD2F0aGphrEQSb55G9+igpE31O7/bhV8tGCz3NpoeJSx/T5XCM",
  server: false

# In test we don't send emails
config :super_barato, SuperBarato.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
