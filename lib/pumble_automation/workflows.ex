defmodule PumbleAutomation.Workflows do
  @moduledoc """
  The only supported way to read or change a workflow.

  Every public function takes a `PumbleAutomation.Scope` first, and there is no
  arity that omits it. That is the point of the module: a controller, a
  LiveView, a job, or a mix task that wants a workflow has to say who is asking
  and inside which workspace, and no caller outside this module builds an Ecto
  query against `workflows` or `workflow_versions`.

  ## A scope is an argument, not a filter applied afterwards

  The tenant is in the `WHERE` clause of every query, not checked against the
  row after it is loaded. A row belonging to another workspace is not fetched
  and then refused; it is never fetched. The distinction matters because the
  refusal is where information leaks, and there is nothing here to leak from.

  ## Another workspace's identifier does not exist

  Every read answers `PumbleAutomation.Installations.Policy.not_found/0` for an
  identifier from another workspace — the identical error, field for field,
  that a random UUID gets. A `:permission` error would confirm the row exists,
  which turns identifier guessing into an existence oracle. The capability
  check therefore runs *after* the tenant lookup for anything addressed by id,
  and before it for anything that creates.

  ## Which role may do what

    * `viewer` reads: `list_workflows/2`, `list_workflow_index/2`,
      `get_workflow/2`, `list_versions/2`, `get_version/3`.
    * `editor` changes: `create_workflow/2`, `duplicate_workflow/2`,
      `update_draft/4`, `archive_workflow/2`, `activate_workflow/3`,
      `reactivate_workflow/3`, `deactivate_workflow/2`.
    * `owner` destroys: `delete_workflow/2`, `delete_draft_workflow/2`.

  Those come from `PumbleAutomation.Installations.Policy`, which is the only
  module that turns a role into a permission.

  ## Security-sensitive changes are audited in their own transaction

  Creating, archiving, and deleting a workflow each write an audit row through
  `PumbleAutomation.Audit.Writer.append/3`, inside the same `Ecto.Multi` as the
  change. If the audit insert fails the change rolls back, so no workflow is
  ever created, archived, or deleted unaccountably.

  Saving a draft is deliberately not audited. A draft save is an editor
  keystroke, it happens hundreds of times per workflow, and its history is
  already carried by `draft_revision` and `updated_by_member_id`. Auditing it
  would drown the security record in editing noise. Activation is the
  security-sensitive write: it changes what runs, and it is audited inside
  the same transaction as the switch.

  ## `Service.as_multi/1` in the middle of a pipeline

  It is a Dialyzer shim and nothing else: `Ecto.Multi` keeps its step names in
  an opaque `MapSet`, and a literal `Multi.new()` leaks what is inside it.
  `PumbleAutomation.Installations.Service.as_multi/1` documents the whole story
  and is reused rather than copied.

  ## Activation is one transaction

  `activate_workflow/3`, `reactivate_workflow/3`, and `deactivate_workflow/2`
  delegate to `PumbleAutomation.Workflows.Activation`. That module owns the
  Multi: lock, validate, compile, version, project, point, audit. This module
  owns the scope check and the tenant lookup that every other workflow write
  goes through first.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias PumbleAutomation.Audit.Writer
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Concurrency
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Installations.Service
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.Limits
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows.Activation
  alias PumbleAutomation.Workflows.Clone
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Schedule
  alias PumbleAutomation.Workflows.StarterTemplates
  alias PumbleAutomation.Workflows.TriggerBinding
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomation.Workflows.WorkflowVersion

  @default_limit 50
  @max_limit 200

  @doc """
  Lists the scope's workflows, newest first.

  One query, no preloads, no association walk: the list screen shows columns
  this row already has, and adding a preload here would make the page cost grow
  with its length. `workflow_version_test.exs` and `context_test.exs` both
  assert the count.

  Options: `:limit` (at most #{@max_limit}), `:offset`, `:status`,
  `:q` (name/slug search), `:include_archived` (`false` by default).
  """
  @spec list_workflows(Scope.t(), keyword()) :: {:ok, [Workflow.t()]} | {:error, Error.t()}
  def list_workflows(%Scope{} = scope, opts \\ []) do
    with :ok <- Policy.authorize(scope, :read_workflows) do
      {:ok, Repo.all(list_query(scope, opts))}
    end
  end

  @doc """
  One page of workflow list rows, without draft or version documents.

  The list screen needs name, status, live version number, trigger summary,
  last execution, validation state, updater, and next schedule. Those come
  from joins and JSON path fragments, not from selecting `draft_definition`.
  Search, status, and pagination therefore do not grow with document size.

  Options match `list_workflows/2`. The return value is
  `%{entries: [map()], total: non_neg_integer()}`.
  """
  @spec list_workflow_index(Scope.t(), keyword()) ::
          {:ok, %{entries: [map()], total: non_neg_integer()}} | {:error, Error.t()}
  def list_workflow_index(%Scope{} = scope, opts \\ []) do
    with :ok <- Policy.authorize(scope, :read_workflows) do
      entries = Enum.map(Repo.all(index_query(scope, opts)), &decorate_index_row/1)
      total = Repo.one(index_count_query(scope, opts)) || 0
      {:ok, %{entries: entries, total: total}}
    end
  end

  @doc """
  The scope's workflow with `id`.

  A workflow belonging to another workspace answers exactly as a nonexistent
  one does. See the module documentation.
  """
  @spec get_workflow(Scope.t(), Ecto.UUID.t()) :: {:ok, Workflow.t()} | {:error, Error.t()}
  def get_workflow(%Scope{} = scope, id) do
    with :ok <- Policy.authorize(scope, :read_workflows) do
      fetch(scope, id)
    end
  end

  @doc """
  Creates a workflow and audits it in the same transaction.

  `attrs` carries `:name`, and optionally `:slug`, `:description`, and
  `:definition`. The tenant and the author come from the scope and cannot be
  overridden by the caller; a `:installation_id` in `attrs` is dropped. A
  definition, when present, is encoded through `Definition` before insert.
  """
  @spec create_workflow(Scope.t(), map()) :: {:ok, Workflow.t()} | {:error, Error.t()}
  def create_workflow(%Scope{} = scope, attrs) when is_map(attrs) do
    with :ok <- Policy.authorize(scope, :manage_workflows),
         {:ok, draft} <- optional_draft(attrs) do
      changeset =
        Workflow.changeset(%Workflow{}, %{
          installation_id: scope.installation_id,
          name: attr(attrs, :name),
          slug: blank_to_nil(attr(attrs, :slug)),
          description: blank_to_nil(attr(attrs, :description)),
          status: "draft",
          draft_definition: draft,
          created_by_member_id: scope.member_id,
          updated_by_member_id: scope.member_id
        })

      Multi.new()
      |> Service.as_multi()
      |> Multi.run(:installation, fn repo, _changes -> lock_installation(repo, scope) end)
      |> Multi.run(:quota, fn repo, _changes -> require_total_workflow_quota(repo, scope) end)
      |> Multi.insert(:workflow, changeset)
      |> audit(scope, "workflow.created", :workflow)
      |> commit(:workflow)
    end
  end

  @doc """
  Creates a new draft copied from `id`, with new workflow, trigger, and node ids.

  Version rows, bindings, and schedules stay on the source. A source with no
  draft receives the blank starter definition.
  """
  @spec duplicate_workflow(Scope.t(), Ecto.UUID.t()) :: {:ok, Workflow.t()} | {:error, Error.t()}
  def duplicate_workflow(%Scope{} = scope, id) do
    with {:ok, source} <- fetch(scope, id),
         :ok <- Policy.authorize(scope, :manage_workflows),
         {:ok, definition} <- clone_definition(source) do
      create_workflow(scope, %{
        name: copy_name(source.name),
        slug: copy_slug(source.slug),
        description: source.description,
        definition: definition
      })
    end
  end

  @doc """
  Saves a draft, refusing to overwrite somebody else's work.

  Delegates the compare-and-swap to `PumbleAutomation.Workflows.Workflow.save_draft/4`,
  which is the only writer of the draft columns. A stale `expected_revision`
  returns a `:conflict` error carrying the revision the row actually holds.
  """
  @spec update_draft(Scope.t(), Ecto.UUID.t(), Definition.t() | map(), non_neg_integer()) ::
          {:ok, Workflow.t()} | {:error, Error.t()}
  def update_draft(%Scope{} = scope, id, definition, expected_revision)
      when is_integer(expected_revision) and expected_revision >= 0 do
    with {:ok, workflow} <- fetch(scope, id),
         :ok <- Policy.authorize(scope, :manage_workflows) do
      Workflow.save_draft(workflow, definition, expected_revision,
        updated_by_member_id: scope.member_id
      )
    end
  end

  @doc """
  Archives a workflow, and audits it in the same transaction.

  Archiving is reversible bookkeeping, not deletion: the row and its versions
  stay, so an execution that already named a version still resolves. An
  already-archived workflow is a `:conflict`, not a silent success.
  """
  @spec archive_workflow(Scope.t(), Ecto.UUID.t()) :: {:ok, Workflow.t()} | {:error, Error.t()}
  def archive_workflow(%Scope{} = scope, id) do
    with {:ok, workflow} <- fetch(scope, id),
         :ok <- Policy.authorize(scope, :manage_workflows),
         :ok <- refute_archived(workflow) do
      changeset =
        Workflow.changeset(workflow, %{
          status: "archived",
          archived_at: DateTime.utc_now(),
          updated_by_member_id: scope.member_id
        })

      Multi.new()
      |> Service.as_multi()
      |> Multi.update(:workflow, changeset)
      |> audit(scope, "workflow.archived", :workflow, %{
        "previous_state" => workflow.status,
        "next_state" => "archived"
      })
      |> commit(:workflow)
    end
  end

  @doc """
  Deletes a workflow and everything hanging off it, and audits it first.

  This is `owner` work, because it removes the versions that executions name
  and is not reversible. `archive_workflow/2` is what an editor reaches for.
  """
  @spec delete_workflow(Scope.t(), Ecto.UUID.t()) :: {:ok, Workflow.t()} | {:error, Error.t()}
  def delete_workflow(%Scope{} = scope, id) do
    with {:ok, workflow} <- fetch(scope, id),
         :ok <- Policy.authorize(scope, :destructive_lifecycle) do
      purge(scope, workflow)
    end
  end

  @doc """
  Deletes a draft that has never been activated.

  Active, inactive, and archived workflows are a `:not_a_draft` conflict.
  Occupying executions cannot exist on a never-activated draft; if the row
  is no longer a draft, this refuses rather than cascading those runs away.
  """
  @spec delete_draft_workflow(Scope.t(), Ecto.UUID.t()) ::
          {:ok, Workflow.t()} | {:error, Error.t()}
  def delete_draft_workflow(%Scope{} = scope, id) do
    with {:ok, workflow} <- fetch(scope, id),
         :ok <- Policy.authorize(scope, :destructive_lifecycle),
         :ok <- ensure_deletable_draft(workflow) do
      purge(scope, workflow)
    end
  end

  @doc """
  Compiles the current draft and makes it the running program.

  `expected_revision` is compare-and-swap against `draft_revision`. Two
  activations that observed the same draft produce one winner; the other
  receives a `:draft_revision_conflict`. Warnings do not stop it. Any error
  from validation, compilation, or current dependencies rolls the whole
  switch back.
  """
  @spec activate_workflow(Scope.t(), Ecto.UUID.t(), non_neg_integer()) ::
          {:ok, Activation.result()} | {:error, Error.t()}
  def activate_workflow(%Scope{} = scope, id, expected_revision)
      when is_integer(expected_revision) and expected_revision >= 0 do
    with {:ok, _workflow} <- fetch(scope, id),
         :ok <- Policy.authorize(scope, :activate_workflows) do
      Activation.activate(scope, id, expected_revision)
    end
  end

  @doc """
  Makes a previously stored immutable version the running program.

  The version row is not rewritten. Current installation scopes, secrets, and
  connections are checked before the live pointer moves.
  """
  @spec reactivate_workflow(Scope.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, Activation.result()} | {:error, Error.t()}
  def reactivate_workflow(%Scope{} = scope, id, version_number)
      when is_integer(version_number) and version_number >= 1 do
    with {:ok, _workflow} <- fetch(scope, id),
         :ok <- Policy.authorize(scope, :activate_workflows) do
      Activation.reactivate(scope, id, version_number)
    end
  end

  @doc """
  Stops a workflow from starting new executions.

  Disables trigger bindings and schedules, clears the live version pointer,
  and audits the change in one transaction. In-flight executions are not
  cancelled. A workflow that is not running is a `:not_active` conflict.
  """
  @spec deactivate_workflow(Scope.t(), Ecto.UUID.t()) ::
          {:ok, Workflow.t()} | {:error, Error.t()}
  def deactivate_workflow(%Scope{} = scope, id) do
    with {:ok, _workflow} <- fetch(scope, id),
         :ok <- Policy.authorize(scope, :activate_workflows) do
      Activation.deactivate(scope, id)
    end
  end

  @doc """
  The version history of one workflow, newest version first.

  Source and compiled definitions are omitted: a history list shows numbers,
  hashes, and times, and shipping two JSON documents per row for a screen that
  renders none of them is the same mistake as an unnecessary preload. Use
  `get_version/3` for the content of one version.
  """
  @spec list_versions(Scope.t(), Ecto.UUID.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_versions(%Scope{} = scope, workflow_id) do
    with :ok <- Policy.authorize(scope, :read_workflows),
         {:ok, workflow} <- fetch(scope, workflow_id) do
      query =
        from v in WorkflowVersion,
          where: v.installation_id == ^scope.installation_id and v.workflow_id == ^workflow.id,
          order_by: [desc: v.version_number],
          select: %{
            id: v.id,
            version_number: v.version_number,
            definition_hash: v.definition_hash,
            compiler_version: v.compiler_version,
            required_scopes: v.required_scopes,
            created_by_member_id: v.created_by_member_id,
            activated_at: v.activated_at,
            inserted_at: v.inserted_at
          }

      {:ok, Repo.all(query)}
    end
  end

  @doc "One version of one workflow, addressed by its number inside that workflow."
  @spec get_version(Scope.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, WorkflowVersion.t()} | {:error, Error.t()}
  def get_version(%Scope{} = scope, workflow_id, version_number)
      when is_integer(version_number) and version_number >= 1 do
    with :ok <- Policy.authorize(scope, :read_workflows),
         {:ok, workflow} <- fetch(scope, workflow_id) do
      query =
        from v in WorkflowVersion,
          where:
            v.installation_id == ^scope.installation_id and v.workflow_id == ^workflow.id and
              v.version_number == ^version_number

      case Repo.one(query) do
        nil -> {:error, Policy.not_found()}
        version -> {:ok, version}
      end
    end
  end

  defp list_query(%Scope{} = scope, opts) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit) |> max(1)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    from(w in filtered_workflows(scope, opts),
      order_by: [desc: w.inserted_at, desc: w.id],
      limit: ^limit,
      offset: ^offset
    )
  end

  defp index_query(%Scope{} = scope, opts) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit) |> max(1)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)
    occupying = Concurrency.occupying_statuses()

    from(w in filtered_workflows(scope, opts),
      left_join: version in WorkflowVersion,
      on: version.id == w.active_version_id and version.installation_id == w.installation_id,
      left_join: member in WorkspaceMember,
      on: member.id == w.updated_by_member_id and member.installation_id == w.installation_id,
      left_join: last in subquery(last_executions(scope)),
      on: last.workflow_id == w.id,
      left_join: occupying_row in subquery(occupying_counts(scope, occupying)),
      on: occupying_row.workflow_id == w.id,
      left_join: schedule in Schedule,
      on:
        schedule.workflow_id == w.id and schedule.installation_id == w.installation_id and
          schedule.enabled == true,
      left_join: binding in subquery(binding_summaries(scope)),
      on: binding.workflow_version_id == w.active_version_id,
      order_by: [desc: w.inserted_at, desc: w.id],
      limit: ^limit,
      offset: ^offset,
      select: %{
        id: w.id,
        name: w.name,
        status: w.status,
        slug: w.slug,
        active_version_number: version.version_number,
        binding_kind: binding.kind,
        binding_type: binding.type,
        binding_alias: binding.alias,
        draft_trigger_type: fragment("? #>> '{trigger,type}'", w.draft_definition),
        draft_event: fragment("? #>> '{trigger,config,event}'", w.draft_definition),
        draft_schedule_type:
          fragment("? #>> '{trigger,config,schedule_type}'", w.draft_definition),
        draft_alias: fragment("? #>> '{trigger,config,manual_alias}'", w.draft_definition),
        last_execution_status: last.status,
        last_execution_at: last.at,
        occupying_count: fragment("coalesce(?, 0)", occupying_row.count),
        has_draft: fragment("? IS NOT NULL", w.draft_definition),
        updated_at: w.updated_at,
        updated_by_label:
          fragment(
            "coalesce(nullif(?->>'name', ''), nullif(?->>'display_name', ''), ?)",
            member.profile_snapshot,
            member.profile_snapshot,
            member.pumble_user_id
          ),
        next_run_at: schedule.next_run_at
      }
    )
  end

  defp index_count_query(%Scope{} = scope, opts) do
    from(w in filtered_workflows(scope, opts), select: count(w.id))
  end

  defp filtered_workflows(%Scope{} = scope, opts) do
    from(w in Workflow, where: w.installation_id == ^scope.installation_id)
    |> filter_status(Keyword.get(opts, :status))
    |> filter_archived(Keyword.get(opts, :include_archived, false))
    |> filter_search(Keyword.get(opts, :q))
  end

  defp last_executions(%Scope{} = scope) do
    from(e in Execution,
      where: e.installation_id == ^scope.installation_id,
      distinct: e.workflow_id,
      order_by: [asc: e.workflow_id, desc: e.inserted_at],
      select: %{workflow_id: e.workflow_id, status: e.status, at: e.inserted_at}
    )
  end

  defp occupying_counts(%Scope{} = scope, occupying) do
    from(e in Execution,
      where: e.installation_id == ^scope.installation_id and e.status in ^occupying,
      group_by: e.workflow_id,
      select: %{workflow_id: e.workflow_id, count: count(e.id)}
    )
  end

  defp binding_summaries(%Scope{} = scope) do
    from(b in TriggerBinding,
      where: b.installation_id == ^scope.installation_id and b.enabled == true,
      group_by: b.workflow_version_id,
      select: %{
        workflow_version_id: b.workflow_version_id,
        kind: min(b.kind),
        type: min(b.type),
        alias: min(b.alias)
      }
    )
  end

  defp filter_status(query, nil), do: query
  defp filter_status(query, ""), do: query
  defp filter_status(query, status), do: from(w in query, where: w.status == ^status)

  defp filter_archived(query, true), do: query
  defp filter_archived(query, _false), do: from(w in query, where: is_nil(w.archived_at))

  defp filter_search(query, q) when is_binary(q) do
    trimmed = String.trim(q)

    if trimmed == "" do
      query
    else
      pattern = "%" <> escape_like(trimmed) <> "%"

      from(w in query,
        where:
          fragment("? ILIKE ? ESCAPE ?", w.name, ^pattern, "\\") or
            fragment("coalesce(?, '') ILIKE ? ESCAPE ?", w.slug, ^pattern, "\\")
      )
    end
  end

  defp filter_search(query, _q), do: query

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp decorate_index_row(row) do
    row
    |> Map.put(:trigger_summary, trigger_summary(row))
    |> Map.put(:validation_state, validation_state(row))
    |> Map.update!(:occupying_count, &occupying_count/1)
  end

  defp occupying_count(count) when is_integer(count) and count >= 0, do: count
  defp occupying_count(_count), do: 0

  defp trigger_summary(row) do
    kind = row.binding_kind || row.draft_trigger_type
    type = row.binding_type || row.draft_event || row.draft_schedule_type
    alias_name = row.binding_alias || row.draft_alias
    format_trigger(kind, type, alias_name)
  end

  defp format_trigger(nil, _type, _alias_name), do: "—"
  defp format_trigger("pumble_event", type, _alias_name), do: "Pumble · " <> event_label(type)

  defp format_trigger("manual", _type, alias_name)
       when is_binary(alias_name) and alias_name != "",
       do: "Manual · " <> alias_name

  defp format_trigger("manual", _type, _alias_name), do: "Manual"
  defp format_trigger("schedule", type, _alias_name), do: "Schedule · " <> schedule_label(type)
  defp format_trigger("webhook", _type, _alias_name), do: "Webhook"
  defp format_trigger("manual_test", _type, _alias_name), do: "Test"
  defp format_trigger(kind, _type, _alias_name) when is_binary(kind), do: kind
  defp format_trigger(_kind, _type, _alias_name), do: "—"

  defp event_label("NEW_MESSAGE"), do: "New message"
  defp event_label("UPDATED_MESSAGE"), do: "Updated message"
  defp event_label("REACTION_ADDED"), do: "Reaction added"
  defp event_label("CHANNEL_CREATED"), do: "Channel created"
  defp event_label("WORKSPACE_USER_JOINED"), do: "Member joined"
  defp event_label(other) when is_binary(other), do: other
  defp event_label(_other), do: "Event"

  defp schedule_label("daily"), do: "Daily"
  defp schedule_label("weekly"), do: "Weekly"
  defp schedule_label("once"), do: "Once"
  defp schedule_label("every_minutes"), do: "Interval"
  defp schedule_label("every_hours"), do: "Interval"
  defp schedule_label(other) when is_binary(other), do: other
  defp schedule_label(_other), do: "Clock"

  defp validation_state(%{status: "active"}), do: "live"
  defp validation_state(%{has_draft: true}), do: "draft"
  defp validation_state(_row), do: "empty"

  defp optional_draft(attrs) do
    case attr(attrs, :definition) do
      nil ->
        {:ok, nil}

      %Definition{} = definition ->
        {:ok, Definition.encode(definition)}

      raw when is_map(raw) ->
        case Definition.decode(raw) do
          {:ok, definition} -> {:ok, Definition.encode(definition)}
          {:error, %Error{}} = error -> error
        end

      _other ->
        {:error,
         Error.new(:validation, :invalid_definition,
           message: "The workflow definition is not valid."
         )}
    end
  end

  defp clone_definition(source) do
    case Workflow.draft(source) do
      {:ok, definition} -> {:ok, Clone.definition(definition)}
      {:error, %Error{code: :draft_not_found}} -> {:ok, StarterTemplates.blank()}
      {:error, %Error{}} = error -> error
    end
  end

  defp copy_name(name) when is_binary(name) do
    String.slice("Copy of " <> name, 0, Workflow.name_max())
  end

  defp copy_slug(nil), do: nil

  defp copy_slug(slug) when is_binary(slug) do
    suffix = "-copy-#{System.unique_integer([:positive])}"
    base_len = max(1, Workflow.slug_max() - String.length(suffix))
    String.slice(slug, 0, base_len) <> suffix
  end

  defp attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(other), do: other

  defp purge(%Scope{} = scope, %Workflow{} = workflow) do
    Multi.new()
    |> Service.as_multi()
    |> Multi.delete(:workflow, workflow)
    |> audit(scope, "workflow.deleted", :workflow, %{"previous_state" => workflow.status})
    |> commit(:workflow)
  end

  defp ensure_deletable_draft(%Workflow{status: "draft", active_version_id: nil}), do: :ok

  defp ensure_deletable_draft(%Workflow{}) do
    {:error,
     Error.new(:conflict, :not_a_draft,
       message: "Only a draft that has never been activated can be deleted."
     )}
  end

  # Every read of one workflow goes through here, so the tenant predicate is
  # written once and the not-found answer is the same one everywhere.
  defp fetch(%Scope{} = scope, id) do
    if valid_uuid?(id) do
      query =
        from w in Workflow,
          where: w.id == ^id and w.installation_id == ^scope.installation_id

      case Repo.one(query) do
        nil -> Scope.refuse_unknown(Workflow, id, scope.installation_id, :workflows)
        workflow -> {:ok, workflow}
      end
    else
      {:error, Policy.not_found()}
    end
  end

  # A malformed identifier is not a database error to surface; it is an
  # identifier that names nothing, and it answers exactly like one.
  defp valid_uuid?(id) when is_binary(id), do: match?({:ok, _uuid}, Ecto.UUID.cast(id))
  defp valid_uuid?(_id), do: false

  defp refute_archived(%Workflow{archived_at: nil}), do: :ok

  defp refute_archived(%Workflow{}) do
    {:error,
     Error.new(:conflict, :already_archived, message: "That workflow is already archived.")}
  end

  defp audit(multi, %Scope{} = scope, action, step, metadata \\ %{}) do
    Writer.append(multi, :audit, fn changes ->
      workflow = Map.fetch!(changes, step)

      %{
        installation_id: scope.installation_id,
        actor_type: "user",
        actor_id: scope.member_id,
        action: action,
        resource_type: "workflow",
        resource_id: workflow.id,
        metadata: Map.put(metadata, "actor_role", scope.role)
      }
    end)
  end

  defp lock_installation(repo, %Scope{installation_id: installation_id}) do
    query =
      from installation in Installation,
        where: installation.id == ^installation_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      %Installation{} = installation -> {:ok, installation}
      nil -> {:error, Policy.not_found()}
    end
  end

  defp require_total_workflow_quota(repo, %Scope{installation_id: installation_id}) do
    limit = Limits.get(:total_workflows)

    count =
      repo.aggregate(
        from(workflow in Workflow, where: workflow.installation_id == ^installation_id),
        :count
      )

    if count >= limit do
      Limits.record_hit(:total_workflows, installation_id)

      {:error,
       Error.new(:validation, :total_workflows_limit,
         message: "This workspace has too many workflows."
       )}
    else
      {:ok, count}
    end
  end

  defp commit(multi, step) do
    case Repo.transaction(multi) do
      {:ok, changes} ->
        {:ok, Map.fetch!(changes, step)}

      {:error, _step, %Ecto.Changeset{} = changeset, _done} ->
        {:error, changeset_error(changeset)}

      {:error, _step, %Error{} = error, _done} ->
        {:error, error}

      {:error, _step, reason, _done} ->
        {:error, unexpected(reason)}
    end
  end

  defp changeset_error(%Ecto.Changeset{data: %Workflow{}} = changeset) do
    if Keyword.has_key?(changeset.errors, :slug) do
      Error.new(:conflict, :slug_taken,
        message: "Another workflow in this workspace already uses that name."
      )
    else
      Error.new(:validation, :invalid_workflow,
        message: "The workflow is not valid.",
        details: %{fields: Enum.map(changeset.errors, fn {field, _error} -> field end)}
      )
    end
  end

  defp changeset_error(%Ecto.Changeset{} = changeset) do
    Error.new(:internal, :audit_write_failed,
      message: "The change could not be recorded and was not applied.",
      details: %{fields: Enum.map(changeset.errors, fn {field, _error} -> field end)}
    )
  end

  defp unexpected(reason) do
    Error.new(:internal, :workflow_write_failed,
      message: "The change could not be applied.",
      cause: reason
    )
  end
end
