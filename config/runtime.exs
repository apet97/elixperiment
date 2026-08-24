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
#     PHX_SERVER=true bin/pumble_automation start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :pumble_automation, PumbleAutomationWeb.Endpoint, server: true
end

config :pumble_automation, PumbleAutomationWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :pumble_automation, PumbleAutomationWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/pumble_automation_web/router\.ex$"E,
        ~r"lib/pumble_automation_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # Every production setting is parsed and validated up front. A missing or
  # malformed variable aborts the boot before the endpoint or any job starts.
  # Errors name the variable only; they never echo a value.
  settings = PumbleAutomation.Config.load_prod!(System.get_env())

  config :pumble_automation, PumbleAutomation.Repo,
    url: settings.database_url,
    ssl: settings.database_ssl,
    pool_size: settings.pool_size,
    timeout: 15_000,
    queue_target: 50,
    queue_interval: 1_000,
    socket_options: if(settings.database_ipv6, do: [:inet6], else: [])

  config :pumble_automation, :dns_cluster_query, settings.dns_cluster_query

  config :pumble_automation,
    public_url: settings.public_url.url,
    pumble: [
      client_id: settings.pumble_client_id,
      client_secret: settings.pumble_client_secret,
      app_key: settings.pumble_app_key,
      signing_secret: settings.pumble_signing_secret,
      bot_scopes: settings.pumble_bot_scopes,
      user_scopes: settings.pumble_user_scopes
    ],
    encryption: [
      key: settings.encryption_key,
      key_version: settings.encryption_key_version,
      legacy_keys: settings.encryption_legacy_keys
    ],
    session_signing_salt: settings.session_signing_salt,
    queue_concurrency: settings.queue_concurrency,
    limits: settings.limits,
    trusted_proxies: settings.trusted_proxies

  config :logger, level: settings.log_level

  # Queue names are fixed by the plan; only concurrency is tunable per
  # deployment through QUEUE_CONCURRENCY_* variables.
  config :pumble_automation, Oban, queues: settings.queue_concurrency

  config :pumble_automation, allowed_hosts: [settings.public_url.host]

  config :pumble_automation, PumbleAutomationWeb.Endpoint,
    url: [
      host: settings.public_url.host,
      port: settings.public_url.port,
      scheme: settings.public_url.scheme
    ],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: settings.port
    ],
    secret_key_base: settings.secret_key_base,
    live_view: [signing_salt: settings.session_signing_salt],
    check_origin: [settings.public_url.url]

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :pumble_automation, PumbleAutomationWeb.Endpoint,
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
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :pumble_automation, PumbleAutomationWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
