defmodule PumbleAutomation.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias PumbleAutomation.Diagnostics.Export
  alias PumbleAutomation.Ingress.RateLimiter

  @impl true
  def start(_type, _args) do
    PumbleAutomation.Logging.setup()
    Export.setup()

    children = [
      PumbleAutomationWeb.Telemetry,
      PumbleAutomation.Repo,
      {DNSCluster, query: Application.get_env(:pumble_automation, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PumbleAutomation.PubSub},
      # Oban starts after the Repo, because it needs the database, and before
      # the Endpoint, so that no request can enqueue work into a stopped queue.
      {Oban, Application.fetch_env!(:pumble_automation, Oban)},
      RateLimiter,
      # Start to serve requests, typically the last entry
      PumbleAutomationWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PumbleAutomation.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PumbleAutomationWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
