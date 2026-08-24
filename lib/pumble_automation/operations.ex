defmodule PumbleAutomation.Operations do
  @moduledoc """
  Finite, tenant-scoped owner support operations.

  The names in `operations/0` are the whole catalogue. There is no SQL console,
  no eval, and no global super-admin. A job that is not provably safe to retry
  returns an instruction; it does not open a backdoor.

  Every mutation writes audit in the same transaction as the change. A read
  that exports diagnostics writes the export audit before the bundle is
  returned, so an unaccountable copy does not leave.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias PumbleAutomation.Audit.Writer
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Concurrency
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.StepAttempt
  alias PumbleAutomation.Executions.Workers.ReconciliationWorker
  alias PumbleAutomation.Executions.Workers.RetentionWorker
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Lifecycle
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Installations.Service
  alias PumbleAutomation.Limits
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Retention
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows.Workflow

  @operations [
    :requeue_safe_job,
    :run_reconciliation,
    :export_diagnostics,
    :initiate_tenant_deletion
  ]
  @capability :destructive_lifecycle
  @requeueable ~w(discarded cancelled retryable)
  @unsafe_message "This job cannot be retried automatically. Run reconciliation for missing work, or resolve a paused step. Do not repair jobs in SQL."

  @type operation ::
          :requeue_safe_job
          | :run_reconciliation
          | :export_diagnostics
          | :initiate_tenant_deletion

  @doc "The support operations this module will ever perform, sorted."
  @spec operations() :: [operation()]
  def operations, do: @operations

  @doc "Whether `name` is one of the finite support operations."
  @spec operation?(term()) :: boolean()
  def operation?(name), do: name in @operations

  @doc """
  Requeues one discarded, cancelled, or retryable job when that is provably safe.

  Safe means: the job names this tenant, the worker is an allowlisted repair
  target, no step attempt was opened for the job, and the job is not already
  available or executing. Anything else is an instruction, not a retry.
  """
  @spec requeue_safe_job(Scope.t(), term()) :: {:ok, Oban.Job.t()} | {:error, Error.t()}
  def requeue_safe_job(%Scope{} = scope, job_id) do
    with :ok <- Policy.authorize(scope, @capability),
         {:ok, id} <- parse_job_id(job_id) do
      Multi.new()
      |> Service.as_multi()
      |> Multi.run(:job, fn repo, _changes -> load_safe_job(repo, scope, id) end)
      |> Multi.run(:retried, fn repo, %{job: job} -> apply_retry(repo, job) end)
      |> Writer.append(:audit, fn %{job: job} -> requeue_audit(scope, job) end)
      |> Repo.transaction()
      |> finish_requeue()
    end
  end

  @doc """
  Runs tenant-scoped reconciliation for recoverable execution and job gaps.

  Delegates to `Engine.reconcile/1`, which already audits inside the repair
  transaction. Ambiguous effects still pause rather than retry.
  """
  @spec run_reconciliation(Scope.t()) :: {:ok, map()} | {:error, Error.t()}
  def run_reconciliation(%Scope{} = scope) do
    Engine.reconcile(scope)
  end

  @doc """
  Builds a bounded, allowlisted diagnostic map for this tenant.

  The bundle names installation status, counts, queue states, limits, and
  retention policy. It never reads a secret value, a token, a session digest,
  or another tenant. The export is audited before the map is returned.
  """
  @spec export_diagnostics(Scope.t()) :: {:ok, map()} | {:error, Error.t()}
  def export_diagnostics(%Scope{} = scope) do
    with :ok <- Policy.authorize(scope, @capability),
         {:ok, installation} <- fetch_installation(scope),
         bundle <- build_bundle(scope, installation) do
      persist_export_audit(scope, installation, bundle)
    end
  end

  @doc """
  Starts the uninstalled grace window and schedules tenant purge.

  This is the owner path. It uses `Lifecycle.uninstall/2`, which removes
  credentials immediately, audits in the same transaction, and enqueues
  retention. An already-uninstalled tenant is returned unchanged. A deleted
  tenant is a conflict.
  """
  @spec initiate_tenant_deletion(Scope.t()) ::
          {:ok, %{installation: Installation.t(), scheduled_at: DateTime.t() | nil}}
          | {:error, Error.t()}
  def initiate_tenant_deletion(%Scope{} = scope) do
    with :ok <- Policy.authorize(scope, @capability),
         {:ok, installation} <- fetch_installation(scope),
         :ok <- deletion_allowed(installation) do
      finish_deletion(
        Lifecycle.uninstall(scope.installation_id,
          actor_type: "user",
          actor_id: scope.member_id,
          reason: "owner_requested"
        )
      )
    end
  end

  defp load_safe_job(repo, %Scope{} = scope, id) do
    query = from job in Oban.Job, where: job.id == ^id, lock: "FOR UPDATE"

    case repo.one(query) do
      nil ->
        {:error, Policy.not_found()}

      %Oban.Job{} = job ->
        classify_job(repo, scope, job)
    end
  end

  defp classify_job(repo, %Scope{} = scope, %Oban.Job{} = job) do
    cond do
      job_installation_id(job) != scope.installation_id ->
        refuse_foreign(job, scope)

      job.worker not in safe_workers() ->
        {:error, unsafe_repair()}

      job.state not in @requeueable ->
        {:error,
         Error.new(:conflict, :job_not_requeueable,
           message: "That job is already queued or running."
         )}

      attempt_exists?(repo, scope.installation_id, job.id) ->
        {:error, unsafe_repair()}

      true ->
        {:ok, job}
    end
  end

  defp refuse_foreign(%Oban.Job{} = job, %Scope{} = scope) do
    if job_installation_id(job) do
      Scope.record_mismatch(:operations)
    end

    _ = scope
    {:error, Policy.not_found()}
  end

  defp apply_retry(repo, %Oban.Job{} = job) do
    now = DateTime.utc_now()
    max_attempts = max(job.max_attempts, job.attempt + 1)

    {count, _} =
      repo.update_all(
        from(j in Oban.Job, where: j.id == ^job.id, where: j.state in ^@requeueable),
        set: [
          state: "available",
          max_attempts: max_attempts,
          scheduled_at: now,
          completed_at: nil,
          cancelled_at: nil,
          discarded_at: nil
        ]
      )

    if count == 1 do
      {:ok, repo.get!(Oban.Job, job.id)}
    else
      {:error,
       Error.new(:conflict, :job_not_requeueable,
         message: "That job is already queued or running."
       )}
    end
  end

  defp requeue_audit(%Scope{} = scope, %Oban.Job{} = job) do
    Map.merge(Writer.actor(scope), %{
      installation_id: scope.installation_id,
      action: "admin.job_requeued",
      resource_type: "oban_job",
      resource_id: Integer.to_string(job.id),
      metadata: %{
        "actor_role" => scope.role,
        "result" => "ok",
        "source" => "support",
        "previous_state" => job.state,
        "next_state" => "available",
        "target_kind" => job.worker
      }
    })
  end

  defp finish_requeue({:ok, %{retried: job}}), do: {:ok, job}
  defp finish_requeue({:error, _step, %Error{} = error, _changes}), do: {:error, error}

  defp finish_requeue({:error, :audit, %Ecto.Changeset{}, _changes}) do
    {:error,
     Error.new(:internal, :audit_append_failed,
       message: "The support action could not be audited."
     )}
  end

  defp finish_requeue({:error, _step, _reason, _changes}) do
    {:error, Error.new(:internal, :requeue_failed, message: "The job could not be requeued.")}
  end

  defp persist_export_audit(%Scope{} = scope, %Installation{} = installation, bundle) do
    attrs =
      Map.merge(Writer.actor(scope), %{
        installation_id: scope.installation_id,
        action: "admin.diagnostics_exported",
        resource_type: "installation",
        resource_id: installation.id,
        metadata: %{
          "actor_role" => scope.role,
          "result" => "ok",
          "source" => "support",
          "count" => map_size(bundle)
        }
      })

    case Multi.new()
         |> Service.as_multi()
         |> Writer.append(:audit, attrs)
         |> Repo.transaction() do
      {:ok, _changes} ->
        {:ok, bundle}

      {:error, _step, _reason, _changes} ->
        {:error,
         Error.new(:internal, :audit_append_failed,
           message: "The support action could not be audited."
         )}
    end
  end

  defp build_bundle(%Scope{} = scope, %Installation{} = installation) do
    %{
      "schema_version" => 1,
      "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "application" => %{
        "name" => "pumble_automation",
        "version" => application_version()
      },
      "installation" => %{
        "id" => installation.id,
        "status" => installation.status,
        "workspace_id" => installation.pumble_workspace_id,
        "bot_scopes" => installation.bot_scopes || [],
        "user_scopes" => installation.user_scopes || [],
        "deletion_scheduled_at" => encode_time(installation.deletion_scheduled_at)
      },
      "workflows" => workflow_counts(scope.installation_id),
      "executions" => execution_counts(scope.installation_id),
      "jobs" => job_counts(scope.installation_id),
      "retention" => retention_snapshot(scope.installation_id),
      "limits" => limit_snapshot()
    }
    |> Error.sanitize()
  end

  defp workflow_counts(installation_id) do
    %{
      "total" =>
        Repo.aggregate(from(w in Workflow, where: w.installation_id == ^installation_id), :count),
      "active" =>
        Repo.aggregate(
          from(w in Workflow,
            where: w.installation_id == ^installation_id,
            where: not is_nil(w.active_version_id)
          ),
          :count
        )
    }
  end

  defp execution_counts(installation_id) do
    rows =
      Repo.all(
        from e in Execution,
          where: e.installation_id == ^installation_id,
          group_by: e.status,
          select: {e.status, count(e.id)}
      )

    Execution.statuses()
    |> Map.new(&{&1, 0})
    |> Map.merge(Map.new(rows))
  end

  defp job_counts(installation_id) do
    rows =
      Repo.all(
        from j in Oban.Job,
          where: fragment("? ->> 'installation_id' = ?", j.args, ^installation_id),
          group_by: j.state,
          select: {j.state, count(j.id)}
      )

    Map.new(rows)
  end

  defp retention_snapshot(installation_id) do
    status = Retention.status()

    %{
      "policy" => status.policy,
      "last_run_at" => encode_time(status.last_run_at),
      "last_kind" => status.last_kind && Atom.to_string(status.last_kind),
      "last_counts" => status.last_counts,
      "applies_to_this_tenant" => status.last_installation_id == installation_id
    }
  end

  defp limit_snapshot do
    Map.new(Limits.keys(), fn key -> {Atom.to_string(key), Limits.get(key)} end)
  end

  defp application_version do
    case Application.spec(:pumble_automation, :vsn) do
      value when is_list(value) -> List.to_string(value)
      value when is_binary(value) -> value
      _other -> "0.1.0"
    end
  end

  defp fetch_installation(%Scope{installation_id: installation_id}) do
    case Repo.get(Installation, installation_id) do
      %Installation{} = installation -> {:ok, installation}
      nil -> {:error, Policy.not_found()}
    end
  end

  defp deletion_allowed(%Installation{status: "deleted"}) do
    {:error,
     Error.new(:conflict, :already_deleted, message: "This workspace has already been deleted.")}
  end

  defp deletion_allowed(%Installation{}), do: :ok

  defp finish_deletion({:ok, %Installation{} = installation}) do
    {:ok, %{installation: installation, scheduled_at: installation.deletion_scheduled_at}}
  end

  defp finish_deletion({:error, %Error{} = error}), do: {:error, error}

  defp parse_job_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp parse_job_id(id) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {value, ""} when value > 0 -> {:ok, value}
      _other -> {:error, Policy.not_found()}
    end
  end

  defp parse_job_id(_id), do: {:error, Policy.not_found()}

  defp job_installation_id(%Oban.Job{args: args}) when is_map(args) do
    case Map.get(args, "installation_id") || Map.get(args, :installation_id) do
      id when is_binary(id) -> id
      _other -> nil
    end
  end

  defp attempt_exists?(repo, installation_id, job_id) do
    repo.exists?(
      from attempt in StepAttempt,
        where: attempt.installation_id == ^installation_id,
        where: attempt.oban_job_id == ^job_id
    )
  end

  defp safe_workers do
    [
      Concurrency.advance_worker(),
      Concurrency.approval_timeout_worker(),
      Concurrency.approval_delivery_worker(),
      Oban.Worker.to_string(ReconciliationWorker),
      Oban.Worker.to_string(RetentionWorker)
    ]
  end

  defp unsafe_repair do
    Error.new(:validation, :unsafe_repair, message: @unsafe_message)
  end

  defp encode_time(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp encode_time(_time), do: nil
end
