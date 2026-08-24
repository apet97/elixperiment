defmodule PumbleAutomation.Executions.Engine do
  @moduledoc """
  The durable start, claim, and finalize primitives of an execution.

  Ingress, schedules, and the UI start a run by calling `create/2`. That call
  is one `Ecto.Multi`: the queued execution, its first step, and the Oban
  advance job either all exist or none of them do. Duplicate source keys
  collapse onto the row the unique index already kept.

  `claim/1` is the matching short transaction a worker opens before it
  evaluates anything. It locks the execution and the current step, checks the
  job's expected node and generation, and either returns a bounded snapshot
  or a no-op. External I/O happens after this function returns, never while
  the row locks are held.

  `finalize/2` is the other half of that window: it locks the same rows,
  requires the claim's attempt and generation, writes the runner outcome, and
  inserts the next durable job in the same transaction. A stale or duplicate
  finalizer is a no-op. Retryable outcomes go through
  `PumbleAutomation.Executions.RetryPolicy` so backoff, exhaustion, and
  uncertain pauses are engine-owned rather than Oban-owned.

  `resolve_uncertain/4` is the owner-only path that leaves `paused_uncertain`.

  `cancel/3` records a durable request. Waiting, queued, and paused rows
  stop immediately. A running external call is not revoked; finalize
  observes the request and does not start the next step. `cancel_all/2` is
  the owner-only in-flight stop. Per-workspace occupancy is five occupying
  rows; excess creates stay queued until a slot frees, oldest first.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias PumbleAutomation.Audit.Writer
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Approval
  alias PumbleAutomation.Executions.ApprovalService
  alias PumbleAutomation.Executions.Concurrency
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Lineage
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Executions.RetryPolicy
  alias PumbleAutomation.Executions.StateMachine
  alias PumbleAutomation.Executions.StepAttempt
  alias PumbleAutomation.Executions.StepExecution
  alias PumbleAutomation.Executions.Uncertainty
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.Executions.Workers.ApprovalDeliveryWorker
  alias PumbleAutomation.Executions.Workers.ApprovalTimeoutWorker
  alias PumbleAutomation.FailureInjection
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Installations.Service
  alias PumbleAutomation.Limits
  alias PumbleAutomation.Logging
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows.CompiledWorkflow
  alias PumbleAutomation.Workflows.TriggerBinding
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomation.Workflows.WorkflowVersion

  @reconcile_batch 100

  @run_modes ~w(live dry_run)
  @lock_timeout "3s"
  @telemetry_event [:pumble_automation, :executions]

  @type snapshot :: %{
          installation_id: Ecto.UUID.t(),
          execution_id: Ecto.UUID.t(),
          workflow_id: Ecto.UUID.t(),
          workflow_version_id: Ecto.UUID.t(),
          node_id: String.t(),
          node_type: String.t(),
          compiled_node: CompiledWorkflow.compiled_node(),
          context: map(),
          trigger_snapshot: map(),
          run_mode: String.t(),
          effect_key: String.t(),
          attempt_id: Ecto.UUID.t(),
          attempt_number: pos_integer(),
          generation: non_neg_integer(),
          step_execution_id: Ecto.UUID.t(),
          delay_resume?: boolean(),
          started_at: DateTime.t()
        }

  @doc """
  Creates a queued execution, its first step, and an advance job together.

  `attrs` must name `:workflow_version_id` and `:execution_key`. Optional:
  `:trigger_snapshot`, `:received_event_id`, `:parent_execution_id`,
  `:root_execution_id`, `:lineage_depth`, `:lineage_source`, and `:run_mode`
  (`"live"` or `"dry_run"`). Pumble events must pass `:lineage_source`
  `:pumble_event` so payload-supplied parents cannot be forged. Internal
  derived runs pass `:parent_execution_id` from a row this process already
  loaded.

  The first argument is a member `Scope` or the installation id. Ingress has
  no browser session, so it passes the tenant id the callback already
  resolved. The version must belong to that tenant and be the workflow's live
  version. The installation and workflow must both be `active`. A second call
  with the same key returns the existing execution rather than inserting
  another.
  """
  @spec create(Scope.t() | Ecto.UUID.t(), map()) :: {:ok, Execution.t()} | {:error, Error.t()}
  def create(%Scope{installation_id: installation_id}, attrs) when is_map(attrs) do
    create(installation_id, attrs)
  end

  def create(installation_id, attrs) when is_binary(installation_id) and is_map(attrs) do
    with {:ok, request} <- parse_create(installation_id, attrs) do
      request
      |> create_multi()
      |> transact()
      |> finish_create(request)
    end
  end

  @doc """
  Claims the current runnable step for one worker attempt.

  Accepts an `Oban.Job` or its args map. On success the execution and step
  are `running`, one attempt row exists, and `generation` has advanced. A
  due `waiting_delay` job is claimed as a resume: the snapshot carries
  `:delay_resume?` so the worker continues without waiting twice. An early
  delay job returns `{:ok, {:snooze, seconds}}` and leaves the wait in
  place. A duplicate, stale, cancelled, waiting-approval, completed, or
  uninstalled job returns `{:ok, :noop}` so Oban does not retry it forever.
  A lock timeout is a retryable error.
  """
  @spec claim(Oban.Job.t() | map()) ::
          {:ok, snapshot()}
          | {:ok, :noop}
          | {:ok, {:snooze, pos_integer()}}
          | {:error, Error.t()}
  def claim(%Oban.Job{args: args, id: id}), do: claim(args, id)
  def claim(args) when is_map(args), do: claim(args, nil)

  @doc "Telemetry prefix for execution, step, retry, uncertainty, and reconcile events."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  @doc """
  Persists a runner outcome and enqueues the next durable job together.

  `snapshot` is the map `claim/1` returned. The current attempt id and
  generation must still match. On success the attempt, step, execution, and
  optional next step/job either all exist or none of them do. A stale attempt,
  a duplicate call, or a terminal row returns `{:ok, :noop}`.
  """
  @spec finalize(snapshot(), Outcome.t()) ::
          {:ok, Execution.t()} | {:ok, :noop} | {:error, Error.t()}
  def finalize(snapshot, %Outcome{} = outcome) when is_map(snapshot) do
    FailureInjection.crash(:before_finalize)

    snapshot
    |> finalize_multi(outcome)
    |> transact()
    |> finish_finalize()
  end

  @doc """
  Resolves a `paused_uncertain` execution as the scope's owner.

  `choice` is `:succeeded`, `:failed`, or `:retry`. Retry requires
  `acknowledge_duplicate_risk: true`. Succeeded may carry sanitized
  `:evidence`. A second identical choice is an idempotent stay. A different
  choice after resolution is a conflict. Uninstall refuses any path that
  would dispatch a new effect.
  """
  @spec resolve_uncertain(Scope.t(), Ecto.UUID.t(), term(), map()) ::
          {:ok, Execution.t()} | {:error, Error.t()}
  def resolve_uncertain(%Scope{} = scope, execution_id, choice, attrs \\ %{})
      when is_binary(execution_id) and is_map(attrs) do
    with {:ok, request} <- Uncertainty.parse(choice, attrs) do
      scope
      |> resolve_multi(execution_id, request)
      |> transact()
      |> finish_resolve()
    end
  end

  @doc """
  Requests cancellation of one execution.

  Editors and owners may call this. Waiting, queued, and paused rows become
  `cancelled` immediately, including a pending approval. A running row keeps
  its status until the in-flight attempt finalizes, which then halts.
  Duplicate cancel of an already-cancelled row is an idempotent stay.
  """
  @spec cancel(Scope.t(), Ecto.UUID.t(), map()) :: {:ok, Execution.t()} | {:error, Error.t()}
  def cancel(%Scope{} = scope, execution_id, attrs \\ %{})
      when is_binary(execution_id) and is_map(attrs) do
    scope
    |> cancel_multi(execution_id, attrs)
    |> transact()
    |> finish_cancel()
  end

  @doc """
  Cancels every non-terminal execution in the tenant, optionally one workflow.

  Owner-only. Running rows receive the durable request; every other
  in-flight row stops immediately. Freed slots wake the oldest remaining
  queued executions of other workflows when a workflow filter is set.
  """
  @spec cancel_all(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def cancel_all(%Scope{} = scope, attrs \\ %{}) when is_map(attrs) do
    scope
    |> cancel_all_multi(attrs)
    |> transact()
    |> finish_cancel_all()
  end

  @doc """
  Repairs a bounded batch of recoverable execution and job gaps.

  A scope runs the tenant-scoped owner path. A job args map may name
  `:installation_id`; omitting it scans every tenant up to the batch limit.
  Duplicate calls are a no-op once the gaps are gone. Uninstall refuses
  resume and cancels leftover in-flight rows instead.
  """
  @spec reconcile(Scope.t() | map()) :: {:ok, map()} | {:error, Error.t()}
  def reconcile(%Scope{} = scope) do
    with :ok <- Policy.authorize(scope, :destructive_lifecycle) do
      %{"installation_id" => scope.installation_id, "actor" => scope}
      |> reconcile_multi()
      |> transact()
      |> finish_reconcile()
    end
  end

  def reconcile(args) when is_map(args) do
    args
    |> stringify_keys()
    |> reconcile_multi()
    |> transact()
    |> finish_reconcile()
  end

  defp claim(args, oban_job_id) do
    with {:ok, ids} <- parse_claim(args) do
      ids
      |> claim_multi(oban_job_id)
      |> transact()
      |> finish_claim()
    end
  end

  ## Create

  defp create_multi(request) do
    Multi.new()
    |> Service.as_multi()
    |> Multi.run(:installation, fn repo, _changes ->
      lock_installation(repo, request.installation_id)
    end)
    |> Multi.run(:version, fn repo, _changes ->
      load_version(repo, request.installation_id, request.workflow_version_id)
    end)
    |> Multi.run(:workflow, fn repo, changes ->
      lock_live_workflow(repo, request.installation_id, changes)
    end)
    |> Multi.run(:binding, fn repo, changes ->
      require_binding(repo, request.installation_id, changes.version.id)
    end)
    |> Multi.run(:compiled, fn _repo, changes -> decode_compiled(changes.version) end)
    |> Multi.run(:lineage, fn repo, %{version: version} ->
      Lineage.admit(repo, request, version)
    end)
    |> Multi.run(:execution, fn repo, changes -> insert_execution(repo, request, changes) end)
    |> Multi.run(:queued_quota, fn repo, %{execution: execution} ->
      require_queued_quota(repo, execution)
    end)
    |> Multi.run(:step, fn repo, changes -> insert_first_step(repo, changes) end)
    |> Multi.run(:admissions, fn repo, _changes ->
      {:ok, Concurrency.admissions(repo, request.installation_id)}
    end)
    |> Multi.merge(&enqueue_admissions/1)
  end

  defp parse_create(installation_id, attrs) do
    with {:ok, execution_key} <- required_key(attrs),
         {:ok, workflow_version_id} <- required_uuid(attrs, :workflow_version_id),
         {:ok, run_mode} <- parse_run_mode(attrs),
         {:ok, trigger_snapshot} <- parse_map(attrs, :trigger_snapshot),
         {:ok, received_event_id} <- optional_uuid(attrs, :received_event_id),
         {:ok, parent_execution_id} <- optional_uuid(attrs, :parent_execution_id),
         {:ok, root_execution_id} <- optional_uuid(attrs, :root_execution_id),
         {:ok, lineage_source} <- parse_lineage_source(attrs),
         {:ok, lineage_depth} <- parse_lineage(attrs, root_execution_id, parent_execution_id) do
      {:ok,
       %{
         installation_id: installation_id,
         workflow_version_id: workflow_version_id,
         execution_key: execution_key,
         run_mode: run_mode,
         trigger_snapshot: trigger_snapshot,
         received_event_id: received_event_id,
         parent_execution_id: parent_execution_id,
         root_execution_id: root_execution_id,
         lineage_depth: lineage_depth,
         lineage_source: lineage_source
       }}
    end
  end

  defp required_key(attrs) do
    case attr(attrs, :execution_key) do
      key when is_binary(key) and byte_size(key) > 0 ->
        {:ok, key}

      _other ->
        {:error,
         Error.new(:validation, :invalid_execution, message: "An execution key is required.")}
    end
  end

  defp parse_run_mode(attrs) do
    case attr(attrs, :run_mode) || "live" do
      mode when mode in @run_modes ->
        {:ok, mode}

      _other ->
        {:error,
         Error.new(:validation, :invalid_run_mode, message: "Run mode must be live or dry_run.")}
    end
  end

  defp parse_map(attrs, field) do
    case attr(attrs, field) do
      nil -> {:ok, %{}}
      map when is_map(map) and not is_struct(map) -> {:ok, map}
      _other -> {:error, invalid_execution("The #{field} must be an object.")}
    end
  end

  defp parse_lineage_source(attrs) do
    case attr(attrs, :lineage_source) do
      nil -> {:ok, :internal}
      :internal -> {:ok, :internal}
      :webhook -> {:ok, :webhook}
      :pumble_event -> {:ok, :pumble_event}
      "internal" -> {:ok, :internal}
      "webhook" -> {:ok, :webhook}
      "pumble_event" -> {:ok, :pumble_event}
      _other -> {:error, invalid_execution("Lineage source is not recognized.")}
    end
  end

  defp parse_lineage(attrs, root_execution_id, parent_execution_id) do
    depth = attr(attrs, :lineage_depth) || 0

    with :ok <- validate_depth_value(depth),
         :ok <- validate_depth_ceiling(depth),
         :ok <- validate_lineage_pair(depth, root_execution_id, parent_execution_id) do
      {:ok, depth}
    end
  end

  defp validate_depth_value(depth) when is_integer(depth) and depth >= 0, do: :ok

  defp validate_depth_value(_depth) do
    {:error, invalid_execution("Lineage depth must be a non-negative integer.")}
  end

  defp validate_depth_ceiling(depth) do
    if depth > Execution.max_lineage_depth() do
      {:error,
       Error.new(:validation, :lineage_depth_exceeded,
         message: "This run cannot start because it would exceed the lineage depth limit."
       )}
    else
      :ok
    end
  end

  defp validate_lineage_pair(_depth, _root, parent) when is_binary(parent), do: :ok
  defp validate_lineage_pair(0, nil, _parent), do: :ok
  defp validate_lineage_pair(depth, root, _parent) when depth > 0 and not is_nil(root), do: :ok

  defp validate_lineage_pair(0, _root, _parent) do
    {:error, invalid_execution("A root execution cannot name a parent run.")}
  end

  defp validate_lineage_pair(_depth, nil, _parent) do
    {:error, invalid_execution("A derived execution must name its root run.")}
  end

  defp lock_installation(repo, installation_id) do
    query =
      from installation in Installation,
        where: installation.id == ^installation_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      %Installation{status: "active"} = installation ->
        {:ok, installation}

      %Installation{} ->
        {:error,
         Error.new(:permission, :installation_revoked,
           message: "This workspace's authorization is no longer valid."
         )}

      nil ->
        {:error, Policy.not_found()}
    end
  end

  defp load_version(repo, installation_id, version_id) do
    query =
      from version in WorkflowVersion,
        where: version.id == ^version_id and version.installation_id == ^installation_id

    case repo.one(query) do
      %WorkflowVersion{} = version -> {:ok, version}
      nil -> Scope.refuse_unknown(WorkflowVersion, version_id, installation_id, :engine)
    end
  end

  defp lock_live_workflow(repo, installation_id, %{
         version: version,
         installation: installation
       }) do
    query =
      from workflow in Workflow,
        where:
          workflow.id == ^version.workflow_id and workflow.installation_id == ^installation_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      %Workflow{} = workflow ->
        admit_workflow(workflow, installation, version)

      nil ->
        {:error, Policy.not_found()}
    end
  end

  defp admit_workflow(
         %Workflow{} = workflow,
         %Installation{} = installation,
         %WorkflowVersion{} = version
       ) do
    cond do
      not StateMachine.admit_new_execution?(workflow.status, installation.status) ->
        {:error,
         Error.new(:conflict, :not_active,
           message: "That workflow is not running.",
           details: %{workflow_id: workflow.id}
         )}

      workflow.active_version_id != version.id ->
        {:error,
         Error.new(:conflict, :version_mismatch,
           message: "That workflow version is not the live program.",
           details: %{workflow_id: workflow.id}
         )}

      true ->
        {:ok, workflow}
    end
  end

  defp require_binding(repo, installation_id, version_id) do
    query =
      from binding in TriggerBinding,
        where:
          binding.installation_id == ^installation_id and
            binding.workflow_version_id == ^version_id and
            binding.enabled,
        limit: 1

    case repo.one(query) do
      %TriggerBinding{} = binding ->
        {:ok, binding}

      nil ->
        {:error, Error.new(:conflict, :not_active, message: "That workflow is not running.")}
    end
  end

  defp decode_compiled(%WorkflowVersion{compiled_definition: document}) do
    CompiledWorkflow.decode(document)
  end

  defp insert_execution(repo, request, %{
         version: version,
         compiled: compiled,
         lineage: lineage
       }) do
    id = Ecto.UUID.generate()

    attrs = %{
      installation_id: request.installation_id,
      workflow_id: version.workflow_id,
      workflow_version_id: version.id,
      received_event_id: request.received_event_id,
      execution_key: request.execution_key,
      status: "queued",
      current_node_id: compiled.entry_node_id,
      context: %{"execution" => %{"id" => id, "run_mode" => request.run_mode}},
      trigger_snapshot: request.trigger_snapshot,
      root_execution_id: lineage.root_execution_id,
      lineage_depth: lineage.lineage_depth,
      lock_version: 0
    }

    %Execution{id: id}
    |> Execution.changeset(attrs)
    |> repo.insert()
    |> case do
      {:ok, execution} -> {:ok, execution}
      {:error, changeset} -> {:error, execution_insert_error(changeset, request.execution_key)}
    end
  end

  defp require_queued_quota(repo, %Execution{} = execution) do
    limit = Limits.get(:queued_executions)

    count =
      repo.aggregate(
        from(row in Execution,
          where: row.installation_id == ^execution.installation_id and row.status == "queued"
        ),
        :count
      )

    if count > limit do
      Limits.record_hit(:queued_executions, execution.installation_id)

      {:error,
       Error.new(:validation, :queued_executions_limit,
         retryable?: true,
         message: "This workspace has too many queued executions."
       )}
    else
      {:ok, count}
    end
  end

  defp insert_first_step(repo, %{execution: execution, compiled: compiled}) do
    insert_step_row(repo, execution, compiled)
  end

  defp insert_step_row(repo, %Execution{} = execution, %CompiledWorkflow{} = compiled) do
    case Map.fetch(compiled.nodes, execution.current_node_id) do
      {:ok, node} ->
        %StepExecution{}
        |> StepExecution.changeset(%{
          installation_id: execution.installation_id,
          execution_id: execution.id,
          node_id: execution.current_node_id,
          node_type: Atom.to_string(node.type),
          status: "queued"
        })
        |> repo.insert()
        |> case do
          {:ok, step} -> {:ok, step}
          {:error, changeset} -> {:error, step_insert_error(changeset)}
        end

      :error ->
        {:error,
         Error.new(:internal, :missing_entry_node,
           message: "The compiled workflow does not name an entry step."
         )}
    end
  end

  defp execution_insert_error(%Ecto.Changeset{} = changeset, execution_key) do
    if violated?(changeset, "executions_installation_id_execution_key_index") do
      {:duplicate, execution_key}
    else
      invalid_execution("The execution could not be stored.", changeset)
    end
  end

  defp step_insert_error(%Ecto.Changeset{} = changeset) do
    if violated?(changeset, "step_executions_execution_id_node_id_index") do
      Error.new(:conflict, :step_already_open, message: "That step is already open on this run.")
    else
      Error.new(:validation, :invalid_step,
        message: "The step could not be stored.",
        details: %{fields: Enum.map(changeset.errors, fn {field, _error} -> field end)}
      )
    end
  end

  defp finish_create({:ok, changes}, _request) do
    emit_create(changes.execution)
    {:ok, changes.execution}
  end

  defp finish_create({:error, :execution, {:duplicate, key}, _changes}, request) do
    fetch_existing(request.installation_id, key)
  end

  defp finish_create({:error, :lock, %Error{} = error, _changes}, _request), do: {:error, error}

  defp finish_create({:error, _step, %Error{} = error, _changes}, _request), do: {:error, error}

  defp finish_create({:error, _step, %Ecto.Changeset{} = changeset, _changes}, _request) do
    {:error, invalid_execution("The execution could not be stored.", changeset)}
  end

  defp finish_create({:error, _step, _reason, _changes}, _request) do
    {:error,
     Error.new(:internal, :execution_write_failed, message: "The execution could not be stored.")}
  end

  defp fetch_existing(installation_id, execution_key) do
    query =
      from execution in Execution,
        where:
          execution.installation_id == ^installation_id and
            execution.execution_key == ^execution_key

    case Repo.one(query) do
      %Execution{} = execution ->
        {:ok, execution}

      nil ->
        {:error,
         Error.new(:conflict, :execution_key_taken,
           retryable?: true,
           message: "Another run with that key is already being created. Try again."
         )}
    end
  end

  ## Claim

  defp parse_claim(args) do
    with {:ok, installation_id} <- required_uuid(args, :installation_id),
         {:ok, execution_id} <- required_uuid(args, :execution_id),
         {:ok, expected_node_id} <- required_uuid(args, :expected_node_id),
         {:ok, generation} <- parse_generation(args) do
      {:ok,
       %{
         installation_id: installation_id,
         execution_id: execution_id,
         expected_node_id: expected_node_id,
         generation: generation
       }}
    end
  end

  defp parse_generation(args) do
    case attr(args, :generation) do
      generation when is_integer(generation) and generation >= 0 ->
        {:ok, generation}

      _other ->
        {:error,
         Error.new(:validation, :invalid_job, message: "The job does not name a generation.")}
    end
  end

  defp claim_multi(ids, oban_job_id) do
    Multi.new()
    |> Service.as_multi()
    |> Multi.run(:claimed, fn repo, _changes -> do_claim(repo, ids, oban_job_id) end)
  end

  defp do_claim(repo, ids, oban_job_id) do
    repo.query!("SELECT set_config('lock_timeout', $1, true)", [@lock_timeout])

    with {:ok, execution} <- lock_execution(repo, ids),
         :ok <- verify_claim(repo, execution, ids),
         {:ok, compiled} <- load_compiled(repo, execution),
         {:ok, step} <- ensure_step(repo, execution, compiled),
         :ok <- verify_step(execution, step) do
      FailureInjection.crash(:before_claim_commit)
      take_claim(repo, execution, step, compiled, oban_job_id)
    end
  end

  defp lock_execution(repo, %{installation_id: installation_id, execution_id: execution_id}) do
    query =
      from execution in Execution,
        where: execution.id == ^execution_id and execution.installation_id == ^installation_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      %Execution{} = execution ->
        {:ok, execution}

      nil ->
        Scope.record_if_foreign(Execution, execution_id, installation_id, :executions)
        {:error, :noop}
    end
  end

  defp verify_claim(repo, %Execution{} = execution, ids) do
    cond do
      not installation_active?(repo, execution.installation_id) ->
        {:error, :noop}

      cancelled?(execution) ->
        {:error, :noop}

      Execution.terminal?(execution.status) ->
        {:error, :noop}

      execution.status not in ["queued", "running", "waiting_delay"] ->
        {:error, :noop}

      execution.current_node_id != ids.expected_node_id ->
        {:error, :noop}

      execution.lock_version != ids.generation ->
        {:error, :noop}

      true ->
        :ok
    end
  end

  defp installation_active?(repo, installation_id) do
    query =
      from installation in Installation,
        where: installation.id == ^installation_id,
        select: installation.status

    repo.one(query) == "active"
  end

  defp cancelled?(%Execution{status: "cancelled"}), do: true
  defp cancelled?(%Execution{cancelled_at: %DateTime{}}), do: true
  defp cancelled?(%Execution{}), do: false

  defp load_compiled(repo, %Execution{} = execution) do
    query =
      from version in WorkflowVersion,
        where:
          version.id == ^execution.workflow_version_id and
            version.installation_id == ^execution.installation_id and
            version.workflow_id == ^execution.workflow_id

    case repo.one(query) do
      %WorkflowVersion{} = version -> decode_compiled(version)
      nil -> {:error, Policy.not_found()}
    end
  end

  defp ensure_step(repo, %Execution{} = execution, %CompiledWorkflow{} = compiled) do
    case lock_step(repo, execution) do
      %StepExecution{} = step -> {:ok, step}
      nil -> open_missing_step(repo, execution, compiled)
    end
  end

  defp open_missing_step(repo, execution, compiled) do
    case insert_step_row(repo, execution, compiled) do
      {:ok, step} -> {:ok, step}
      {:error, %Error{code: :step_already_open}} -> relock_step(repo, execution)
      {:error, reason} -> {:error, reason}
    end
  end

  defp relock_step(repo, execution) do
    case lock_step(repo, execution) do
      %StepExecution{} = step -> {:ok, step}
      nil -> {:error, :noop}
    end
  end

  defp lock_step(repo, %Execution{} = execution) do
    query =
      from step in StepExecution,
        where:
          step.execution_id == ^execution.id and
            step.installation_id == ^execution.installation_id and
            step.node_id == ^execution.current_node_id,
        lock: "FOR UPDATE"

    repo.one(query)
  end

  defp verify_step(%Execution{status: "waiting_delay"}, %StepExecution{status: "waiting_delay"}) do
    :ok
  end

  defp verify_step(%Execution{}, %StepExecution{status: status})
       when status in ["queued", "running"] do
    :ok
  end

  defp verify_step(_execution, %StepExecution{}), do: {:error, :noop}

  defp take_claim(
         repo,
         %Execution{status: "waiting_delay"} = execution,
         step,
         compiled,
         oban_job_id
       ) do
    resume_delay_claim(repo, execution, step, compiled, oban_job_id)
  end

  defp take_claim(repo, execution, step, compiled, oban_job_id) do
    start_claim(repo, execution, step, compiled, oban_job_id)
  end

  defp start_claim(repo, execution, step, compiled, oban_job_id) do
    with {:ok, _start} <- StateMachine.transition(:execution, execution.status, :start),
         {:ok, _step_start} <- StateMachine.transition(:step, step.status, :start),
         {:ok, attempt} <- open_attempt(step, oban_job_id),
         {:ok, step} <- mark_step_running(repo, step),
         {:ok, execution} <- mark_execution_running(repo, execution) do
      {:ok, snapshot(execution, step, attempt, compiled, false)}
    end
  end

  defp resume_delay_claim(repo, execution, step, compiled, oban_job_id) do
    now = DateTime.utc_now()

    with :ok <- delay_node?(compiled, execution),
         {:ok, _resume} <- StateMachine.transition(:execution, execution.status, :resume),
         {:ok, _step_resume} <- StateMachine.transition(:step, step.status, :resume),
         :ok <- due_resume(step, now),
         {:ok, attempt} <- open_attempt(step, oban_job_id),
         {:ok, step} <- mark_step_running(repo, step),
         {:ok, execution} <- mark_execution_running(repo, execution) do
      {:ok, snapshot(execution, step, attempt, compiled, true)}
    end
  end

  defp delay_node?(%CompiledWorkflow{} = compiled, %Execution{} = execution) do
    case Map.fetch(compiled.nodes, execution.current_node_id) do
      {:ok, %{type: :delay}} -> :ok
      _other -> {:error, :noop}
    end
  end

  defp due_resume(%StepExecution{} = step, %DateTime{} = now) do
    case stored_resume_at(step) do
      %DateTime{} = resume_at ->
        case DateTime.compare(now, resume_at) do
          :lt -> {:error, {:snooze, snooze_seconds(now, resume_at)}}
          _due -> :ok
        end

      nil ->
        :ok
    end
  end

  defp snooze_seconds(%DateTime{} = now, %DateTime{} = resume_at) do
    max(1, DateTime.diff(resume_at, now, :second))
  end

  defp stored_resume_at(%StepExecution{output: output}) when is_map(output) do
    parse_resume_at(Map.get(output, "resume_at"))
  end

  defp stored_resume_at(_step), do: nil

  defp parse_resume_at(%DateTime{} = datetime), do: datetime

  defp parse_resume_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _invalid -> nil
    end
  end

  defp parse_resume_at(_value), do: nil

  defp open_attempt(%StepExecution{} = step, oban_job_id) do
    attrs =
      if is_integer(oban_job_id) and oban_job_id > 0 do
        %{oban_job_id: oban_job_id}
      else
        %{}
      end

    StepAttempt.create(step, attrs)
  end

  defp mark_step_running(repo, %StepExecution{} = step) do
    step
    |> StepExecution.changeset(%{status: "running", attempt_count: step.attempt_count + 1})
    |> repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> {:error, step_insert_error(changeset)}
    end
  end

  defp mark_execution_running(repo, %Execution{} = execution) do
    execution
    |> Execution.changeset(%{
      status: "running",
      lock_version: execution.lock_version + 1
    })
    |> repo.update()
    |> case do
      {:ok, updated} ->
        {:ok, updated}

      {:error, changeset} ->
        {:error, invalid_execution("The execution could not be claimed.", changeset)}
    end
  end

  defp snapshot(execution, step, attempt, compiled, delay_resume?) do
    node = Map.fetch!(compiled.nodes, execution.current_node_id)
    run_mode = get_in(execution.context, ["execution", "run_mode"]) || "live"

    %{
      installation_id: execution.installation_id,
      execution_id: execution.id,
      workflow_id: execution.workflow_id,
      workflow_version_id: execution.workflow_version_id,
      node_id: execution.current_node_id,
      node_type: step.node_type,
      compiled_node: node,
      context: execution.context,
      trigger_snapshot: execution.trigger_snapshot,
      run_mode: run_mode,
      effect_key: step.effect_key,
      attempt_id: attempt.id,
      attempt_number: attempt.attempt_number,
      generation: execution.lock_version,
      step_execution_id: step.id,
      delay_resume?: delay_resume?,
      started_at: execution.inserted_at
    }
  end

  defp finish_claim({:ok, %{claimed: snapshot}}) do
    FailureInjection.crash(:after_claim)
    {:ok, snapshot}
  end

  defp finish_claim({:error, _step, :noop, _changes}), do: {:ok, :noop}

  defp finish_claim({:error, _step, {:snooze, seconds}, _changes})
       when is_integer(seconds) and seconds > 0 do
    {:ok, {:snooze, seconds}}
  end

  defp finish_claim({:error, :lock, %Error{} = error, _changes}), do: {:error, error}
  defp finish_claim({:error, _step, %Error{} = error, _changes}), do: {:error, error}

  defp finish_claim({:error, _step, _reason, _changes}) do
    {:error, Error.new(:internal, :claim_failed, message: "The step could not be claimed.")}
  end

  ## Finalize

  defp finalize_multi(snapshot, outcome) do
    Multi.new()
    |> Service.as_multi()
    |> Multi.run(:applied, fn repo, _changes -> do_finalize(repo, snapshot, outcome) end)
    |> Multi.merge(&enqueue_followup/1)
  end

  defp enqueue_admissions(%{admissions: admissions}) do
    enqueue_execution_jobs(admissions)
  end

  defp enqueue_followup(%{applied: :noop}) do
    empty_jobs()
  end

  defp enqueue_followup(%{applied: applied}) do
    applied
    |> Map.get(:job)
    |> followup_jobs(Map.get(applied, :wake, []))
    |> enqueue_job_specs()
    |> maybe_append_audit(Map.get(applied, :audit))
  end

  defp maybe_append_audit(multi, nil), do: multi

  defp maybe_append_audit(multi, attrs) when is_map(attrs) do
    Writer.append(multi, :audit, fn _changes -> attrs end)
  end

  defp followup_jobs(nil, wake), do: Enum.map(wake, &execution_job_spec/1)

  defp followup_jobs(specs, wake) when is_list(specs),
    do: specs ++ Enum.map(wake, &execution_job_spec/1)

  defp followup_jobs(spec, wake), do: [spec | Enum.map(wake, &execution_job_spec/1)]

  defp enqueue_execution_jobs([]), do: empty_jobs()

  defp enqueue_execution_jobs(executions) do
    executions
    |> Enum.map(&execution_job_spec/1)
    |> enqueue_job_specs()
  end

  defp empty_jobs do
    Multi.new()
    |> Service.as_multi()
    |> Multi.put(:job, nil)
  end

  defp enqueue_job_specs([]), do: empty_jobs()

  defp enqueue_job_specs([spec]) do
    FailureInjection.crash(:before_next_job_insert)

    Multi.new()
    |> Service.as_multi()
    |> PumbleAutomation.Oban.insert(:job, fn _changes -> next_job_changeset(spec) end)
  end

  defp enqueue_job_specs(specs) when is_list(specs) do
    FailureInjection.crash(:before_next_job_insert)

    specs
    |> Enum.with_index()
    |> Enum.reduce(Multi.new() |> Service.as_multi(), fn {spec, index}, multi ->
      PumbleAutomation.Oban.insert(multi, {:job, index}, fn _changes ->
        next_job_changeset(spec)
      end)
    end)
  end

  defp execution_job_spec(%Execution{} = execution) do
    immediate_job(execution, execution.current_node_id, execution.lock_version)
  end

  defp do_finalize(repo, snapshot, outcome) do
    repo.query!("SELECT set_config('lock_timeout', $1, true)", [@lock_timeout])

    with {:ok, execution} <- lock_execution(repo, snapshot),
         :ok <- verify_finalize(execution, snapshot),
         {:ok, compiled} <- load_compiled(repo, execution),
         {:ok, step} <- require_current_step(repo, execution),
         :ok <- verify_finalize_step(step, snapshot),
         {:ok, attempt} <- require_started_attempt(repo, snapshot, step),
         {:ok, bounded} <- persistable_outcome(outcome, snapshot),
         {:ok, plan, bounded, context} <- plan_finalize(execution, step, compiled, bounded),
         {:ok, plan, bounded} <- attach_approval(repo, execution, step, snapshot, bounded, plan),
         {:ok, attempt} <- finish_attempt(repo, attempt, bounded, plan, snapshot),
         {:ok, _step} <- finish_step(repo, step, bounded, plan),
         {:ok, execution} <- finish_execution(repo, execution, context, plan),
         {:ok, _next} <- insert_next_step(repo, execution, compiled, plan) do
      {:ok,
       %{
         execution: execution,
         job: plan.job,
         wake: wake_after(repo, execution),
         audit: Map.get(plan, :audit),
         telemetry: finalize_telemetry(snapshot, execution, attempt, bounded)
       }}
    end
  end

  defp verify_finalize(%Execution{} = execution, snapshot) do
    cond do
      Execution.terminal?(execution.status) -> {:error, :noop}
      execution.current_node_id != snapshot.node_id -> {:error, :noop}
      execution.lock_version != snapshot.generation -> {:error, :noop}
      execution.status != "running" -> {:error, :noop}
      true -> :ok
    end
  end

  defp require_current_step(repo, execution) do
    case lock_step(repo, execution) do
      %StepExecution{} = step -> {:ok, step}
      nil -> {:error, :noop}
    end
  end

  defp verify_finalize_step(%StepExecution{} = step, snapshot) do
    if step.id == snapshot.step_execution_id and step.status == "running" do
      :ok
    else
      {:error, :noop}
    end
  end

  defp require_started_attempt(repo, snapshot, %StepExecution{} = step) do
    query =
      from attempt in StepAttempt,
        where:
          attempt.id == ^snapshot.attempt_id and
            attempt.step_execution_id == ^step.id and
            attempt.installation_id == ^step.installation_id and
            attempt.status == "started"

    case repo.one(query) do
      %StepAttempt{} = attempt -> {:ok, attempt}
      nil -> {:error, :noop}
    end
  end

  defp persistable_outcome(%Outcome{} = outcome, snapshot) do
    case Outcome.bound(outcome, StepExecution.max_payload_bytes()) do
      {:ok, bounded} -> RetryPolicy.apply(bounded, snapshot)
      {:error, %Error{code: :output_too_large}} -> limit_outcome()
      {:error, _reason} = error -> error
    end
  end

  defp limit_outcome do
    Outcome.new(%{
      kind: :permanent_error,
      error_class: "resource_limit",
      message: "The step output is too large."
    })
  end

  defp plan_finalize(execution, step, compiled, outcome) do
    with {:ok, outcome, plan} <- build_plan(execution, compiled, outcome),
         {:ok, outcome, plan} <- apply_requested_cancel(execution, outcome, plan),
         {:ok, exec_plan} <-
           StateMachine.transition(:execution, execution.status, plan.execution_command),
         {:ok, step_plan} <-
           StateMachine.transition(:step, step.status, plan.step_command),
         {:ok, attempt_plan} <-
           StateMachine.transition(:attempt, "started", Outcome.attempt_command(outcome.kind)) do
      plan = %{
        plan
        | execution_to: exec_plan.to,
          step_to: step_plan.to,
          attempt_to: attempt_plan.to
      }

      merge_plan_context(execution, step, outcome, plan)
    end
  end

  defp apply_requested_cancel(%Execution{} = execution, outcome, plan) do
    if cancelled?(execution) and execution.status == "running" do
      {:ok, cancel_outcome(outcome),
       %{
         plan
         | execution_command: :cancel,
           step_command: :cancel,
           execution_to: "cancelled",
           step_to: "cancelled",
           current_node_id: execution.current_node_id,
           insert_next?: false,
           merge_output?: outcome.kind == :success,
           job: nil
       }}
    else
      {:ok, outcome, plan}
    end
  end

  defp cancel_outcome(%Outcome{kind: kind} = outcome) when kind in [:success, :uncertain] do
    outcome
  end

  defp cancel_outcome(%Outcome{} = outcome) do
    %{outcome | kind: :cancelled, resume_at: nil, error_class: outcome.error_class || "cancelled"}
  end

  defp merge_plan_context(execution, step, outcome, plan) do
    case merge_context(execution.context, step.node_id, outcome.output, plan.merge_output?) do
      {:ok, context} ->
        {:ok, plan, outcome, context}

      {:error, :context_overflow} ->
        {:ok, failed} = limit_outcome()
        {:ok, overflow_fail_plan(execution, failed), failed, execution.context}
    end
  end

  defp overflow_fail_plan(execution, outcome) do
    execution
    |> halt_plan("failed", :fail, outcome, nil)
    |> Map.put(:attempt_to, "failed")
  end

  defp build_plan(execution, compiled, %Outcome{kind: :success} = outcome) do
    node = Map.fetch!(compiled.nodes, execution.current_node_id)

    case Outcome.follow(node.edges, outcome.edge) do
      {:ok, :end} ->
        {:ok, outcome, halt_plan(execution, "completed", :complete, outcome, nil)}

      {:ok, {:continue, next_id}} ->
        {:ok, outcome, continue_plan(execution, next_id, outcome)}

      {:error, _reason} ->
        halt_from_mismatch(execution)
    end
  end

  defp build_plan(execution, compiled, %Outcome{kind: :wait_delay} = outcome) do
    expire_or_continue(execution, compiled, outcome, fn ->
      {:ok, outcome, wait_plan(execution, :wait_delay, "waiting_delay", outcome)}
    end)
  end

  defp build_plan(execution, compiled, %Outcome{kind: :wait_approval} = outcome) do
    expire_or_continue(execution, compiled, outcome, fn ->
      {:ok, outcome, wait_plan(execution, :wait_approval, "waiting_approval", outcome)}
    end)
  end

  defp build_plan(execution, compiled, %Outcome{kind: :retryable_error} = outcome) do
    expire_or_continue(execution, compiled, outcome, fn ->
      generation = execution.lock_version + 1

      {:ok, outcome,
       %{
         execution_command: :retry,
         step_command: :retry,
         execution_to: "running",
         step_to: "running",
         attempt_to: "failed",
         current_node_id: execution.current_node_id,
         insert_next?: false,
         merge_output?: false,
         selected_edge: outcome.edge,
         uncertainty_reason: nil,
         job: delayed_job(execution, execution.current_node_id, generation, outcome.resume_at)
       }}
    end)
  end

  defp build_plan(execution, _compiled, %Outcome{kind: :permanent_error} = outcome) do
    {:ok, outcome, halt_plan(execution, "failed", :fail, outcome, nil)}
  end

  defp build_plan(execution, _compiled, %Outcome{kind: :uncertain} = outcome) do
    {:ok, outcome,
     halt_plan(execution, "paused_uncertain", :pause_uncertain, outcome, outcome.message)}
  end

  defp build_plan(execution, _compiled, %Outcome{kind: :cancelled} = outcome) do
    {:ok, outcome, halt_plan(execution, "cancelled", :cancel, outcome, nil)}
  end

  defp halt_from_mismatch(execution) do
    {:ok, failed} =
      Outcome.new(%{
        kind: :permanent_error,
        error_class: "internal",
        message: "The compiled step does not name that outcome."
      })

    {:ok, failed, halt_plan(execution, "failed", :fail, failed, nil)}
  end

  defp halt_plan(execution, to, command, outcome, uncertainty_reason) do
    %{
      execution_command: command,
      step_command: command,
      execution_to: to,
      step_to: to,
      attempt_to: nil,
      current_node_id: execution.current_node_id,
      insert_next?: false,
      merge_output?: command == :complete,
      selected_edge: outcome.edge,
      uncertainty_reason: uncertainty_reason,
      job: nil
    }
  end

  defp continue_plan(execution, next_id, outcome) do
    generation = execution.lock_version + 1

    %{
      execution_command: :retry,
      step_command: :complete,
      execution_to: "running",
      step_to: "completed",
      attempt_to: nil,
      current_node_id: next_id,
      insert_next?: true,
      merge_output?: true,
      selected_edge: outcome.edge,
      uncertainty_reason: nil,
      job: immediate_job(execution, next_id, generation)
    }
  end

  defp expire_or_continue(execution, compiled, outcome, on_ok) do
    if wait_past_deadline?(execution, outcome) do
      Limits.record_hit(:execution_lifetime, execution.installation_id)
      build_plan(execution, compiled, lifetime_failure())
    else
      on_ok.()
    end
  end

  defp wait_past_deadline?(%Execution{inserted_at: %DateTime{} = started}, %Outcome{
         resume_at: %DateTime{} = resume_at
       }) do
    DateTime.compare(resume_at, Limits.deadline(started)) != :lt
  end

  defp wait_past_deadline?(_execution, _outcome), do: false

  defp lifetime_failure do
    {:ok, outcome} =
      Outcome.new(%{
        kind: :permanent_error,
        error_class: "resource_limit",
        message: "The execution exceeded its maximum lifetime."
      })

    outcome
  end

  defp wait_plan(execution, :wait_approval, to, outcome) do
    %{
      execution_command: :wait_approval,
      step_command: :wait_approval,
      execution_to: to,
      step_to: to,
      attempt_to: nil,
      current_node_id: execution.current_node_id,
      insert_next?: false,
      merge_output?: true,
      selected_edge: outcome.edge,
      uncertainty_reason: nil,
      job: nil
    }
  end

  defp wait_plan(execution, command, to, outcome) do
    generation = execution.lock_version + 1

    %{
      execution_command: command,
      step_command: command,
      execution_to: to,
      step_to: to,
      attempt_to: nil,
      current_node_id: execution.current_node_id,
      insert_next?: false,
      merge_output?: true,
      selected_edge: outcome.edge,
      uncertainty_reason: nil,
      job: delayed_job(execution, execution.current_node_id, generation, outcome.resume_at)
    }
  end

  defp merge_context(context, _node_id, _output, false), do: {:ok, context}

  defp merge_context(context, node_id, output, true) do
    steps = Map.get(context, "steps") || %{}

    if Map.has_key?(steps, node_id) do
      {:ok, context}
    else
      merged = Map.put(context, "steps", Map.put(steps, node_id, %{"output" => output}))

      if Execution.json_within?(merged, Execution.max_context_bytes()) and
           Execution.sanitized_map?(merged) do
        {:ok, merged}
      else
        {:error, :context_overflow}
      end
    end
  end

  defp finish_attempt(repo, %StepAttempt{} = attempt, outcome, plan, snapshot) do
    now = DateTime.utc_now()
    diagnostics = RetryPolicy.diagnostics(outcome, snapshot)

    set = [
      status: plan.attempt_to,
      ended_at: now,
      error_class: outcome.error_class,
      error_code: outcome.error_class,
      remote_status: remote_status(outcome.output),
      remote_request_id: outcome.remote_reference,
      retry_at: retry_at(outcome),
      duration_ms: duration_ms(attempt.started_at, now),
      diagnostics: diagnostics
    ]

    query =
      from a in StepAttempt,
        where: a.id == ^attempt.id and a.status == "started",
        select: a

    case repo.update_all(query, set: set) do
      {1, [row]} -> {:ok, row}
      {0, _rows} -> {:error, :noop}
    end
  end

  defp finish_step(repo, %StepExecution{} = step, outcome, plan) do
    attrs = %{
      status: plan.step_to,
      output: persist_step_output(outcome),
      selected_edge: plan.selected_edge,
      remote_reference: outcome.remote_reference,
      uncertainty_reason: plan.uncertainty_reason
    }

    step
    |> StepExecution.changeset(attrs)
    |> repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> {:error, step_insert_error(changeset)}
    end
  end

  defp persist_step_output(%Outcome{
         kind: :wait_delay,
         resume_at: %DateTime{} = resume_at,
         output: output
       }) do
    Map.put(output, "resume_at", DateTime.to_iso8601(resume_at))
  end

  defp persist_step_output(%Outcome{
         kind: :wait_approval,
         resume_at: %DateTime{} = resume_at,
         output: output
       }) do
    output
    |> Map.put("expires_at", DateTime.to_iso8601(resume_at))
    |> Map.delete("approver_member_ids")
  end

  defp persist_step_output(%Outcome{output: output}), do: output

  defp attach_approval(repo, execution, step, snapshot, outcome, plan) do
    if plan.execution_command == :wait_approval do
      case ApprovalService.insert_pending(repo, execution, step, snapshot, outcome) do
        {:ok, {:existing, approval}} ->
          {updated, next} = attach_existing_approval(repo, plan, approval, outcome)
          {:ok, updated, next}

        {:ok, approval} ->
          {updated, next} = attach_pending_approval(plan, execution, approval, outcome)
          {:ok, updated, next}

        {:error, :skip} ->
          {:ok, plan, outcome}

        {:error, %Error{} = error} ->
          fail_approval_wait(execution, error)
      end
    else
      {:ok, plan, outcome}
    end
  end

  defp attach_pending_approval(plan, execution, approval, outcome) do
    generation = execution.lock_version + 1

    jobs = [
      ApprovalTimeoutWorker.job_spec(approval, execution.current_node_id, generation),
      ApprovalDeliveryWorker.job_spec(approval)
    ]

    {plan
     |> Map.put(:job, jobs)
     |> Map.put(:audit, ApprovalService.request_audit(approval, execution)), outcome}
  end

  defp attach_existing_approval(repo, plan, approval, outcome) do
    jobs =
      if open_delivery_job?(repo, approval.id) do
        []
      else
        [ApprovalDeliveryWorker.job_spec(approval)]
      end

    {Map.put(plan, :job, jobs), outcome}
  end

  defp open_delivery_job?(repo, approval_id) do
    query =
      from job in Oban.Job,
        where: job.worker == ^Concurrency.approval_delivery_worker(),
        where: job.state in ^Concurrency.incomplete_job_states(),
        where: fragment("? ->> 'approval_id' = ?::text", job.args, ^approval_id)

    repo.exists?(query)
  end

  defp fail_approval_wait(execution, %Error{} = error) do
    {:ok, failed} =
      Outcome.new(%{
        kind: :permanent_error,
        error_class: Atom.to_string(error.class),
        message: error.message,
        output: fail_output(error)
      })

    {:ok, attempt_plan} = StateMachine.transition(:attempt, "started", :fail)

    {:ok, %{halt_plan(execution, "failed", :fail, failed, nil) | attempt_to: attempt_plan.to},
     failed}
  end

  defp fail_output(%Error{details: details}) do
    case Map.get(details, :field) || Map.get(details, "field") do
      field when is_binary(field) and field != "" -> %{"field" => field}
      _missing -> %{}
    end
  end

  defp finish_execution(repo, %Execution{} = execution, context, plan) do
    attrs = %{
      status: plan.execution_to,
      context: context,
      current_node_id: plan.current_node_id,
      lock_version: execution.lock_version + 1
    }

    execution
    |> Execution.changeset(attrs)
    |> repo.update()
    |> case do
      {:ok, updated} ->
        {:ok, updated}

      {:error, changeset} ->
        {:error, invalid_execution("The execution could not be finalized.", changeset)}
    end
  end

  defp insert_next_step(_repo, _execution, _compiled, %{insert_next?: false}), do: {:ok, nil}

  defp insert_next_step(repo, execution, compiled, %{insert_next?: true}) do
    insert_step_row(repo, execution, compiled)
  end

  defp immediate_job(execution, node_id, generation) do
    %{
      args: job_args(execution, node_id, generation),
      opts: []
    }
  end

  defp delayed_job(execution, node_id, generation, %DateTime{} = resume_at) do
    %{
      args: job_args(execution, node_id, generation),
      opts: [scheduled_at: resume_at]
    }
  end

  defp delayed_job(execution, node_id, generation, _resume_at) do
    immediate_job(execution, node_id, generation)
  end

  defp job_args(execution, node_id, generation) do
    %{
      installation_id: execution.installation_id,
      execution_id: execution.id,
      expected_node_id: node_id,
      generation: generation
    }
  end

  defp next_job_changeset(%{worker: worker, args: args, opts: opts}) do
    worker.new(args, opts)
  end

  defp next_job_changeset(%{args: args, opts: opts}) do
    AdvanceExecutionWorker.new(args, opts)
  end

  defp retry_at(%Outcome{kind: :retryable_error, resume_at: %DateTime{} = time}), do: time
  defp retry_at(_outcome), do: nil

  defp duration_ms(%DateTime{} = started_at, %DateTime{} = ended_at) do
    max(0, DateTime.diff(ended_at, started_at, :millisecond))
  end

  defp duration_ms(_started_at, _ended_at), do: 0

  defp wake_after(repo, %Execution{} = execution) do
    if Execution.terminal?(execution.status) do
      Concurrency.admissions(repo, execution.installation_id)
    else
      []
    end
  end

  defp finish_finalize({:ok, %{applied: :noop}}), do: {:ok, :noop}

  defp finish_finalize({:ok, %{applied: %{execution: execution} = applied}}) do
    emit_finalize(applied)
    {:ok, execution}
  end

  defp finish_finalize({:error, _step, :noop, _changes}), do: {:ok, :noop}
  defp finish_finalize({:error, :lock, %Error{} = error, _changes}), do: {:error, error}
  defp finish_finalize({:error, _step, %Error{} = error, _changes}), do: {:error, error}

  defp finish_finalize({:error, _step, reason, _changes}) do
    {:error,
     Error.new(:internal, :finalize_failed,
       message: "The step could not be finalized.",
       details: %{reason: inspect(reason)}
     )}
  end

  ## Cancellation

  defp cancel_multi(scope, execution_id, attrs) do
    Multi.new()
    |> Service.as_multi()
    |> Multi.run(:applied, fn repo, _changes ->
      do_cancel(repo, scope, execution_id, attrs)
    end)
    |> Multi.merge(&enqueue_cancel_followup/1)
  end

  defp cancel_all_multi(scope, attrs) do
    Multi.new()
    |> Service.as_multi()
    |> Multi.run(:applied, fn repo, _changes -> do_cancel_all(repo, scope, attrs) end)
    |> Multi.merge(&enqueue_cancel_followup/1)
  end

  defp enqueue_cancel_followup(%{applied: %{idempotent?: true}}) do
    empty_jobs()
  end

  defp enqueue_cancel_followup(%{applied: applied}) do
    Multi.new()
    |> Service.as_multi()
    |> then(&enqueue_execution_jobs_onto(&1, Map.get(applied, :wake, [])))
    |> Writer.append(:audit, fn _changes -> cancel_audit(applied) end)
    |> maybe_append_approval_cancel_audit(applied)
  end

  defp maybe_append_approval_cancel_audit(
         multi,
         %{kind: :single, cancelled_approvals: [approval | _]} = applied
       ) do
    Writer.append(multi, :approval_audit, fn _changes ->
      ApprovalService.cancelled_audit(approval, applied.execution, %{
        actor_type: "user",
        actor_id: applied.scope.member_id,
        actor_role: applied.scope.role,
        source: "cancel"
      })
    end)
  end

  defp maybe_append_approval_cancel_audit(multi, _applied), do: multi

  defp enqueue_execution_jobs_onto(multi, []), do: Multi.put(multi, :job, nil)

  defp enqueue_execution_jobs_onto(multi, [execution]) do
    PumbleAutomation.Oban.insert(multi, :job, fn _changes ->
      next_job_changeset(execution_job_spec(execution))
    end)
  end

  defp enqueue_execution_jobs_onto(multi, executions) do
    executions
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {execution, index}, acc ->
      PumbleAutomation.Oban.insert(acc, {:job, index}, fn _changes ->
        next_job_changeset(execution_job_spec(execution))
      end)
    end)
  end

  defp do_cancel(repo, scope, execution_id, attrs) do
    repo.query!("SELECT set_config('lock_timeout', $1, true)", [@lock_timeout])
    ids = %{installation_id: scope.installation_id, execution_id: execution_id}

    with :ok <- Policy.authorize(scope, :cancel_execution),
         {:ok, reason} <- parse_cancel_reason(attrs),
         {:ok, execution} <- lock_resolve_execution(repo, ids) do
      apply_cancel(repo, scope, execution, reason, :single)
    end
  end

  defp do_cancel_all(repo, scope, attrs) do
    repo.query!("SELECT set_config('lock_timeout', $1, true)", [@lock_timeout])

    with :ok <- Policy.authorize(scope, :destructive_lifecycle),
         {:ok, reason} <- parse_cancel_reason(attrs),
         {:ok, workflow_id} <- optional_uuid(attrs, :workflow_id) do
      executions = repo.all(cancel_all_query(scope.installation_id, workflow_id))
      reduce_cancel_all(repo, scope, executions, reason)
    end
  end

  defp cancel_all_query(installation_id, nil) do
    from execution in Execution,
      where: execution.installation_id == ^installation_id,
      where: execution.status not in ^Execution.terminal_statuses(),
      lock: "FOR UPDATE"
  end

  defp cancel_all_query(installation_id, workflow_id) do
    from execution in Execution,
      where: execution.installation_id == ^installation_id,
      where: execution.workflow_id == ^workflow_id,
      where: execution.status not in ^Execution.terminal_statuses(),
      lock: "FOR UPDATE"
  end

  defp reduce_cancel_all(repo, scope, executions, reason) do
    Enum.reduce_while(executions, {:ok, []}, fn execution, {:ok, acc} ->
      case apply_cancel(repo, scope, execution, reason, :bulk) do
        {:ok, %{idempotent?: true}} ->
          {:cont, {:ok, acc}}

        {:ok, applied} ->
          {:cont, {:ok, [applied | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, applied} ->
        {:ok,
         %{
           executions: Enum.map(applied, & &1.execution),
           count: length(applied),
           wake: wake_after_bulk(repo, scope.installation_id),
           scope: scope,
           reason: reason,
           previous_state: "in_flight",
           next_state: "cancelled",
           idempotent?: applied == []
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_cancel(repo, scope, %Execution{} = execution, reason, kind) do
    cond do
      execution.status == "cancelled" ->
        {:ok, %{execution: execution, wake: [], idempotent?: true, scope: scope, kind: kind}}

      match?(%DateTime{}, execution.cancelled_at) and execution.status == "running" ->
        {:ok, %{execution: execution, wake: [], idempotent?: true, scope: scope, kind: kind}}

      Execution.terminal?(execution.status) ->
        StateMachine.transition(:execution, execution.status, :cancel)

      execution.status == "running" ->
        request_running_cancel(repo, scope, execution, reason, kind)

      true ->
        halt_inflight_cancel(repo, scope, execution, reason, kind)
    end
  end

  defp request_running_cancel(repo, scope, execution, reason, kind) do
    now = DateTime.utc_now()

    execution
    |> Execution.changeset(%{
      cancelled_at: now,
      cancelled_by_member_id: scope.member_id,
      cancellation_reason: reason
    })
    |> repo.update()
    |> case do
      {:ok, updated} ->
        {:ok, cancel_applied(scope, execution, updated, [], kind, reason)}

      {:error, changeset} ->
        {:error, invalid_execution("The execution could not be cancelled.", changeset)}
    end
  end

  defp halt_inflight_cancel(repo, scope, execution, reason, kind) do
    with {:ok, plan} <- StateMachine.transition(:execution, execution.status, :cancel),
         {:ok, approvals} <- cancel_pending_approvals(repo, execution, scope),
         {:ok, _attempts} <- cancel_started_attempts(repo, execution),
         {:ok, _step} <- cancel_current_step(repo, execution),
         {:ok, updated} <-
           persist_cancelled(repo, execution, scope, reason) do
      {:ok,
       cancel_applied(
         scope,
         execution,
         updated,
         wake_after(repo, updated),
         kind,
         reason,
         plan.from,
         approvals
       )}
    end
  end

  defp persist_cancelled(repo, execution, scope, reason) do
    now = DateTime.utc_now()

    execution
    |> Execution.changeset(%{
      status: "cancelled",
      cancelled_at: execution.cancelled_at || now,
      cancelled_by_member_id: execution.cancelled_by_member_id || scope.member_id,
      cancellation_reason: reason || execution.cancellation_reason,
      lock_version: execution.lock_version + 1
    })
    |> repo.update()
    |> case do
      {:ok, updated} ->
        {:ok, updated}

      {:error, changeset} ->
        {:error, invalid_execution("The execution could not be cancelled.", changeset)}
    end
  end

  defp cancel_current_step(repo, %Execution{} = execution) do
    case lock_step(repo, execution) do
      %StepExecution{} = step -> maybe_cancel_step(repo, step)
      nil -> {:ok, nil}
    end
  end

  defp maybe_cancel_step(repo, %StepExecution{} = step) do
    if Execution.terminal?(step.status) do
      {:ok, step}
    else
      apply_step_cancel(repo, step)
    end
  end

  defp apply_step_cancel(repo, %StepExecution{} = step) do
    with {:ok, plan} <- StateMachine.transition(:step, step.status, :cancel) do
      step
      |> StepExecution.changeset(%{status: plan.to})
      |> repo.update()
      |> finish_step_write()
    end
  end

  defp cancel_started_attempts(repo, %Execution{} = execution) do
    now = DateTime.utc_now()

    query =
      from attempt in StepAttempt,
        where:
          attempt.installation_id == ^execution.installation_id and
            attempt.status == "started" and
            attempt.step_execution_id in subquery(
              from step in StepExecution,
                where: step.execution_id == ^execution.id,
                select: step.id
            )

    {_count, rows} =
      repo.update_all(query,
        set: [
          status: "cancelled",
          ended_at: now,
          error_class: "cancelled",
          error_code: "cancelled",
          duration_ms: 0
        ]
      )

    {:ok, rows}
  end

  defp cancel_pending_approvals(repo, %Execution{} = execution, scope) do
    query =
      from approval in Approval,
        where:
          approval.execution_id == ^execution.id and
            approval.installation_id == ^execution.installation_id and
            approval.status == "pending",
        select: approval

    {_count, rows} =
      repo.update_all(query,
        set:
          DateTime.utc_now()
          |> Approval.cancel_set()
          |> Keyword.put(:decided_by_member_id, cancel_actor_id(scope)),
        inc: [lock_version: 1]
      )

    {:ok, rows || []}
  end

  defp cancel_applied(
         scope,
         previous,
         execution,
         wake,
         kind,
         reason,
         from \\ nil,
         approvals \\ []
       ) do
    %{
      execution: execution,
      executions: [execution],
      count: 1,
      wake: wake,
      scope: scope,
      kind: kind,
      reason: reason,
      previous_state: from || previous.status,
      next_state: execution.status,
      idempotent?: false,
      cancelled_approvals: approvals || []
    }
  end

  defp cancel_actor_id(%Scope{member_id: member_id}), do: member_id
  defp cancel_actor_id(_scope), do: nil

  defp parse_cancel_reason(attrs) do
    case attr(attrs, :reason) do
      nil ->
        {:ok, nil}

      reason when is_binary(reason) and byte_size(reason) <= 500 ->
        {:ok, reason}

      reason when is_binary(reason) ->
        {:error,
         Error.new(:validation, :invalid_execution,
           message: "The cancellation reason is too long."
         )}

      _other ->
        {:error,
         Error.new(:validation, :invalid_execution,
           message: "The cancellation reason must be text."
         )}
    end
  end

  defp cancel_audit(%{count: count} = applied) when count != 1 do
    scope = applied.scope

    %{
      installation_id: scope.installation_id,
      actor_type: "user",
      actor_id: scope.member_id,
      action: "execution.cancelled",
      resource_type: "execution",
      metadata: %{
        "actor_role" => scope.role,
        "result" => "ok",
        "count" => count,
        "previous_state" => applied.previous_state,
        "next_state" => applied.next_state,
        "reason" => applied.reason || "cancel_all"
      }
    }
  end

  defp cancel_audit(applied) do
    scope = applied.scope
    execution = applied.execution

    %{
      installation_id: execution.installation_id,
      actor_type: "user",
      actor_id: scope.member_id,
      action: "execution.cancelled",
      resource_type: "execution",
      resource_id: execution.id,
      metadata: %{
        "actor_role" => scope.role,
        "result" => "ok",
        "previous_state" => applied.previous_state,
        "next_state" => applied.next_state,
        "reason" => applied.reason || "cancelled"
      }
    }
  end

  defp wake_after_bulk(repo, installation_id) do
    Concurrency.admissions(repo, installation_id)
  end

  defp finish_cancel({:ok, %{applied: %{execution: execution}}}), do: {:ok, execution}
  defp finish_cancel({:error, :lock, %Error{} = error, _changes}), do: {:error, error}
  defp finish_cancel({:error, _step, %Error{} = error, _changes}), do: {:error, error}

  defp finish_cancel({:error, _step, _reason, _changes}) do
    {:error,
     Error.new(:internal, :cancel_failed, message: "The execution could not be cancelled.")}
  end

  defp finish_cancel_all({:ok, %{applied: applied}}) do
    {:ok, %{count: applied.count, executions: applied.executions}}
  end

  defp finish_cancel_all({:error, :lock, %Error{} = error, _changes}), do: {:error, error}
  defp finish_cancel_all({:error, _step, %Error{} = error, _changes}), do: {:error, error}

  defp finish_cancel_all({:error, _step, _reason, _changes}) do
    {:error,
     Error.new(:internal, :cancel_failed, message: "The executions could not be cancelled.")}
  end

  ## Reconciliation

  defp reconcile_multi(args) do
    Multi.new()
    |> Service.as_multi()
    |> Multi.run(:applied, fn repo, _changes -> do_reconcile(repo, args) end)
    |> Multi.merge(&enqueue_reconcile_followup/1)
  end

  defp enqueue_reconcile_followup(%{applied: %{count: 0}}) do
    empty_jobs()
  end

  defp enqueue_reconcile_followup(%{applied: applied}) do
    multi =
      Multi.new()
      |> Service.as_multi()
      |> enqueue_job_specs_onto(applied.jobs)

    case reconcile_audit(applied) do
      nil -> multi
      attrs -> Writer.append(multi, :audit, fn _changes -> attrs end)
    end
  end

  defp enqueue_job_specs_onto(multi, []), do: Multi.put(multi, :job, nil)

  defp enqueue_job_specs_onto(multi, [spec]) do
    PumbleAutomation.Oban.insert(multi, :job, fn _changes -> next_job_changeset(spec) end)
  end

  defp enqueue_job_specs_onto(multi, specs) do
    specs
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {spec, index}, acc ->
      PumbleAutomation.Oban.insert(acc, {:job, index}, fn _changes -> next_job_changeset(spec) end)
    end)
  end

  defp do_reconcile(repo, args) do
    repo.query!("SELECT set_config('lock_timeout', $1, true)", [@lock_timeout])
    installation_id = attr(args, :installation_id)
    actor = attr(args, :actor)
    now = DateTime.utc_now()

    with {:ok, _tenant} <- maybe_lock_tenant(repo, installation_id),
         {:ok, cancelled} <- reconcile_uninstalled(repo, installation_id, now),
         {:ok, paused, retry_jobs} <- reconcile_stale_attempts(repo, installation_id, now),
         {:ok, waiting_jobs} <- reconcile_waiting_jobs(repo, installation_id),
         {:ok, timeout_jobs} <- reconcile_approval_timeout_jobs(repo, installation_id),
         {:ok, delivery_jobs} <- reconcile_approval_delivery_jobs(repo, installation_id),
         {:ok, missing_jobs} <- reconcile_missing_jobs(repo, installation_id) do
      jobs = retry_jobs ++ waiting_jobs ++ timeout_jobs ++ delivery_jobs ++ missing_jobs
      count = length(cancelled) + length(paused) + length(jobs)

      {:ok,
       %{
         count: count,
         cancelled: length(cancelled),
         paused: length(paused),
         jobs: jobs,
         installation_id: installation_id,
         actor: actor
       }}
    end
  end

  defp maybe_lock_tenant(repo, installation_id) when is_binary(installation_id) do
    query =
      from installation in Installation,
        where: installation.id == ^installation_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      %Installation{} = installation -> {:ok, installation}
      nil -> {:error, Policy.not_found()}
    end
  end

  defp maybe_lock_tenant(_repo, _installation_id), do: {:ok, :all}

  defp reconcile_uninstalled(repo, installation_id, now) do
    query =
      from execution in Execution,
        join: installation in Installation,
        on: installation.id == execution.installation_id,
        where: installation.status != "active",
        where: execution.status not in ^Execution.terminal_statuses(),
        select: execution,
        limit: ^@reconcile_batch

    query = scope_execution_query(query, installation_id)

    executions = repo.all(query)

    Enum.reduce_while(executions, {:ok, []}, fn execution, {:ok, acc} ->
      case persist_system_cancel(repo, execution, now, "uninstalled") do
        {:ok, updated} -> {:cont, {:ok, [updated | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reconcile_stale_attempts(repo, installation_id, now) do
    cutoff = DateTime.add(now, -Concurrency.stale_after_seconds(), :second)

    query =
      from attempt in StepAttempt,
        join: step in StepExecution,
        on: step.id == attempt.step_execution_id,
        join: execution in Execution,
        on: execution.id == step.execution_id,
        where: attempt.status == "started",
        where: attempt.started_at < ^cutoff,
        where: execution.status == "running",
        select: {attempt, step, execution},
        limit: ^@reconcile_batch

    query = scope_stale_query(query, installation_id)

    rows = repo.all(query)

    Enum.reduce_while(rows, {:ok, [], []}, fn {attempt, step, execution}, {:ok, paused, jobs} ->
      case repair_stale_attempt(repo, execution, step, attempt, now) do
        {:ok, {:retry, spec}} -> {:cont, {:ok, paused, [spec | jobs]}}
        {:ok, repaired} -> {:cont, {:ok, [repaired | paused], jobs}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reconcile_waiting_jobs(repo, installation_id) do
    query =
      from execution in Execution,
        as: :exec,
        where: execution.status == "waiting_delay",
        where: is_nil(execution.cancelled_at),
        where: not exists(incomplete_advance_subquery()),
        limit: ^@reconcile_batch

    query = scope_execution_query(query, installation_id)

    executions =
      query
      |> repo.all()
      |> Enum.filter(&Concurrency.installation_active?(repo, &1.installation_id))

    {:ok, Enum.map(executions, &waiting_job_spec(repo, &1))}
  end

  defp reconcile_approval_delivery_jobs(repo, installation_id) do
    query =
      from approval in Approval,
        as: :approval,
        join: execution in Execution,
        on:
          execution.id == approval.execution_id and
            execution.installation_id == approval.installation_id,
        where: approval.status == "pending",
        where: is_nil(approval.pumble_message_id),
        where: execution.status == "waiting_approval",
        where: is_nil(execution.cancelled_at),
        where: not exists(incomplete_delivery_subquery()),
        select: approval,
        limit: ^@reconcile_batch

    query = scope_approval_query(query, installation_id)

    jobs =
      query
      |> repo.all()
      |> Enum.filter(&Concurrency.installation_active?(repo, &1.installation_id))
      |> Enum.map(&ApprovalDeliveryWorker.job_spec/1)

    {:ok, jobs}
  end

  defp reconcile_approval_timeout_jobs(repo, installation_id) do
    query =
      from approval in Approval,
        as: :approval,
        join: execution in Execution,
        on:
          execution.id == approval.execution_id and
            execution.installation_id == approval.installation_id,
        where: approval.status == "pending",
        where: not is_nil(approval.expires_at),
        where: execution.status == "waiting_approval",
        where: is_nil(execution.cancelled_at),
        where: not exists(incomplete_timeout_subquery()),
        select: {approval, execution},
        limit: ^@reconcile_batch

    query = scope_approval_query(query, installation_id)

    jobs =
      query
      |> repo.all()
      |> Enum.filter(fn {approval, _execution} ->
        Concurrency.installation_active?(repo, approval.installation_id)
      end)
      |> Enum.map(fn {approval, execution} ->
        ApprovalTimeoutWorker.job_spec(
          approval,
          execution.current_node_id,
          execution.lock_version
        )
      end)

    {:ok, jobs}
  end

  defp incomplete_timeout_subquery do
    from job in Oban.Job,
      where: job.worker == ^Concurrency.approval_timeout_worker(),
      where: job.state in ^Concurrency.incomplete_job_states(),
      where: fragment("? ->> 'approval_id' = ?::text", job.args, parent_as(:approval).id)
  end

  defp incomplete_delivery_subquery do
    from job in Oban.Job,
      where: job.worker == ^Concurrency.approval_delivery_worker(),
      where: job.state in ^Concurrency.incomplete_job_states(),
      where: fragment("? ->> 'approval_id' = ?::text", job.args, parent_as(:approval).id)
  end

  defp scope_approval_query(query, nil), do: query

  defp scope_approval_query(query, installation_id) do
    from [approval, execution] in query, where: execution.installation_id == ^installation_id
  end

  defp reconcile_missing_jobs(repo, installation_id) do
    installation_ids = reconcile_installation_ids(repo, installation_id)

    jobs =
      Enum.flat_map(installation_ids, fn id ->
        Enum.map(Concurrency.admissions(repo, id), &execution_job_spec/1)
      end)

    running =
      from(execution in Execution,
        as: :exec,
        where: execution.status == "running",
        where: is_nil(execution.cancelled_at),
        where: not exists(incomplete_advance_subquery()),
        where:
          not exists(
            from attempt in StepAttempt,
              join: step in StepExecution,
              on: step.id == attempt.step_execution_id,
              where: step.execution_id == parent_as(:exec).id,
              where: attempt.status == "started"
          ),
        limit: ^@reconcile_batch
      )
      |> scope_execution_query(installation_id)
      |> repo.all()
      |> Enum.filter(&Concurrency.installation_active?(repo, &1.installation_id))
      |> Enum.map(&execution_job_spec/1)

    {:ok, jobs ++ running}
  end

  defp reconcile_installation_ids(_repo, installation_id) when is_binary(installation_id) do
    [installation_id]
  end

  defp reconcile_installation_ids(repo, _installation_id) do
    repo.all(
      from execution in Execution,
        as: :exec,
        where: execution.status == "queued",
        where: is_nil(execution.cancelled_at),
        where: not exists(incomplete_advance_subquery()),
        distinct: true,
        select: execution.installation_id,
        limit: ^@reconcile_batch
    )
  end

  defp incomplete_advance_subquery do
    from job in Oban.Job,
      where: job.worker == ^Concurrency.advance_worker(),
      where: job.state in ^Concurrency.incomplete_job_states(),
      where: fragment("? ->> 'execution_id' = ?::text", job.args, parent_as(:exec).id)
  end

  defp scope_execution_query(query, nil), do: query

  defp scope_execution_query(query, installation_id) do
    from execution in query, where: execution.installation_id == ^installation_id
  end

  defp scope_stale_query(query, nil), do: query

  defp scope_stale_query(query, installation_id) do
    from [attempt, step, execution] in query,
      where: execution.installation_id == ^installation_id
  end

  defp waiting_job_spec(repo, %Execution{} = execution) do
    resume_at = waiting_resume_at(repo, execution)

    if resume_at do
      delayed_job(execution, execution.current_node_id, execution.lock_version, resume_at)
    else
      immediate_job(execution, execution.current_node_id, execution.lock_version)
    end
  end

  defp waiting_resume_at(repo, %Execution{status: "waiting_delay"} = execution) do
    query =
      from step in StepExecution,
        where:
          step.execution_id == ^execution.id and
            step.installation_id == ^execution.installation_id and
            step.node_id == ^execution.current_node_id,
        select: step.output,
        limit: 1

    case repo.one(query) do
      output when is_map(output) -> parse_resume_at(Map.get(output, "resume_at"))
      _missing -> nil
    end
  end

  defp waiting_resume_at(_repo, %Execution{}), do: nil

  defp repair_stale_attempt(repo, execution, step, attempt, now) do
    cond do
      cancelled?(execution) ->
        with {:ok, _} <- close_stale_attempt(repo, attempt, now, "cancelled", "cancelled") do
          persist_system_cancel(repo, execution, now, "stale_cancelled")
        end

      stale_retry_safe?(repo, execution, step) ->
        with {:ok, _} <- close_stale_attempt(repo, attempt, now, "cancelled", "stale_attempt") do
          {:ok, {:retry, execution_job_spec(execution)}}
        end

      true ->
        pause_stale_uncertain(repo, execution, step, attempt, now)
    end
  end

  defp stale_retry_safe?(repo, execution, step) do
    case load_compiled(repo, execution) do
      {:ok, compiled} ->
        node = Map.get(compiled.nodes, step.node_id) || %{type: step.node_type}
        RetryPolicy.retry_safety(node) in [:read_only, :idempotent_effect]

      {:error, _reason} ->
        false
    end
  end

  defp pause_stale_uncertain(repo, execution, step, attempt, now) do
    diagnostics = stale_uncertainty_diagnostics(step, attempt)

    with {:ok, _} <-
           close_stale_attempt(
             repo,
             attempt,
             now,
             "uncertain",
             "side_effect_uncertain",
             diagnostics
           ),
         {:ok, _} <- pause_stale_step(repo, step) do
      execution
      |> Execution.changeset(%{
        status: "paused_uncertain",
        lock_version: execution.lock_version + 1
      })
      |> repo.update()
      |> finish_execution_write()
    end
  end

  defp pause_stale_step(repo, %StepExecution{} = step) do
    step
    |> StepExecution.changeset(%{
      status: "paused_uncertain",
      uncertainty_reason: "The in-flight effect may have already been sent."
    })
    |> repo.update()
    |> finish_step_write()
  end

  defp close_stale_attempt(repo, attempt, now, status, class, diagnostics \\ %{}) do
    query =
      from a in StepAttempt,
        where: a.id == ^attempt.id and a.status == "started",
        select: a

    case repo.update_all(query,
           set: [
             status: status,
             ended_at: now,
             error_class: class,
             error_code: class,
             duration_ms: duration_ms(attempt.started_at, now),
             diagnostics: diagnostics
           ]
         ) do
      {1, [row]} -> {:ok, row}
      {0, _rows} -> {:ok, attempt}
    end
  end

  defp stale_uncertainty_diagnostics(step, attempt) do
    %{
      "kind" => "uncertain",
      "message" => "The worker stopped after remote dispatch may have begun.",
      "error_class" => "side_effect_uncertain",
      "effect_key" => step.effect_key,
      "attempt" => attempt.attempt_number,
      "operation" => step.node_type,
      "request_summary" => step.node_type,
      "dispatch_state" => "unknown",
      "duplicate_risk" => true,
      "guidance" =>
        "Check the remote system before marking success, failure, or deliberately retrying."
    }
  end

  defp remote_status(%{"status" => status}) when is_integer(status), do: status
  defp remote_status(%{"remote_status" => status}) when is_integer(status), do: status
  defp remote_status(_output), do: nil

  defp persist_system_cancel(repo, execution, now, reason) do
    with {:ok, _} <- cancel_pending_approvals(repo, execution, nil),
         {:ok, _} <- cancel_started_attempts(repo, execution),
         {:ok, _} <- cancel_current_step(repo, execution) do
      execution
      |> Execution.changeset(%{
        status: "cancelled",
        cancelled_at: execution.cancelled_at || now,
        cancellation_reason: reason,
        lock_version: execution.lock_version + 1
      })
      |> repo.update()
      |> finish_execution_write()
    end
  end

  defp finish_step_write({:ok, step}), do: {:ok, step}
  defp finish_step_write({:error, changeset}), do: {:error, step_insert_error(changeset)}

  defp finish_execution_write({:ok, execution}), do: {:ok, execution}

  defp finish_execution_write({:error, changeset}) do
    {:error, invalid_execution("The execution could not be repaired.", changeset)}
  end

  defp reconcile_audit(applied) do
    actor = applied.actor
    installation_id = applied.installation_id || audit_installation(actor)

    if is_nil(installation_id) do
      nil
    else
      {actor_type, actor_id, actor_role} =
        case actor do
          %Scope{} = scope -> {"user", scope.member_id, scope.role}
          _other -> {"job", "reconciliation_worker", nil}
        end

      %{
        installation_id: installation_id,
        actor_type: actor_type,
        actor_id: actor_id,
        action: "execution.reconciled",
        resource_type: "execution",
        metadata:
          %{
            "result" => "ok",
            "source" => "reconciliation",
            "count" => applied.count,
            "actor_role" => actor_role
          }
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.new()
      }
    end
  end

  defp audit_installation(%Scope{installation_id: id}), do: id
  defp audit_installation(_actor), do: nil

  defp finish_reconcile({:ok, %{applied: applied}}) do
    emit_reconcile(applied, "ok")

    {:ok,
     %{
       count: applied.count,
       cancelled: Map.get(applied, :cancelled, 0),
       paused: Map.get(applied, :paused, 0),
       jobs: length(Map.get(applied, :jobs, []))
     }}
  end

  defp finish_reconcile({:error, :lock, %Error{} = error, _changes}) do
    emit_reconcile(%{count: 0}, "error", error)
    {:error, error}
  end

  defp finish_reconcile({:error, _step, %Error{} = error, _changes}) do
    emit_reconcile(%{count: 0}, "error", error)
    {:error, error}
  end

  defp finish_reconcile({:error, _step, _reason, _changes}) do
    emit_reconcile(%{count: 0}, "error")

    {:error, Error.new(:internal, :reconcile_failed, message: "Reconciliation could not finish.")}
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  ## Uncertain resolution

  defp resolve_multi(scope, execution_id, request) do
    Multi.new()
    |> Service.as_multi()
    |> Multi.run(:applied, fn repo, _changes ->
      do_resolve(repo, scope, execution_id, request)
    end)
    |> Multi.merge(&enqueue_resolve_followup(scope, request, &1))
  end

  defp enqueue_resolve_followup(_scope, _request, %{applied: %{idempotent?: true}}) do
    empty_jobs()
  end

  defp enqueue_resolve_followup(scope, request, %{applied: applied}) do
    applied
    |> Map.get(:job)
    |> followup_jobs(Map.get(applied, :wake, []))
    |> enqueue_job_specs()
    |> Writer.append(:audit, fn _changes ->
      Uncertainty.audit_attrs(scope, applied.execution, request, applied.plan)
    end)
  end

  defp do_resolve(repo, scope, execution_id, request) do
    repo.query!("SELECT set_config('lock_timeout', $1, true)", [@lock_timeout])
    ids = %{installation_id: scope.installation_id, execution_id: execution_id}

    with {:ok, execution} <- lock_resolve_execution(repo, ids),
         :ok <- Uncertainty.authorize(scope),
         {:ok, compiled} <- load_compiled(repo, execution),
         {:ok, step} <- require_current_step(repo, execution),
         {:ok, plan} <- Uncertainty.plan(execution, step, compiled, request),
         :ok <- require_resolve_dispatch(repo, execution, plan) do
      apply_resolve(repo, execution, step, compiled, plan)
    end
  end

  defp lock_resolve_execution(repo, ids) do
    case lock_execution(repo, ids) do
      {:ok, execution} -> {:ok, execution}
      {:error, :noop} -> {:error, Policy.not_found()}
    end
  end

  defp require_resolve_dispatch(_repo, _execution, %{dispatch?: false}), do: :ok

  defp require_resolve_dispatch(repo, execution, _plan) do
    if installation_active?(repo, execution.installation_id) do
      :ok
    else
      {:error,
       Error.new(:permission, :installation_revoked,
         message: "This workspace's authorization is no longer valid."
       )}
    end
  end

  defp apply_resolve(_repo, execution, _step, _compiled, %{idempotent?: true} = plan) do
    {:ok, %{execution: execution, job: nil, plan: plan, idempotent?: true}}
  end

  defp apply_resolve(repo, execution, step, compiled, plan) do
    with {:ok, context} <- resolve_context(execution, step, plan),
         {:ok, _step} <- finish_resolve_step(repo, step, plan),
         {:ok, execution} <- finish_execution(repo, execution, context, plan),
         {:ok, _next} <- insert_next_step(repo, execution, compiled, plan) do
      {:ok,
       %{
         execution: execution,
         job: plan.job,
         plan: plan,
         idempotent?: false,
         wake: wake_after(repo, execution)
       }}
    end
  end

  defp resolve_context(execution, step, plan) do
    case merge_context(execution.context, step.node_id, plan.output, plan.merge_output?) do
      {:ok, context} ->
        {:ok, context}

      {:error, :context_overflow} ->
        {:error,
         Error.new(:validation, :output_too_large, message: "The step output is too large.")}
    end
  end

  defp finish_resolve_step(repo, %StepExecution{} = step, plan) do
    attrs =
      %{status: plan.step_to}
      |> put_if(plan.merge_output?, :output, plan.output)
      |> put_if(not is_nil(plan.selected_edge), :selected_edge, plan.selected_edge)

    step
    |> StepExecution.changeset(attrs)
    |> repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> {:error, step_insert_error(changeset)}
    end
  end

  defp put_if(attrs, true, key, value), do: Map.put(attrs, key, value)
  defp put_if(attrs, false, _key, _value), do: attrs

  defp finish_resolve({:ok, %{applied: %{execution: execution}}}) do
    log_uncertain(execution, "ok", nil)
    {:ok, execution}
  end

  defp finish_resolve({:error, :lock, %Error{} = error, _changes}) do
    log_uncertain(nil, "error", error)
    {:error, error}
  end

  defp finish_resolve({:error, _step, :noop, _changes}) do
    {:error,
     Error.new(:conflict, :illegal_transition,
       message: "The execution cannot make that transition."
     )}
  end

  defp finish_resolve({:error, _step, %Error{} = error, _changes}) do
    log_uncertain(nil, "error", error)
    {:error, error}
  end

  defp finish_resolve({:error, _step, _reason, _changes}) do
    {:error,
     Error.new(:internal, :resolution_failed,
       message: "The uncertain step could not be resolved."
     )}
  end

  defp log_uncertain(execution, status, error) do
    fields = %{
      operation: "execution.uncertain",
      event_type: "uncertainty",
      status: (execution && execution.status) || status
    }

    fields =
      if execution do
        Map.merge(fields, %{
          installation_id: execution.installation_id,
          workflow_id: execution.workflow_id,
          version_id: execution.workflow_version_id,
          execution_id: execution.id
        })
      else
        fields
      end

    fields =
      if error do
        Map.merge(fields, %{error_code: error.code, error_class: error.class})
      else
        fields
      end

    Logging.event(:info, "execution.uncertain", fields)
  end

  defp emit_create(%Execution{} = execution) do
    PumbleAutomation.Telemetry.execute(
      @telemetry_event ++ [:transition],
      %{count: 1},
      %{
        operation: "create",
        from: "new",
        status: execution.status,
        type: "execution",
        installation_id: execution.installation_id,
        workflow_id: execution.workflow_id,
        execution_id: execution.id
      }
    )
  end

  defp finalize_telemetry(snapshot, execution, attempt, outcome) do
    %{
      type: snapshot.node_type,
      from: "running",
      to: execution.status,
      duration_ms: attempt.duration_ms || 0,
      kind: kind_name(outcome.kind),
      error_class: outcome.error_class,
      execution_duration_ms: duration_ms(execution.inserted_at, execution.updated_at),
      installation_id: execution.installation_id,
      workflow_id: execution.workflow_id,
      version_id: execution.workflow_version_id,
      execution_id: execution.id,
      step_id: snapshot.step_execution_id,
      attempt_id: snapshot.attempt_id
    }
  end

  defp emit_finalize(%{telemetry: telemetry}) when is_map(telemetry) do
    ids =
      Map.take(telemetry, [
        :installation_id,
        :workflow_id,
        :version_id,
        :execution_id,
        :step_id,
        :attempt_id
      ])

    PumbleAutomation.Telemetry.execute(
      @telemetry_event ++ [:step, :stop],
      %{duration_ms: telemetry.duration_ms, count: 1},
      Map.merge(ids, %{
        operation: "step",
        type: telemetry.type,
        status: telemetry.to,
        kind: telemetry.kind,
        error_class: telemetry.error_class
      })
    )

    PumbleAutomation.Telemetry.execute(
      @telemetry_event ++ [:transition],
      %{count: 1},
      Map.merge(ids, %{
        operation: "finalize",
        from: telemetry.from,
        status: telemetry.to,
        type: telemetry.type
      })
    )

    if telemetry.kind == "retryable_error" do
      PumbleAutomation.Telemetry.execute(
        @telemetry_event ++ [:retry],
        %{count: 1},
        Map.merge(ids, %{
          operation: "retry",
          type: telemetry.type,
          error_class: telemetry.error_class,
          status: telemetry.to
        })
      )
    end

    if telemetry.kind == "uncertain" or telemetry.to == "paused_uncertain" do
      PumbleAutomation.Telemetry.execute(
        @telemetry_event ++ [:uncertain],
        %{count: 1},
        Map.merge(ids, %{
          operation: "uncertain",
          type: telemetry.type,
          error_class: telemetry.error_class,
          status: telemetry.to
        })
      )
    end

    if Execution.terminal?(telemetry.to) do
      PumbleAutomation.Telemetry.execute(
        @telemetry_event ++ [:stop],
        %{duration_ms: telemetry.execution_duration_ms, count: 1},
        Map.merge(ids, %{operation: "execution", status: telemetry.to, type: telemetry.type})
      )
    end

    :ok
  end

  defp emit_finalize(_applied), do: :ok

  defp emit_reconcile(applied, status, error \\ nil) do
    metadata = %{
      operation: "reconcile",
      status: status,
      installation_id: Map.get(applied, :installation_id)
    }

    metadata =
      if error do
        Map.merge(metadata, %{error_class: error.class, error_code: error.code})
      else
        metadata
      end

    PumbleAutomation.Telemetry.execute(
      @telemetry_event ++ [:reconcile],
      %{
        count: Map.get(applied, :count, 0),
        cancelled: Map.get(applied, :cancelled, 0),
        paused: Map.get(applied, :paused, 0),
        jobs: length(Map.get(applied, :jobs, []))
      },
      metadata
    )
  end

  defp kind_name(kind) when is_atom(kind), do: Atom.to_string(kind)

  defp transact(multi) do
    Repo.transaction(multi)
  rescue
    exception in Postgrex.Error ->
      if lock_timeout?(exception) do
        {:error, :lock, lock_timeout_error(), %{}}
      else
        {:error, :database, exception, %{}}
      end

    exception in DBConnection.ConnectionError ->
      {:error, :database, exception, %{}}
  end

  defp lock_timeout?(%Postgrex.Error{postgres: %{code: code}})
       when code in [:lock_not_available, :query_canceled],
       do: true

  defp lock_timeout?(_exception), do: false

  defp lock_timeout_error do
    Error.new(:timeout, :lock_timeout,
      retryable?: true,
      message: "The execution is busy. Try again."
    )
  end

  defp required_uuid(attrs, field) do
    case Ecto.UUID.cast(attr(attrs, field)) do
      {:ok, uuid} ->
        {:ok, uuid}

      :error ->
        {:error,
         Error.new(:validation, :invalid_execution,
           message: "The #{field} is not a valid identifier."
         )}
    end
  end

  defp optional_uuid(attrs, field) do
    case attr(attrs, field) do
      nil -> {:ok, nil}
      value -> required_uuid(%{field => value}, field)
    end
  end

  defp attr(attrs, field) when is_atom(field) do
    Map.get(attrs, field) || Map.get(attrs, Atom.to_string(field))
  end

  defp invalid_execution(message, changeset \\ nil) do
    details =
      case changeset do
        %Ecto.Changeset{} -> %{fields: Enum.map(changeset.errors, fn {field, _} -> field end)}
        _other -> %{}
      end

    Error.new(:validation, :invalid_execution, message: message, details: details)
  end

  defp violated?(%Ecto.Changeset{errors: errors}, name) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint_name) == name
    end)
  end
end
