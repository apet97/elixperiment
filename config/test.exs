import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :pumble_automation, PumbleAutomation.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "pumble_automation_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  ownership_timeout: 60_000,
  timeout: 15_000,
  queue_target: 50,
  queue_interval: 1_000

# Deterministic test values. Only this file may define them; production reads
# every one of these from the environment through PumbleAutomation.Config.
config :pumble_automation,
  public_url: "http://localhost:4002",
  pumble: [
    client_id: "test-client-id",
    client_secret: "test-client-secret",
    app_key: "test-app-key",
    signing_secret: "test-signing-secret"
  ],
  encryption: [key: :binary.copy(<<1>>, 32), key_version: 1, legacy_keys: %{}],
  session_signing_salt: "test-session-salt"

# Every outbound Pumble request goes to a `Req.Test` stub instead of the network.
# This is the only supported way to exercise `PumbleAutomation.Pumble.OauthClient`
# offline, and it means a test that forgets to install a stub fails loudly rather
# than reaching a real host. See `PumbleAutomation.PumbleFake`.
config :pumble_automation,
  pumble_http_options: [plug: {Req.Test, PumbleAutomation.Pumble.OauthClient}]

# The JSON API client has a stub of its own, so a test about an API operation
# and a test about the token exchange cannot install stubs over each other.
config :pumble_automation,
  pumble_api_http_options: [plug: {Req.Test, PumbleAutomation.Pumble.Client}]

# Oban runs no queues and no plugins in test. `testing: :manual` keeps inserted
# jobs in the database so a test can assert on them, and never executes them
# unless the test drains a queue explicitly.
config :pumble_automation, Oban, testing: :manual

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :pumble_automation, PumbleAutomationWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "tuUXZNrq/LKZpsVRPRmpEziBzVc/AvYZOpJ1hXMjUa8liAO8Wjjjw8Tv9pVeIjsi",
  server: false

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
