defmodule PumbleAutomationWeb.HealthController do
  @moduledoc """
  The two operational endpoints, and nothing else.

  Both are unauthenticated, because the component that reads them — a load
  balancer, a container orchestrator, an uptime probe — has no credential to
  offer. That is only acceptable while the responses stay free of information an
  attacker could use, so a response here is a fixed set of keys whose values are
  `"ok"` or `"error"`. No version, no host, no queue name, no migration number,
  and no error reason ever reaches the body. The reason is logged and emitted as
  telemetry instead, where an operator can read it and the public cannot.
  """

  use PumbleAutomationWeb, :controller

  alias PumbleAutomation.Health
  alias PumbleAutomation.Logging

  @service_unavailable 503

  @doc """
  Answers `200` whenever this node can run code.

  It performs no database query, so a database incident never causes a restart
  loop. See `PumbleAutomation.Health` for why the two endpoints differ.
  """
  @spec live(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def live(conn, _params) do
    :ok = Health.liveness()
    json(conn, %{status: "ok"})
  end

  @doc """
  Answers `200` when every readiness probe passes and `503` when any fails.

  The body has the same shape either way, so a probe can be parsed without
  branching on the status code.
  """
  @spec ready(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ready(conn, _params) do
    report = Health.readiness()
    log_readiness(report)

    conn
    |> put_status(http_status(report.status))
    |> json(%{status: to_string(report.status), checks: render_checks(report.checks)})
  end

  defp http_status(:ok), do: :ok
  defp http_status(:error), do: @service_unavailable

  defp render_checks(checks) do
    Map.new(checks, fn {check, status} -> {to_string(check), to_string(status)} end)
  end

  defp log_readiness(%{status: :ok}), do: :ok

  defp log_readiness(%{status: :error, errors: errors}) do
    Enum.each(errors, fn error ->
      Logging.event(:warning, "health.ready", %{
        operation: "health.ready",
        status: "error",
        error_code: error.code,
        error_class: error.class,
        event_type: "health"
      })
    end)
  end
end
