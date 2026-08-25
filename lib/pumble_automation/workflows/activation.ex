defmodule PumbleAutomation.Workflows.Activation do
  @moduledoc """
  The one transaction that turns an edited draft into a running program.

  Activation is the boundary between configuration and production. Until it
  commits, nothing inbound can start a run of the new version. After it
  commits, readers see either the previous complete activation or the new
  complete one — never a version without bindings, bindings without a version,
  or a live pointer at a program that was not compiled.

  ## One `Ecto.Multi`

  The steps are the list in plan Section 16, in that order: lock the
  installation and the workflow, verify the draft revision and that the
  workspace may still run automations, validate and compile, insert or reuse
  the immutable version, replace the trigger-binding and schedule projections,
  point the workflow at the new version, and append an audit event. A failure
  at any step rolls every earlier step back.

  ## Versions are created, never rewritten

  `PumbleAutomation.Workflows.WorkflowVersion.create/2` is the only writer.
  An unchanged source and unchanged compiler/dependency snapshot hash to a
  version that already exists, and that version is reused rather than
  duplicated. During the database expand and rollback window, an unchanged
  source with a different immutable snapshot is refused. The operator must
  save a source revision before activation. This keeps the previous release's
  one-row source lookup valid until a later contract release.

  ## Deactivation stops matching, not in-flight work

  Disabling the enabled bindings and schedules, clearing `active_version_id`,
  and moving the status to `inactive` is what makes ingress and the clock
  stop creating work. A run that already named a version keeps that version.
  Cancelling those runs is a separate operation, owned by the execution
  engine, and is not implied by deactivation.

  ## Schedule projections

  The first `next_run_at` is `Schedule.first_run_at/2` from this transaction's
  activation time, never the activation timestamp itself. Reactivation uses
  the new transaction time; missed slots are not caught up. Editing a draft
  changes nothing until this transaction commits.

  A replacing activation disables the previous enabled clock and inserts the
  new projection in the same Multi. Concurrent dispatch resolves by row
  locks: an occurrence whose `Engine.create/2` already committed may still
  run, bound to the version it named. Unclaimed future occurrences are not
  selected after disable. Timezone and schedule-type changes are audited.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias PumbleAutomation.Audit.Writer
  alias PumbleAutomation.Error
  alias PumbleAutomation.Ingress.Endpoints
  alias PumbleAutomation.Ingress.WebhookEndpoint
  alias PumbleAutomation.Ingress.WebhookService
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Installations.Service
  alias PumbleAutomation.Limits
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows.CompiledWorkflow
  alias PumbleAutomation.Workflows.Compiler
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.ScheduleConfig
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Definition.WebhookConfig
  alias PumbleAutomation.Workflows.Dependencies
  alias PumbleAutomation.Workflows.Schedule
  alias PumbleAutomation.Workflows.TriggerBinding
  alias PumbleAutomation.Workflows.ValidationIssue
  alias PumbleAutomation.Workflows.Validator
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomation.Workflows.WorkflowVersion

  @usable_installation_statuses ~w(active degraded)

  @type result :: %{
          workflow: Workflow.t(),
          version: WorkflowVersion.t(),
          warnings: [ValidationIssue.t()],
          webhook_credentials: map() | nil
        }

  @doc """
  Activates the workflow's current draft at `expected_revision`.

  The revision is compare-and-swap: two activations that both observed the
  same draft produce one winner and a `:draft_revision_conflict` for the
  other. The winner's write is the only write that exists after commit.
  """
  @spec activate(Scope.t(), Ecto.UUID.t(), non_neg_integer()) ::
          {:ok, result()} | {:error, Error.t()}
  def activate(%Scope{} = scope, id, expected_revision)
      when is_integer(expected_revision) and expected_revision >= 0 do
    run(scope, id, %{kind: :draft, expected_revision: expected_revision})
  end

  @doc """
  Activates a previously stored immutable version of the workflow.

  The version row is not rewritten. The recorded install request, current
  secrets, and current connections are checked against the stored program, and
  new projections are written to point at it. A secret that is gone, or a scope
  omitted from the recorded request, blocks the switch; the live pointer is
  left where it was.
  """
  @spec reactivate(Scope.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, result()} | {:error, Error.t()}
  def reactivate(%Scope{} = scope, id, version_number)
      when is_integer(version_number) and version_number >= 1 do
    run(scope, id, %{kind: :version, version_number: version_number})
  end

  @doc """
  Stops new executions of the workflow from being created.

  Bindings and schedules are disabled in the same transaction that clears the
  live version pointer and records the deactivation. An already-inactive
  workflow is a `:not_active` conflict, not a silent success.
  """
  @spec deactivate(Scope.t(), Ecto.UUID.t()) :: {:ok, Workflow.t()} | {:error, Error.t()}
  def deactivate(%Scope{} = scope, id) do
    Multi.new()
    |> Service.as_multi()
    |> Multi.run(:locked, fn repo, _changes -> lock_workflow(repo, scope, id) end)
    |> Multi.run(:guard, fn _repo, %{locked: workflow} -> refute_inactive(workflow) end)
    |> Multi.run(:bindings, fn repo, %{locked: workflow} ->
      disable_bindings(repo, workflow)
    end)
    |> Multi.run(:schedules, fn repo, %{locked: workflow} ->
      disable_schedules(repo, workflow)
    end)
    |> Multi.run(:webhooks, fn repo, %{locked: workflow} ->
      disable_webhooks(repo, workflow)
    end)
    |> Multi.update(:workflow, fn %{locked: workflow} ->
      workflow
      |> Workflow.changeset(%{
        status: "inactive",
        updated_by_member_id: scope.member_id
      })
      |> Ecto.Changeset.put_change(:active_version_id, nil)
    end)
    |> Writer.append(:audit, &deactivation_audit(scope, &1))
    |> transact()
    |> finish_deactivation()
  end

  ## Activation transaction

  defp run(%Scope{} = scope, id, intent) do
    Multi.new()
    |> Service.as_multi()
    |> Multi.run(:installation, fn repo, _changes -> lock_installation(repo, scope) end)
    |> Multi.run(:locked, fn repo, _changes -> lock_workflow(repo, scope, id) end)
    |> Multi.run(:prepared, fn repo, changes -> prepare(repo, changes, intent) end)
    |> Multi.run(:version, fn _repo, changes -> put_version(scope, changes) end)
    |> Multi.run(:bindings, fn repo, changes -> replace_bindings(repo, changes) end)
    |> Multi.run(:schedules, fn repo, changes -> replace_schedules(repo, changes) end)
    |> Multi.run(:webhooks, fn repo, changes -> replace_webhooks(repo, changes) end)
    |> Multi.update(:workflow, &activation_changeset(scope, &1))
    |> Writer.append(:audit, &activation_audit(scope, &1))
    |> transact()
    |> finish_activation(scope)
  end

  defp lock_installation(repo, %Scope{installation_id: installation_id}) do
    query =
      from installation in Installation,
        where: installation.id == ^installation_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      nil ->
        {:error, Policy.not_found()}

      %Installation{status: status} = installation when status in @usable_installation_statuses ->
        {:ok, installation}

      %Installation{} ->
        {:error,
         Error.new(:permission, :installation_revoked,
           message: "This workspace's authorization is no longer valid."
         )}
    end
  end

  defp lock_workflow(repo, %Scope{installation_id: installation_id}, id) do
    query =
      from workflow in Workflow,
        where: workflow.id == ^id and workflow.installation_id == ^installation_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      nil -> {:error, Policy.not_found()}
      workflow -> {:ok, workflow}
    end
  end

  defp prepare(repo, changes, intent) do
    workflow = changes.locked
    installation = changes.installation

    with :ok <- refute_archived(workflow),
         :ok <- verify_revision(workflow, intent),
         :ok <- require_active_quota(repo, installation, workflow),
         {:ok, definition, existing_version} <- load_source(repo, workflow, intent),
         :ok <- require_schedule_quota(repo, installation, workflow, definition),
         {:ok, compiled, issues} <- compile(definition),
         dependencies = Dependencies.calculate(compiled),
         {:ok, resolved, issues} <- check_dependencies(dependencies, installation, issues) do
      {:ok,
       %{
         workflow: workflow,
         installation: installation,
         definition: definition,
         compiled: compiled,
         dependencies: dependencies,
         resolved: resolved,
         warnings: ValidationIssue.sort(Enum.filter(issues, &(&1.severity == :warning))),
         bump_revision?: intent.kind == :draft,
         existing_version: existing_version,
         activated_at: DateTime.utc_now()
       }}
    end
  end

  defp verify_revision(%Workflow{draft_revision: current}, %{
         kind: :draft,
         expected_revision: expected
       }) do
    if current == expected do
      :ok
    else
      {:error, revision_conflict(expected, current)}
    end
  end

  defp verify_revision(_workflow, %{kind: :version}), do: :ok

  defp load_source(_repo, workflow, %{kind: :draft}) do
    case Workflow.draft(workflow) do
      {:ok, definition} -> {:ok, definition, nil}
      {:error, %Error{}} = error -> error
    end
  end

  defp load_source(repo, workflow, %{kind: :version, version_number: version_number}) do
    query =
      from version in WorkflowVersion,
        where:
          version.workflow_id == ^workflow.id and
            version.installation_id == ^workflow.installation_id and
            version.version_number == ^version_number

    case repo.one(query) do
      nil ->
        {:error, Policy.not_found()}

      version ->
        case decode_source(version.source_definition) do
          {:ok, definition} -> {:ok, definition, version}
          {:error, %Error{}} = error -> error
        end
    end
  end

  defp decode_source(raw) when is_map(raw), do: Definition.decode(raw)

  defp decode_source(_raw) do
    {:error,
     Error.new(:validation, :invalid_definition, message: "The workflow definition is not valid.")}
  end

  defp compile(%Definition{} = definition) do
    issues = Validator.validate(definition)

    if ValidationIssue.errors?(issues) do
      blocked(issues)
    else
      case Compiler.compile(definition) do
        {:ok, compiled} -> {:ok, compiled, issues}
        {:error, compile_issues} -> blocked(issues ++ compile_issues)
      end
    end
  end

  defp check_dependencies(dependencies, installation, issues) do
    scope_issues = Dependencies.check(dependencies, installation.bot_scopes)

    case Dependencies.resolve(dependencies, installation.id) do
      {:ok, resolved} ->
        combined = issues ++ scope_issues

        if ValidationIssue.errors?(combined) do
          blocked(combined)
        else
          {:ok, resolved, combined}
        end

      {:error, resolve_issues} ->
        blocked(issues ++ scope_issues ++ resolve_issues)
    end
  end

  defp put_version(scope, %{prepared: prepared}) do
    with :ok <- verify_version_integrity(prepared.existing_version),
         versions <- versions_with_definition(prepared),
         :ok <- verify_versions_integrity(versions) do
      select_or_create_version(scope, prepared, versions)
    end
  end

  defp verify_version_integrity(nil), do: :ok

  defp verify_version_integrity(%WorkflowVersion{} = version) do
    if WorkflowVersion.intact?(version) or WorkflowVersion.legacy_intact?(version) do
      :ok
    else
      {:error,
       Error.new(:conflict, :version_integrity_failure,
         message: "The stored workflow version failed its integrity check."
       )}
    end
  end

  defp verify_versions_integrity(versions) do
    Enum.reduce_while(versions, :ok, fn version, :ok ->
      case verify_version_integrity(version) do
        :ok -> {:cont, :ok}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp same_snapshot?(%WorkflowVersion{} = version, prepared) do
    stored_identity = version.identity_hash || WorkflowVersion.identity_hash(version)
    stored_identity == WorkflowVersion.identity_hash(snapshot(prepared))
  end

  defp select_or_create_version(_scope, prepared, [version]) do
    if same_snapshot?(version, prepared) do
      {:ok, version}
    else
      {:error, snapshot_changed_error(prepared)}
    end
  end

  defp select_or_create_version(scope, prepared, []), do: create_version(scope, prepared)

  defp select_or_create_version(_scope, _prepared, _versions) do
    {:error,
     Error.new(:conflict, :version_integrity_failure,
       message: "More than one stored workflow version represents the same source."
     )}
  end

  defp snapshot_changed_error(%{existing_version: %WorkflowVersion{}}) do
    Error.new(:conflict, :snapshot_requires_source_revision,
      message:
        "This stored version's compiled or resolved snapshot changed and cannot be reactivated. Update the draft source and activate it as a new version."
    )
  end

  defp snapshot_changed_error(_prepared) do
    Error.new(:conflict, :snapshot_requires_source_revision,
      message:
        "The compiled or resolved workflow snapshot changed. Update the draft source before activation."
    )
  end

  defp snapshot(prepared) do
    %{
      source_definition: Definition.encode(prepared.definition),
      compiled_definition: CompiledWorkflow.encode(prepared.compiled),
      compiler_version: prepared.compiled.compiler_version,
      required_scopes: prepared.dependencies.required_scopes,
      referenced_secret_ids: prepared.resolved.secret_ids,
      referenced_connection_ids: prepared.resolved.connection_ids
    }
  end

  defp versions_with_definition(%{workflow: workflow, definition: definition}) do
    hash = WorkflowVersion.definition_hash(Definition.encode(definition))

    Repo.all(
      from version in WorkflowVersion,
        where:
          version.workflow_id == ^workflow.id and
            (version.source_hash == ^hash or
               (is_nil(version.source_hash) and version.definition_hash == ^hash)),
        order_by: [asc: version.version_number]
    )
  end

  defp create_version(scope, prepared) do
    WorkflowVersion.create(prepared.workflow, %{
      source_definition: prepared.definition,
      compiled_definition: CompiledWorkflow.encode(prepared.compiled),
      compiler_version: prepared.compiled.compiler_version,
      required_scopes: prepared.dependencies.required_scopes,
      referenced_secret_ids: prepared.resolved.secret_ids,
      referenced_connection_ids: prepared.resolved.connection_ids,
      created_by_member_id: scope.member_id,
      activated_at: prepared.activated_at
    })
  end

  defp replace_bindings(repo, %{locked: workflow, version: version, prepared: prepared}) do
    _disabled = disable_bindings(repo, workflow)

    repo.delete_all(
      from binding in TriggerBinding, where: binding.workflow_version_id == ^version.id
    )

    prepared.definition.trigger
    |> TriggerBinding.project(workflow.installation_id, version.id)
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, acc} ->
      case repo.insert(TriggerBinding.changeset(%TriggerBinding{}, attrs)) do
        {:ok, binding} -> {:cont, {:ok, [binding | acc]}}
        {:error, changeset} -> {:halt, {:error, binding_error(changeset)}}
      end
    end)
  end

  defp replace_schedules(repo, %{locked: workflow, version: version, prepared: prepared}) do
    previous = enabled_schedule(repo, workflow)
    _disabled = disable_schedules(repo, workflow)

    case schedule_projection(
           prepared.definition.trigger,
           workflow,
           version,
           prepared.activated_at
         ) do
      :none ->
        {:ok, %{previous: previous, current: nil}}

      {:ok, attrs} ->
        case repo.insert(Schedule.changeset(%Schedule{}, attrs)) do
          {:ok, schedule} -> {:ok, %{previous: previous, current: schedule}}
          {:error, changeset} -> {:error, schedule_error(changeset)}
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp replace_webhooks(repo, %{locked: workflow, version: version, prepared: prepared}) do
    {:ok, disabled_count} = disable_webhooks(repo, workflow)

    case prepared.definition.trigger do
      %Trigger{type: :webhook, config: %WebhookConfig{} = config} ->
        create_webhook(repo, workflow, version, config, disabled_count)

      _other ->
        {:ok, %{disabled_count: disabled_count, endpoint: nil, credentials: nil}}
    end
  end

  defp create_webhook(repo, workflow, version, config, disabled_count) do
    token = WebhookEndpoint.generate_token()
    signing_secret = if config.require_signature, do: WebhookEndpoint.generate_signing_secret()

    attrs = %{
      installation_id: workflow.installation_id,
      workflow_id: workflow.id,
      workflow_version_id: version.id,
      public_id: WebhookEndpoint.generate_public_id(),
      token_digest: WebhookEndpoint.digest(token),
      enabled: true,
      require_signature: config.require_signature,
      signing_secret: signing_secret,
      signing_secret_key_version:
        if(config.require_signature, do: WebhookEndpoint.signing_secret_key_version())
    }

    case repo.insert(WebhookEndpoint.changeset(%WebhookEndpoint{}, attrs)) do
      {:ok, endpoint} ->
        {:ok,
         %{
           disabled_count: disabled_count,
           endpoint: endpoint,
           credentials: %{
             token: Base.url_encode64(token, padding: false),
             signing_secret: signing_secret
           }
         }}

      {:error, changeset} ->
        {:error, webhook_error(changeset)}
    end
  end

  defp disable_bindings(repo, %Workflow{} = workflow) do
    {count, _rows} =
      repo.update_all(
        from(binding in TriggerBinding,
          join: version in WorkflowVersion,
          on: version.id == binding.workflow_version_id,
          where:
            version.workflow_id == ^workflow.id and
              version.installation_id == ^workflow.installation_id and binding.enabled
        ),
        set: [enabled: false, updated_at: DateTime.utc_now()]
      )

    {:ok, count}
  end

  defp disable_schedules(repo, %Workflow{} = workflow) do
    {count, _rows} =
      repo.update_all(
        from(schedule in Schedule,
          where:
            schedule.workflow_id == ^workflow.id and
              schedule.installation_id == ^workflow.installation_id and schedule.enabled
        ),
        set: [enabled: false, updated_at: DateTime.utc_now()]
      )

    {:ok, count}
  end

  defp disable_webhooks(repo, %Workflow{} = workflow) do
    {count, _rows} =
      repo.update_all(
        from(endpoint in WebhookEndpoint,
          where:
            endpoint.workflow_id == ^workflow.id and
              endpoint.installation_id == ^workflow.installation_id and
              (endpoint.enabled or endpoint.signature_enabled)
        ),
        set: [enabled: false, signature_enabled: false, updated_at: DateTime.utc_now()]
      )

    {:ok, count}
  end

  defp enabled_schedule(repo, %Workflow{} = workflow) do
    repo.one(
      from schedule in Schedule,
        where:
          schedule.workflow_id == ^workflow.id and
            schedule.installation_id == ^workflow.installation_id and schedule.enabled
    )
  end

  defp schedule_projection(
         %Trigger{type: :schedule, config: %ScheduleConfig{} = config},
         workflow,
         version,
         activated_at
       ) do
    Schedule.projection_attrs(
      %{
        installation_id: workflow.installation_id,
        workflow_id: workflow.id,
        workflow_version_id: version.id
      },
      config,
      activated_at
    )
  end

  defp schedule_projection(_trigger, _workflow, _version, _activated_at), do: :none

  defp activation_changeset(scope, %{locked: workflow, version: version, prepared: prepared}) do
    attrs = %{
      status: "active",
      active_version_id: version.id,
      updated_by_member_id: scope.member_id
    }

    attrs =
      if prepared.bump_revision? do
        Map.put(attrs, :draft_revision, workflow.draft_revision + 1)
      else
        attrs
      end

    Workflow.changeset(workflow, attrs)
  end

  defp activation_audit(scope, changes) do
    workflow = Map.fetch!(changes, :workflow)

    %{
      installation_id: scope.installation_id,
      actor_type: "user",
      actor_id: scope.member_id,
      action: "workflow.activated",
      resource_type: "workflow",
      resource_id: workflow.id,
      metadata:
        %{
          "actor_role" => scope.role,
          "previous_state" => changes.locked.status,
          "next_state" => "active"
        }
        |> Map.merge(schedule_audit_metadata(Map.get(changes, :schedules)))
    }
  end

  defp schedule_audit_metadata(%{previous: previous, current: current}) do
    %{}
    |> maybe_put("timezone", current && current.timezone)
    |> maybe_put("previous_timezone", previous && previous.timezone)
    |> maybe_put("schedule_type", current && current.schedule_type)
    |> maybe_put("previous_schedule_type", previous && previous.schedule_type)
    |> maybe_put_changed_count(previous, current)
  end

  defp schedule_audit_metadata(_schedules), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_changed_count(map, %Schedule{} = previous, current) do
    Map.put(map, "changed_field_count", schedule_field_changes(previous, current))
  end

  defp maybe_put_changed_count(map, _previous, _current), do: map

  defp schedule_field_changes(_previous, nil), do: 1

  defp schedule_field_changes(previous, current) do
    [
      previous.timezone != current.timezone,
      previous.schedule_type != current.schedule_type,
      previous.config != current.config
    ]
    |> Enum.count(& &1)
  end

  defp deactivation_audit(scope, changes) do
    workflow = Map.fetch!(changes, :workflow)

    %{
      installation_id: scope.installation_id,
      actor_type: "user",
      actor_id: scope.member_id,
      action: "workflow.deactivated",
      resource_type: "workflow",
      resource_id: workflow.id,
      metadata: %{
        "actor_role" => scope.role,
        "previous_state" => changes.locked.status,
        "next_state" => "inactive"
      }
    }
  end

  ## Guards and errors

  defp refute_archived(%Workflow{archived_at: nil}), do: :ok

  defp refute_archived(%Workflow{}) do
    {:error,
     Error.new(:conflict, :already_archived, message: "That workflow is already archived.")}
  end

  defp refute_inactive(%Workflow{status: "active", active_version_id: version_id} = workflow)
       when not is_nil(version_id) do
    {:ok, workflow}
  end

  defp refute_inactive(%Workflow{id: id}) do
    {:error,
     Error.new(:conflict, :not_active,
       message: "That workflow is not running.",
       details: %{workflow_id: id}
     )}
  end

  defp require_active_quota(_repo, _installation, %Workflow{status: "active"}), do: :ok

  defp require_active_quota(repo, %Installation{} = installation, %Workflow{}) do
    limit = Limits.get(:active_workflows)

    count =
      repo.aggregate(
        from(workflow in Workflow,
          where: workflow.installation_id == ^installation.id and workflow.status == "active"
        ),
        :count
      )

    if count >= limit do
      Limits.record_hit(:active_workflows, installation.id)

      {:error,
       Error.new(:validation, :active_workflows_limit,
         message: "This workspace has too many active workflows."
       )}
    else
      :ok
    end
  end

  defp require_schedule_quota(
         repo,
         %Installation{} = installation,
         %Workflow{} = workflow,
         definition
       ) do
    if schedule_trigger?(definition) do
      limit = Limits.get(:schedules_per_workspace)

      count =
        repo.aggregate(
          from(schedule in Schedule,
            where:
              schedule.installation_id == ^installation.id and schedule.enabled and
                schedule.workflow_id != ^workflow.id
          ),
          :count
        )

      if count >= limit do
        Limits.record_hit(:schedules, installation.id)

        {:error,
         Error.new(:validation, :schedules_limit,
           message: "This workspace has too many schedules."
         )}
      else
        :ok
      end
    else
      :ok
    end
  end

  defp schedule_trigger?(%Definition{trigger: %Trigger{type: :schedule}}), do: true
  defp schedule_trigger?(_definition), do: false

  defp revision_conflict(expected, current) do
    Error.new(:conflict, :draft_revision_conflict,
      message: "The workflow draft changed since it was opened.",
      details: %{expected_revision: expected, current_revision: current}
    )
  end

  defp blocked(issues) do
    {:error,
     Error.new(:validation, :activation_blocked,
       message: "This workflow cannot be activated.",
       details: %{issues: ValidationIssue.sort(issues)}
     )}
  end

  defp binding_error(%Ecto.Changeset{} = changeset) do
    if violated?(changeset, "trigger_bindings_enabled_alias_index") do
      Error.new(:conflict, :alias_taken,
        message: "Another active workflow in this workspace already uses that name."
      )
    else
      Error.new(:validation, :invalid_trigger_binding,
        message: "The trigger binding could not be stored.",
        details: %{fields: Enum.map(changeset.errors, fn {field, _error} -> field end)}
      )
    end
  end

  defp schedule_error(%Ecto.Changeset{} = changeset) do
    Error.new(:validation, :invalid_schedule,
      message: "The schedule could not be stored.",
      details: %{fields: Enum.map(changeset.errors, fn {field, _error} -> field end)}
    )
  end

  defp webhook_error(%Ecto.Changeset{} = changeset) do
    Error.new(:validation, :invalid_webhook_endpoint,
      message: "The webhook endpoint could not be stored.",
      details: %{fields: Enum.map(changeset.errors, fn {field, _error} -> field end)}
    )
  end

  defp violated?(%Ecto.Changeset{errors: errors}, name) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint_name) == name
    end)
  end

  # A database exception inside the Multi (a trigger rejecting the audit row,
  # a constraint the changeset did not name) must not leak as a raise: the
  # savepoint has already been rolled back, and the caller is owed the same
  # typed error every other failure produces.
  defp transact(multi) do
    Repo.transaction(multi)
  rescue
    exception in Postgrex.Error ->
      {:error, :audit, exception, %{}}
  end

  defp finish_activation({:ok, changes}, scope) do
    {:ok,
     %{
       workflow: Map.fetch!(changes, :workflow),
       version: Map.fetch!(changes, :version),
       warnings: changes.prepared.warnings,
       webhook_credentials: revealed_webhook_credentials(changes.webhooks, scope)
     }}
  end

  defp finish_activation({:error, _step, %Error{} = error, _changes}, _scope),
    do: {:error, error}

  defp finish_activation({:error, :audit, _reason, _changes}, _scope) do
    {:error,
     Error.new(:internal, :audit_write_failed,
       message: "The change could not be recorded and was not applied."
     )}
  end

  defp finish_activation({:error, _step, %Ecto.Changeset{} = changeset, _changes}, _scope) do
    {:error,
     Error.new(:internal, :activation_write_failed,
       message: "The workflow could not be activated.",
       details: %{fields: Enum.map(changeset.errors, fn {field, _error} -> field end)}
     )}
  end

  defp finish_activation({:error, _step, reason, _changes}, _scope) do
    {:error,
     Error.new(:internal, :activation_write_failed,
       message: "The workflow could not be activated.",
       cause: reason
     )}
  end

  defp revealed_webhook_credentials(
         %{endpoint: %WebhookEndpoint{} = endpoint, credentials: credentials},
         scope
       ) do
    if Policy.can?(scope, :manage_credentials) do
      %{
        endpoint_id: endpoint.id,
        public_id: endpoint.public_id,
        url: Endpoints.public_url(endpoint.public_id),
        token: credentials.token,
        signing_secret: credentials.signing_secret,
        signature_header: WebhookService.signature_header()
      }
    end
  end

  defp revealed_webhook_credentials(_webhooks, _scope), do: nil

  defp finish_deactivation({:ok, changes}), do: {:ok, Map.fetch!(changes, :workflow)}
  defp finish_deactivation({:error, _step, %Error{} = error, _changes}), do: {:error, error}

  defp finish_deactivation({:error, :audit, _reason, _changes}) do
    {:error,
     Error.new(:internal, :audit_write_failed,
       message: "The change could not be recorded and was not applied."
     )}
  end

  defp finish_deactivation({:error, _step, reason, _changes}) do
    {:error,
     Error.new(:internal, :deactivation_write_failed,
       message: "The workflow could not be deactivated.",
       cause: reason
     )}
  end
end
