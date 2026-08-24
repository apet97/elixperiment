defmodule PumbleAutomation.Maintenance do
  @moduledoc """
  Durable scheduling, pause/run-once controls, and bounded integrity checks.

  Reconciliation, retention, OAuth/session cleanup, and integrity each have one
  incomplete Oban job at a time. Cron inserts the next tick after a job
  completes or is discarded; uniqueness never includes discarded rows, so
  exhaustion cannot silence the scheduler. Occupancy-parked queued executions
  are not missing jobs — `Engine.reconcile/1` already keeps that invariant.

  ## Commands

      PumbleAutomation.Maintenance.pause(:retention)
      PumbleAutomation.Maintenance.resume(:retention)
      PumbleAutomation.Maintenance.run_once(:reconcile)
      PumbleAutomation.Maintenance.run_once(scope, :integrity)

  Pause skips the scheduled worker until resume. `run_once/1` and owner
  `run_once/2` set `force` and still run. Owner run-once is audited.

  ## Expected duration

  Each tick is capped by a 10s time budget and a small batch. Typical empty
  ticks finish in well under a second. A full retention sweep of tens of
  thousands of due rows snoozes and continues on the next attempt rather than
  holding the queue.

  | Kind | Cron (UTC) | Batch | Budget | Typical |
  |---|---|---|---|---|
  | reconcile | every 5 minutes | 100 repairs | 10s | empty tick < 1s |
  | cleanup | :17 past each hour | 500 rows | 10s | empty tick < 1s |
  | integrity | :47 past each hour | 50 rows | 10s | empty tick < 1s |
  | retention | 03:23 daily | 500 rows, 20 batches | 10s | continues via snooze |

  See `docs/operations/maintenance.md`.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias PumbleAutomation.Audit.Writer
  alias PumbleAutomation.Connections.Secret
  alias PumbleAutomation.Diagnostics.Export
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Workers.RetentionWorker
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.OauthStates
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Installations.Service
  alias PumbleAutomation.Installations.Sessions
  alias PumbleAutomation.Logging
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Retention
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows.Schedule
  alias PumbleAutomation.Workflows.TriggerBinding
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomation.Workflows.WorkflowVersion

  @kinds [:reconcile, :retention, :cleanup, :integrity]
  @pause_env :maintenance_paused
  @budget_ms 10_000
  @reconcile_continue_after 100
  @cleanup_batch 500
  @integrity_batch 50
  @retention_max_batches 20
  @incomplete_job_states ~w(available scheduled executing retryable)
  @telemetry_run [:pumble_automation, :maintenance, :run]
  @telemetry_alert [:pumble_automation, :maintenance, :alert]
  @retention_worker Oban.Worker.to_string(RetentionWorker)

  @type kind :: :reconcile | :retention | :cleanup | :integrity

  @type summary :: %{
          kind: kind(),
          repaired: non_neg_integer(),
          alerts: non_neg_integer(),
          continue?: boolean()
        }

  @doc "The four scheduled maintenance kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Default wall-clock budget for one tick, in milliseconds."
  @spec budget_ms() :: pos_integer()
  def budget_ms, do: @budget_ms

  @doc "Expected duration and schedule for one kind."
  @spec expected_duration(kind()) :: %{
          cron: String.t(),
          budget_ms: pos_integer(),
          typical: String.t()
        }
  def expected_duration(:reconcile) do
    %{cron: "*/5 * * * *", budget_ms: @budget_ms, typical: "empty tick under 1s; cap 10s"}
  end

  def expected_duration(:cleanup) do
    %{cron: "17 * * * *", budget_ms: @budget_ms, typical: "empty tick under 1s; cap 10s"}
  end

  def expected_duration(:integrity) do
    %{cron: "47 * * * *", budget_ms: @budget_ms, typical: "empty tick under 1s; cap 10s"}
  end

  def expected_duration(:retention) do
    %{cron: "23 3 * * *", budget_ms: @budget_ms, typical: "bounded batches; snooze if more due"}
  end

  @doc "Whether scheduled jobs of `kind` should no-op."
  @spec paused?(kind()) :: boolean()
  def paused?(kind) when kind in @kinds, do: MapSet.member?(paused_set(), kind)

  @doc "Pause scheduled jobs of `kind`. Run-once still works."
  @spec pause(kind()) :: :ok | {:error, Error.t()}
  def pause(kind) do
    with {:ok, kind} <- cast_kind(kind) do
      Application.put_env(:pumble_automation, @pause_env, MapSet.put(paused_set(), kind))
      :ok
    end
  end

  @doc "Resume scheduled jobs of `kind`."
  @spec resume(kind()) :: :ok | {:error, Error.t()}
  def resume(kind) do
    with {:ok, kind} <- cast_kind(kind) do
      Application.put_env(:pumble_automation, @pause_env, MapSet.delete(paused_set(), kind))
      :ok
    end
  end

  @doc """
  Runs one maintenance kind.

  Pass a `Scope` for the audited owner path (editors and viewers are refused).
  Pass a kind, optionally with args, for the system command; that path sets
  `force` so a paused kind still runs. Job args stay identifiers and cursors.
  """
  @spec run_once(Scope.t(), kind()) :: {:ok, summary()} | {:error, Error.t()}
  @spec run_once(kind(), map() | keyword()) ::
          :ok | {:snooze, pos_integer()} | {:error, atom() | Error.t()}
  def run_once(%Scope{} = scope, kind) do
    with :ok <- Policy.authorize(scope, :destructive_lifecycle),
         {:ok, kind} <- cast_kind(kind) do
      args = %{"force" => true, "installation_id" => scope.installation_id}

      case run(kind, args) do
        {:ok, summary} ->
          audit_owner_run(scope, kind, summary)
          {:ok, summary}

        {:error, %Error{} = error} ->
          {:error, error}
      end
    end
  end

  def run_once(kind, opts) when is_atom(kind) or is_binary(kind) do
    with {:ok, kind} <- cast_kind(kind) do
      perform(kind, Map.put(stringify(opts), "force", true))
    end
  end

  @spec run_once(kind()) :: :ok | {:snooze, pos_integer()} | {:error, atom() | Error.t()}
  def run_once(kind), do: run_once(kind, %{})

  @doc """
  Worker entry: honour pause unless `force` is set, then run one bounded tick.
  """
  @spec perform(kind(), map()) :: :ok | {:snooze, pos_integer()} | {:error, atom()}
  def perform(kind, args) when kind in @kinds and is_map(args) do
    args = stringify(args)

    if paused?(kind) and not force?(args) do
      emit_run(kind, empty(kind), "paused")
      :ok
    else
      finish_tick(kind, run(kind, args))
    end
  end

  defp run(:reconcile, args) do
    case Engine.reconcile(Map.take(args, ["installation_id", "actor"])) do
      {:ok, summary} ->
        count = Map.get(summary, :count, 0)

        {:ok,
         %{
           kind: :reconcile,
           repaired: count,
           alerts: 0,
           continue?: count >= @reconcile_continue_after
         }}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp run(:retention, args) do
    now = DateTime.utc_now()
    batch_size = int_arg(args, "batch_size", Retention.batch_size())
    max_batches = int_arg(args, "max_batches", @retention_max_batches)

    {:ok, counts} = Retention.sweep(now, batch_size: batch_size, max_batches: max_batches)

    repaired =
      counts.receipts + counts.executions + counts.audit_events + counts.oauth_states +
        counts.sessions

    {:ok,
     %{
       kind: :retention,
       repaired: repaired,
       alerts: 0,
       continue?: Retention.more_due?(now)
     }}
  end

  defp run(:cleanup, args) do
    now = DateTime.utc_now()
    batch_size = int_arg(args, "batch_size", @cleanup_batch)
    {:ok, oauth} = OauthStates.delete_expired(before: now, batch_size: batch_size)
    {:ok, sessions} = Sessions.delete_unusable(now: now, batch_size: batch_size)
    {:ok, artifacts} = Export.cleanup_expired(now: now)

    {:ok,
     %{
       kind: :cleanup,
       repaired: oauth + sessions + artifacts,
       alerts: 0,
       continue?:
         (oauth == batch_size and OauthStates.expired?(before: now)) or
           (sessions == batch_size and Sessions.unusable?(now: now))
     }}
  end

  defp run(:integrity, args) do
    installation_id = args["installation_id"]
    batch_size = int_arg(args, "batch_size", @integrity_batch)
    now = DateTime.utc_now()

    with {:ok, reconcile} <- run(:reconcile, args) do
      bindings = disable_stale_bindings(installation_id, batch_size, now)
      schedules = disable_stale_schedules(installation_id, batch_size, now)
      purges = enqueue_due_purges(installation_id, batch_size, now)
      alerts = alert_orphan_secrets(installation_id, batch_size)

      repaired = reconcile.repaired + bindings + schedules + purges
      full? = bindings == batch_size or schedules == batch_size or purges == batch_size

      {:ok,
       %{
         kind: :integrity,
         repaired: repaired,
         alerts: alerts,
         continue?: reconcile.continue? or full?
       }}
    end
  end

  defp disable_stale_bindings(installation_id, batch_size, now) do
    ids_query =
      from(binding in stale_binding_query(installation_id),
        select: binding.id,
        order_by: [asc: binding.id],
        limit: ^batch_size
      )

    {count, _rows} =
      Repo.update_all(from(binding in TriggerBinding, where: binding.id in subquery(ids_query)),
        set: [enabled: false, updated_at: now]
      )

    count
  end

  defp disable_stale_schedules(installation_id, batch_size, now) do
    ids_query =
      from(schedule in stale_schedule_query(installation_id),
        select: schedule.id,
        order_by: [asc: schedule.id],
        limit: ^batch_size
      )

    {count, _rows} =
      Repo.update_all(from(schedule in Schedule, where: schedule.id in subquery(ids_query)),
        set: [enabled: false, updated_at: now]
      )

    count
  end

  defp stale_binding_query(installation_id) do
    query =
      from binding in TriggerBinding,
        join: version in WorkflowVersion,
        on:
          version.id == binding.workflow_version_id and
            version.installation_id == binding.installation_id,
        join: workflow in Workflow,
        on:
          workflow.id == version.workflow_id and
            workflow.installation_id == binding.installation_id,
        where: binding.enabled,
        where:
          workflow.status != "active" or is_nil(workflow.active_version_id) or
            workflow.active_version_id != binding.workflow_version_id

    scope_installation(query, installation_id, :binding)
  end

  defp stale_schedule_query(installation_id) do
    query =
      from schedule in Schedule,
        join: workflow in Workflow,
        on:
          workflow.id == schedule.workflow_id and
            workflow.installation_id == schedule.installation_id,
        where: schedule.enabled,
        where:
          workflow.status != "active" or is_nil(workflow.active_version_id) or
            workflow.active_version_id != schedule.workflow_version_id

    scope_installation(query, installation_id, :schedule)
  end

  defp enqueue_due_purges(installation_id, batch_size, now) do
    query =
      from installation in Installation,
        as: :install,
        where: installation.status == "uninstalled",
        where: not is_nil(installation.deletion_scheduled_at),
        where: installation.deletion_scheduled_at <= ^now,
        where:
          not exists(
            from job in Oban.Job,
              where: job.worker == ^@retention_worker,
              where: job.state in ^@incomplete_job_states,
              where:
                fragment("? ->> 'installation_id' = ?::text", job.args, parent_as(:install).id)
          ),
        select: installation.id,
        order_by: [asc: installation.id],
        limit: ^batch_size

    query =
      case installation_id do
        id when is_binary(id) -> from installation in query, where: installation.id == ^id
        _other -> query
      end

    Enum.reduce(Repo.all(query), 0, fn id, acc ->
      case Oban.insert(RetentionWorker.new(%{"installation_id" => id})) do
        {:ok, %Oban.Job{conflict?: true}} -> acc
        {:ok, %Oban.Job{}} -> acc + 1
        {:error, _reason} -> acc
      end
    end)
  end

  defp alert_orphan_secrets(installation_id, batch_size) do
    query =
      from version in WorkflowVersion,
        join: workflow in Workflow,
        on:
          workflow.active_version_id == version.id and
            workflow.installation_id == version.installation_id,
        where: workflow.status == "active",
        where: fragment("cardinality(?) > 0", version.referenced_secret_ids),
        select: {version.installation_id, version.id, version.referenced_secret_ids, workflow.id},
        limit: ^batch_size

    query =
      case installation_id do
        id when is_binary(id) ->
          from [version, workflow] in query, where: version.installation_id == ^id

        _other ->
          query
      end

    rows = Repo.all(query)

    ids =
      rows |> Enum.flat_map(fn {_inst, _vid, secret_ids, _wid} -> secret_ids end) |> Enum.uniq()

    existing =
      case ids do
        [] ->
          MapSet.new()

        ids ->
          Repo.all(
            from secret in Secret,
              where: secret.id in ^ids,
              select: {secret.installation_id, secret.id}
          )
          |> MapSet.new()
      end

    Enum.reduce(rows, 0, fn {inst_id, _version_id, secret_ids, workflow_id}, acc ->
      missing = Enum.count(secret_ids, fn id -> not MapSet.member?(existing, {inst_id, id}) end)

      if missing > 0 do
        emit_alert(inst_id, workflow_id, missing)
        acc + missing
      else
        acc
      end
    end)
  end

  defp emit_alert(installation_id, workflow_id, count) do
    :telemetry.execute(@telemetry_alert, %{count: count}, %{
      kind: "orphan_secret",
      status: "alert",
      outcome: "unsafe"
    })

    Logging.event(:warning, "health.check", %{
      operation: "maintenance.integrity",
      status: "alert",
      error_code: "orphan_secret",
      error_class: "conflict",
      event_type: "orphan_secret",
      installation_id: installation_id
    })

    _ =
      Writer.append_best_effort(
        Map.merge(Writer.actor({:job, "cleanup_worker"}), %{
          installation_id: installation_id,
          action: "admin.maintenance_alert",
          resource_type: "workflow",
          resource_id: workflow_id,
          metadata: %{
            reason: "orphan_secret",
            result: "alert",
            source: "integrity",
            count: count
          }
        })
      )

    :ok
  end

  defp audit_owner_run(%Scope{} = scope, kind, summary) do
    Multi.new()
    |> Service.as_multi()
    |> Writer.append(:audit, fn _changes ->
      Map.merge(Writer.actor(scope), %{
        installation_id: scope.installation_id,
        action: "admin.maintenance_run",
        resource_type: "installation",
        resource_id: scope.installation_id,
        metadata: %{
          result: "ok",
          source: Atom.to_string(kind),
          count: summary.repaired,
          target_kind: Atom.to_string(kind)
        }
      })
    end)
    |> Repo.transaction()
  end

  defp finish_tick(kind, {:ok, summary}) do
    emit_run(kind, summary, "ok")

    if summary.continue? do
      {:snooze, 1}
    else
      :ok
    end
  end

  defp finish_tick(kind, {:error, %Error{retryable?: true} = error}) do
    emit_run(kind, empty(kind), "error")
    {:error, error.code}
  end

  defp finish_tick(kind, {:error, %Error{}}) do
    emit_run(kind, empty(kind), "error")
    :ok
  end

  defp emit_run(kind, summary, status) do
    :telemetry.execute(
      @telemetry_run,
      %{count: 1, repaired: summary.repaired, alerts: summary.alerts},
      %{kind: Atom.to_string(kind), status: status, outcome: outcome_tag(summary)}
    )
  end

  defp outcome_tag(%{alerts: alerts}) when alerts > 0, do: "alert"
  defp outcome_tag(%{repaired: repaired}) when repaired > 0, do: "repaired"
  defp outcome_tag(_summary), do: "ok"

  defp empty(kind), do: %{kind: kind, repaired: 0, alerts: 0, continue?: false}

  defp paused_set do
    case Application.get_env(:pumble_automation, @pause_env, MapSet.new()) do
      %MapSet{} = set -> set
      _other -> MapSet.new()
    end
  end

  defp force?(args), do: args["force"] in [true, "true"]

  defp cast_kind(kind) when kind in @kinds, do: {:ok, kind}

  defp cast_kind(kind) when is_binary(kind) do
    case Enum.find(@kinds, &(Atom.to_string(&1) == kind)) do
      nil -> {:error, invalid_kind()}
      kind -> {:ok, kind}
    end
  end

  defp cast_kind(_kind), do: {:error, invalid_kind()}

  defp invalid_kind do
    Error.new(:validation, :invalid_maintenance_kind,
      message: "That maintenance job is not scheduled."
    )
  end

  defp stringify(opts) when is_list(opts), do: opts |> Map.new() |> stringify()

  defp stringify(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp int_arg(args, key, default) do
    case Map.get(args, key) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end

  defp scope_installation(query, id, :binding) when is_binary(id) do
    from [binding, _version, _workflow] in query, where: binding.installation_id == ^id
  end

  defp scope_installation(query, id, :schedule) when is_binary(id) do
    from [schedule, _workflow] in query, where: schedule.installation_id == ^id
  end

  defp scope_installation(query, _id, _kind), do: query
end
