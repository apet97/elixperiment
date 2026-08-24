defmodule PumbleAutomation.Health do
  @moduledoc """
  Liveness and readiness, expressed without any web type.

  ## The two questions are different

  Liveness asks whether this BEAM node still runs its own code. It touches no
  database, no queue, and no external API. An orchestrator restarts a container
  that fails liveness, so a liveness check that depends on PostgreSQL turns a
  database incident into a restart loop that makes the incident worse.

  Readiness asks whether this node can serve traffic right now. It is allowed to
  fail while the process stays up: a node that is not ready is removed from the
  load balancer and put back when it recovers, with no restart.

  ## Fail closed, and quickly

  Every readiness probe runs under a bounded timeout and inside a rescue. A
  probe that raises, exits, or times out is a failed probe, never a hung
  request. Reporting "not ready" costs one node; hanging the health endpoint
  costs the whole rollout, because the orchestrator learns nothing.

  ## Injecting probes

  The probes live behind this module's behaviour and are resolved at call time
  from `:health_probe` in the application environment, defaulting to
  `PumbleAutomation.Health.RepoProbe`. That indirection exists so a test can
  prove the failure branches — database down, schema behind — without breaking
  the database it is running against.

  ## Telemetry

  Each probe emits `[:pumble_automation, :health, :check]` with a `:duration`
  measurement in native units and `%{check: check, status: :ok | :error}`
  metadata. `PumbleAutomationWeb.Telemetry` turns it into a latency summary and
  a failure counter.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Health.RepoProbe

  @default_timeout_ms 2_000

  @typedoc "The name of one readiness probe."
  @type check :: :database | :migrations | :queues

  @typedoc "The outcome of a readiness evaluation."
  @type report :: %{
          status: :ok | :error,
          checks: [{check(), :ok | :error}],
          errors: [Error.t()]
        }

  @typedoc "What a probe returns."
  @type outcome :: :ok | {:error, Error.t()}

  @doc "Answers whether the database accepts a trivial bounded query."
  @callback ping(timeout :: timeout()) :: outcome()

  @doc "Answers whether every migration this release ships has been applied."
  @callback migration_status() :: outcome()

  @doc "Answers whether the durable job runtime is configured and running."
  @callback queue_status() :: outcome()

  @doc """
  Proves that this node runs its own code.

  It has no arguments and no dependencies on purpose. If this function returns,
  the scheduler is running, the module is loaded, and the endpoint dispatched a
  request to it. That is the whole claim; it deliberately makes no other.
  """
  @spec liveness() :: :ok
  def liveness, do: :ok

  @doc """
  Evaluates every readiness probe and summarises them.

  Options:

    * `:probe` — the module implementing this behaviour. Defaults to the
      application environment, then to `PumbleAutomation.Health.RepoProbe`.
    * `:timeout` — the per-probe bound in milliseconds. Defaults to 2000.

  Probes always all run, so one failure does not hide another in the report.
  """
  @spec readiness(keyword()) :: report()
  def readiness(opts \\ []) do
    probe = Keyword.get_lazy(opts, :probe, &configured_probe/0)
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    results = [
      {:database, measure(:database, fn -> probe.ping(timeout) end)},
      {:migrations, measure(:migrations, fn -> probe.migration_status() end)},
      {:queues, measure(:queues, fn -> probe.queue_status() end)}
    ]

    %{
      status: overall_status(results),
      checks: Enum.map(results, fn {check, outcome} -> {check, status_of(outcome)} end),
      errors: for({_check, {:error, error}} <- results, do: error)
    }
  end

  @doc """
  Returns the probe module used when no `:probe` option is given.
  """
  @spec configured_probe() :: module()
  def configured_probe do
    Application.get_env(:pumble_automation, :health_probe, RepoProbe)
  end

  # Runs one probe under a rescue and a catch, then reports how long it took.
  # A raised exception and an exit are both failures: the caller asked whether
  # this node is ready, and a probe that cannot answer is not a yes.
  defp measure(check, fun) do
    started_at = System.monotonic_time()
    outcome = run(check, fun)
    duration = System.monotonic_time() - started_at

    :telemetry.execute(
      [:pumble_automation, :health, :check],
      %{duration: duration},
      %{check: check, status: status_of(outcome)}
    )

    outcome
  end

  defp run(check, fun) do
    fun.()
  rescue
    exception -> {:error, probe_failure(check, :health_probe_raised, exception.__struct__)}
  catch
    :exit, _reason -> {:error, probe_failure(check, :health_probe_exited, :exit)}
  end

  # Only the failing check and the kind of failure are kept. The exception
  # message is dropped on purpose: connection errors quote the host, the port,
  # and sometimes the user of the database they failed to reach.
  defp probe_failure(check, code, kind) do
    Error.new(:dependency, code,
      message: "A readiness check could not complete.",
      retryable?: true,
      details: %{check: check, kind: inspect(kind)}
    )
  end

  defp overall_status(results) do
    if Enum.all?(results, fn {_check, outcome} -> outcome == :ok end), do: :ok, else: :error
  end

  defp status_of(:ok), do: :ok
  defp status_of({:error, _error}), do: :error
end
