defmodule PumbleAutomation.HealthProbes do
  @moduledoc """
  Deterministic stand-ins for the readiness probes.

  A readiness failure has to be provable, and the honest ways to provoke a real
  one — stop PostgreSQL, roll the schema back — would break the database the
  test suite is running in and every other test with it. These modules fail on
  demand instead, behind the same behaviour the production probes implement, so
  the code under test is unchanged and only the answer differs.
  """

  alias PumbleAutomation.Error

  @doc "The error the failing probes report."
  @spec unavailable(atom()) :: Error.t()
  def unavailable(code) do
    Error.new(:dependency, code, message: "A dependency is unavailable.", retryable?: true)
  end
end

defmodule PumbleAutomation.HealthProbes.DatabaseDown do
  @moduledoc "Reports the database as unreachable and everything else as fine."

  @behaviour PumbleAutomation.Health

  alias PumbleAutomation.HealthProbes

  @impl PumbleAutomation.Health
  def ping(_timeout), do: {:error, HealthProbes.unavailable(:database_unavailable)}

  @impl PumbleAutomation.Health
  def migration_status, do: :ok

  @impl PumbleAutomation.Health
  def queue_status, do: :ok
end

defmodule PumbleAutomation.HealthProbes.MigrationsPending do
  @moduledoc "Reports the schema as behind the release and everything else as fine."

  @behaviour PumbleAutomation.Health

  alias PumbleAutomation.HealthProbes

  @impl PumbleAutomation.Health
  def ping(_timeout), do: :ok

  @impl PumbleAutomation.Health
  def migration_status, do: {:error, HealthProbes.unavailable(:migrations_pending)}

  @impl PumbleAutomation.Health
  def queue_status, do: :ok
end

defmodule PumbleAutomation.HealthProbes.QueuesDown do
  @moduledoc "Reports the job runtime as unavailable and everything else as fine."

  @behaviour PumbleAutomation.Health

  alias PumbleAutomation.HealthProbes

  @impl PumbleAutomation.Health
  def ping(_timeout), do: :ok

  @impl PumbleAutomation.Health
  def migration_status, do: :ok

  @impl PumbleAutomation.Health
  def queue_status, do: {:error, HealthProbes.unavailable(:job_runtime_unavailable)}
end

defmodule PumbleAutomation.HealthProbes.Raising do
  @moduledoc """
  Raises and exits instead of answering.

  It exists to prove that readiness fails closed. A probe that cannot answer is
  not a yes, and it must not become a hung request either.
  """

  @behaviour PumbleAutomation.Health

  @impl PumbleAutomation.Health
  def ping(_timeout),
    do: raise(RuntimeError, "connection refused for user postgres at db.internal")

  @impl PumbleAutomation.Health
  def migration_status, do: exit(:killed)

  @impl PumbleAutomation.Health
  def queue_status, do: :ok
end
