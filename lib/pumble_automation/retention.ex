defmodule PumbleAutomation.Retention do
  @moduledoc """
  Time-based retention sweeps and the uninstalled-tenant purge.

  Default windows:

    * receipt detail — 30 days (`received_events.retain_until`)
    * execution detail — 90 days after last write, terminal rows only
    * audit — 365 days
    * expired or consumed OAuth states, and expired or revoked sessions — promptly
    * uninstalled tenant — 30-day grace, then a tenant-scoped purge

  Credentials and Pumble/user token ciphertext are already removed on uninstall
  by `PumbleAutomation.Installations.Lifecycle`. This module does not add a
  second credential wipe.

  ## No legal hold, no aggregate leftovers

  Product policy does not implement legal or support holds, so none are
  modelled. Aggregate counters of deleted tenant data are not stored. Sweep
  telemetry carries counts, a tenant id when one exists, and a correlation id.

  ## Batches, tenants, restart

  Every delete is `LIMIT`ed, indexed, and scoped to one installation when the
  table has that column. A job that dies after a committed batch leaves the
  remaining due rows in place; the next run continues from what is left.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Audit.Writer
  alias PumbleAutomation.Connections.Connection
  alias PumbleAutomation.Connections.Secret
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.Ingress.WebhookEndpoint
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.OauthState
  alias PumbleAutomation.Installations.Service
  alias PumbleAutomation.Installations.Sessions
  alias PumbleAutomation.Installations.UserAuthorization
  alias PumbleAutomation.Installations.UserSession
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Workflows.Schedule
  alias PumbleAutomation.Workflows.TriggerBinding
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomation.Workflows.WorkflowVersion

  @telemetry_event [:pumble_automation, :retention]
  @last_run_key {__MODULE__, :last_run}

  @receipts_days 30
  @execution_detail_days 90
  @audit_days 365
  @uninstall_grace_days 30

  @batch_size 500

  @terminal_statuses ~w(completed failed cancelled)
  @protected_statuses ~w(queued running waiting_delay waiting_approval paused_uncertain)

  @type counts :: %{
          receipts: non_neg_integer(),
          executions: non_neg_integer(),
          audit_events: non_neg_integer(),
          oauth_states: non_neg_integer(),
          sessions: non_neg_integer(),
          tenant_rows: non_neg_integer()
        }

  @type status :: %{
          last_run_at: DateTime.t() | nil,
          last_kind: atom() | nil,
          last_counts: map() | nil,
          last_correlation_id: String.t() | nil,
          last_installation_id: Ecto.UUID.t() | nil,
          policy: map()
        }

  @doc "Canonical retention windows in days."
  @spec policy() :: %{
          receipts_days: pos_integer(),
          execution_detail_days: pos_integer(),
          audit_days: pos_integer(),
          uninstall_grace_days: pos_integer()
        }
  def policy do
    %{
      receipts_days: @receipts_days,
      execution_detail_days: @execution_detail_days,
      audit_days: @audit_days,
      uninstall_grace_days: @uninstall_grace_days
    }
  end

  @doc "How many days receipt detail is kept."
  @spec receipts_days() :: pos_integer()
  def receipts_days, do: @receipts_days

  @doc "How many days terminal execution detail is kept."
  @spec execution_detail_days() :: pos_integer()
  def execution_detail_days, do: @execution_detail_days

  @doc "How many days audit rows are kept."
  @spec audit_days() :: pos_integer()
  def audit_days, do: @audit_days

  @doc "How many days an uninstalled tenant's remaining data is kept."
  @spec uninstall_grace_days() :: pos_integer()
  def uninstall_grace_days, do: @uninstall_grace_days

  @doc "How many rows one delete statement removes."
  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch_size

  @doc "Telemetry prefix for sweep and tenant-purge events."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  @doc "Statuses that retention must not delete while the tenant is live."
  @spec protected_statuses() :: [String.t()]
  def protected_statuses, do: @protected_statuses

  @doc "Terminal statuses whose rows may age out after `execution_detail_days/0`."
  @spec terminal_statuses() :: [String.t()]
  def terminal_statuses, do: @terminal_statuses

  @doc """
  Last sweep or tenant-purge summary recorded on this node.

  The record is in-memory (`:persistent_term`). A restart forgets it until the
  next run. Counts and identifiers only; no deleted content.
  """
  @spec status() :: status()
  def status do
    last = :persistent_term.get(@last_run_key, %{})

    %{
      last_run_at: Map.get(last, :at),
      last_kind: Map.get(last, :kind),
      last_counts: Map.get(last, :counts),
      last_correlation_id: Map.get(last, :correlation_id),
      last_installation_id: Map.get(last, :installation_id),
      policy: policy()
    }
  end

  @doc """
  Receipts whose retention date is strictly before `now`.

  Optional `:installation_id` scopes the predicate to one tenant. The
  unscoped form is what `received_events_retain_until_index` was built for.
  """
  @spec due_receipts_query(DateTime.t(), keyword()) :: Ecto.Query.t()
  def due_receipts_query(%DateTime{} = now, opts \\ []) do
    query = ReceivedEvent.due_for_retention(now)

    case Keyword.get(opts, :installation_id) do
      nil -> query
      installation_id -> from e in query, where: e.installation_id == ^installation_id
    end
  end

  @doc """
  Terminal executions last written strictly before the 90-day cutoff.

  Descendants pin their root: a due root is kept until every child is gone, so
  a CASCADE on `root_execution_id` cannot remove a newer or still-active run.
  Occupying and queued rows are never selected.
  """
  @spec due_executions_query(DateTime.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def due_executions_query(%DateTime{} = now, installation_id) when is_binary(installation_id) do
    cutoff = DateTime.add(now, -@execution_detail_days, :day)

    from execution in Execution,
      as: :execution,
      where: execution.installation_id == ^installation_id,
      where: execution.status in ^@terminal_statuses,
      where: execution.updated_at < ^cutoff,
      where:
        not exists(
          from child in Execution,
            where: child.root_execution_id == parent_as(:execution).id
        )
  end

  @doc "Audit rows inserted strictly before the 365-day cutoff, one tenant or pre-install."
  @spec due_audit_query(DateTime.t(), Ecto.UUID.t() | nil) :: Ecto.Query.t()
  def due_audit_query(%DateTime{} = now, installation_id) do
    cutoff = DateTime.add(now, -@audit_days, :day)

    query = from event in AuditEvent, where: event.inserted_at < ^cutoff

    case installation_id do
      nil -> from event in query, where: is_nil(event.installation_id)
      id -> from event in query, where: event.installation_id == ^id
    end
  end

  @doc """
  Deletes due receipt, execution, audit, OAuth, and session rows as of `now`.

  Options: `:batch_size`, `:max_batches`, `:correlation_id`.
  """
  @spec sweep(DateTime.t(), keyword()) :: {:ok, counts()}
  def sweep(%DateTime{} = now, opts \\ []) do
    correlation_id = Keyword.get_lazy(opts, :correlation_id, &Ecto.UUID.generate/0)
    counts = empty_counts()

    counts =
      counts
      |> sweep_receipts(now, opts)
      |> sweep_executions(now, opts)
      |> sweep_audit(now, opts)
      |> sweep_oauth(now, opts)
      |> sweep_sessions(now, opts)

    record_run(%{
      at: DateTime.utc_now(),
      kind: :sweep,
      counts: counts,
      correlation_id: correlation_id,
      installation_id: nil
    })

    emit(:sweep, counts, correlation_id, nil)

    Logger.info(
      "retention: sweep completed correlation_id=#{correlation_id} receipts=#{counts.receipts} executions=#{counts.executions} audit_events=#{counts.audit_events} oauth_states=#{counts.oauth_states} sessions=#{counts.sessions}"
    )

    {:ok, counts}
  end

  @doc """
  Whether any receipt, execution, audit, OAuth, or session row is still due.

  The next sweep continues from what is left. Used so a time-budgeted job can
  snooze instead of claiming the table is clean.
  """
  @spec more_due?(DateTime.t()) :: boolean()
  def more_due?(%DateTime{} = now) do
    receipts_due?(now) or executions_due?(now) or audit_due?(now) or oauth_due?(now) or
      sessions_due?(now)
  end

  @doc """
  Deletes one uninstalled tenant's remaining rows and marks it `deleted`.

  Exposed so tests and `RetentionWorker` can run the purge without the queue.
  Every statement is tenant-scoped. The installation row stays so audit history
  can still name the workspace until the 365-day audit window elapses.
  """
  @spec purge_tenant(Installation.t(), keyword()) :: {:ok, Installation.t()} | {:error, term()}
  def purge_tenant(%Installation{id: installation_id} = installation, opts \\ []) do
    correlation_id = Keyword.get_lazy(opts, :correlation_id, &Ecto.UUID.generate/0)
    batch_opts = Keyword.take(opts, [:batch_size, :max_batches])

    counts = %{
      sessions: purge_batches(UserSession, session_scope(installation_id), batch_opts),
      executions:
        purge_batches(
          Execution,
          from(e in Execution, where: e.installation_id == ^installation_id),
          batch_opts
        ),
      receipts:
        purge_batches(
          ReceivedEvent,
          from(e in ReceivedEvent, where: e.installation_id == ^installation_id),
          batch_opts
        ),
      webhook_endpoints:
        purge_batches(
          WebhookEndpoint,
          from(e in WebhookEndpoint, where: e.installation_id == ^installation_id),
          batch_opts
        ),
      schedules:
        purge_batches(
          Schedule,
          from(s in Schedule, where: s.installation_id == ^installation_id),
          batch_opts
        ),
      trigger_bindings:
        purge_batches(
          TriggerBinding,
          from(b in TriggerBinding, where: b.installation_id == ^installation_id),
          batch_opts
        )
    }

    {_, _} =
      Repo.update_all(
        from(w in Workflow, where: w.installation_id == ^installation_id),
        set: [active_version_id: nil]
      )

    counts =
      Map.merge(counts, %{
        workflow_versions:
          purge_batches(
            WorkflowVersion,
            from(v in WorkflowVersion, where: v.installation_id == ^installation_id),
            batch_opts
          ),
        workflows:
          purge_batches(
            Workflow,
            from(w in Workflow, where: w.installation_id == ^installation_id),
            batch_opts
          ),
        connections:
          purge_batches(
            Connection,
            from(c in Connection, where: c.installation_id == ^installation_id),
            batch_opts
          ),
        secrets:
          purge_batches(
            Secret,
            from(s in Secret, where: s.installation_id == ^installation_id),
            batch_opts
          ),
        authorizations:
          purge_batches(
            UserAuthorization,
            from(a in UserAuthorization, where: a.installation_id == ^installation_id),
            batch_opts
          ),
        members:
          purge_batches(
            WorkspaceMember,
            from(m in WorkspaceMember, where: m.installation_id == ^installation_id),
            batch_opts
          ),
        oauth_states:
          purge_batches(
            OauthState,
            from(s in OauthState, where: s.installation_id == ^installation_id),
            batch_opts
          )
      })

    tenant_rows = counts |> Map.values() |> Enum.sum()

    case mark_deleted(installation) do
      {:ok, deleted} ->
        summary = Map.put(empty_counts(), :tenant_rows, tenant_rows)

        record_run(%{
          at: DateTime.utc_now(),
          kind: :tenant_purge,
          counts: summary,
          correlation_id: correlation_id,
          installation_id: installation_id
        })

        emit(:tenant_purge, summary, correlation_id, installation_id)

        Logger.info(
          "retention: tenant purge completed correlation_id=#{correlation_id} installation_id=#{installation_id} count=#{tenant_rows}"
        )

        {:ok, deleted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sweep_receipts(counts, now, opts) do
    ids = due_tenant_ids(from(e in ReceivedEvent, where: e.retain_until < ^now))

    deleted =
      Enum.reduce(ids, 0, fn installation_id, acc ->
        acc +
          purge_batches(
            ReceivedEvent,
            due_receipts_query(now, installation_id: installation_id),
            opts
          )
      end)

    %{counts | receipts: counts.receipts + deleted}
  end

  defp sweep_executions(counts, now, opts) do
    cutoff = DateTime.add(now, -@execution_detail_days, :day)

    ids =
      due_tenant_ids(
        from e in Execution,
          where: e.status in ^@terminal_statuses and e.updated_at < ^cutoff
      )

    deleted =
      Enum.reduce(ids, 0, fn installation_id, acc ->
        acc + purge_batches(Execution, due_executions_query(now, installation_id), opts)
      end)

    %{counts | executions: counts.executions + deleted}
  end

  defp sweep_audit(counts, now, opts) do
    cutoff = DateTime.add(now, -@audit_days, :day)

    tenant_ids =
      due_tenant_ids(
        from e in AuditEvent, where: e.inserted_at < ^cutoff and not is_nil(e.installation_id)
      )

    deleted_tenants =
      Enum.reduce(tenant_ids, 0, fn installation_id, acc ->
        acc + purge_batches(AuditEvent, due_audit_query(now, installation_id), opts)
      end)

    deleted_preinstall = purge_batches(AuditEvent, due_audit_query(now, nil), opts)

    %{counts | audit_events: counts.audit_events + deleted_tenants + deleted_preinstall}
  end

  defp sweep_oauth(counts, now, opts) do
    consumed =
      purge_batches(
        OauthState,
        from(s in OauthState, where: not is_nil(s.consumed_at)),
        opts
      )

    expired =
      purge_batches(
        OauthState,
        from(s in OauthState, where: is_nil(s.consumed_at) and s.expires_at < ^now),
        opts
      )

    %{counts | oauth_states: counts.oauth_states + consumed + expired}
  end

  defp sweep_sessions(counts, now, opts) do
    revoked =
      purge_batches(
        UserSession,
        from(s in UserSession, where: not is_nil(s.revoked_at)),
        opts
      )

    idle =
      purge_batches(
        UserSession,
        from(s in UserSession, where: is_nil(s.revoked_at) and s.idle_expires_at < ^now),
        opts
      )

    absolute =
      purge_batches(
        UserSession,
        from(s in UserSession, where: is_nil(s.revoked_at) and s.absolute_expires_at < ^now),
        opts
      )

    %{counts | sessions: counts.sessions + revoked + idle + absolute}
  end

  defp due_tenant_ids(query) do
    Repo.all(from row in query, distinct: true, select: row.installation_id)
  end

  defp session_scope(installation_id) do
    from session in UserSession,
      where: session.workspace_member_id in subquery(Sessions.member_ids(installation_id))
  end

  # `IN (SELECT ... LIMIT n)` bounds one statement. Repeating until a statement
  # deletes less than a full batch is what makes the purge resumable: every
  # iteration is committed before the next one starts.
  defp purge_batches(schema, scope, opts, acc \\ 0, batches \\ 0) do
    if continue?(batches, Keyword.get(opts, :max_batches, :infinity)) do
      batch_size = Keyword.get(opts, :batch_size, @batch_size)
      ids = from(row in scope, select: row.id, limit: ^batch_size)
      {deleted, _rows} = Repo.delete_all(from(row in schema, where: row.id in subquery(ids)))
      acc = acc + deleted

      if deleted < batch_size do
        acc
      else
        purge_batches(schema, scope, opts, acc, batches + 1)
      end
    else
      acc
    end
  end

  defp continue?(_batches, :infinity), do: true
  defp continue?(batches, max) when is_integer(max) and batches < max, do: true
  defp continue?(_batches, _max), do: false

  defp mark_deleted(installation) do
    Multi.new()
    |> Service.as_multi()
    |> Multi.update(:installation, Installation.changeset(installation, %{status: "deleted"}))
    |> Writer.append(:audit, %{
      installation_id: installation.id,
      actor_type: "job",
      action: "installation.data_deleted",
      resource_type: "installation",
      resource_id: installation.id,
      metadata: %{
        result: "ok",
        source: "retention_worker",
        previous_state: "uninstalled",
        next_state: "deleted"
      }
    })
    |> Repo.transaction()
    |> case do
      {:ok, changes} -> {:ok, changes.installation}
      {:error, step, reason, _changes} -> {:error, {step, reason}}
    end
  end

  defp empty_counts do
    %{
      receipts: 0,
      executions: 0,
      audit_events: 0,
      oauth_states: 0,
      sessions: 0,
      tenant_rows: 0
    }
  end

  defp receipts_due?(%DateTime{} = now) do
    Repo.exists?(from event in ReceivedEvent, where: event.retain_until < ^now)
  end

  defp executions_due?(%DateTime{} = now) do
    cutoff = DateTime.add(now, -@execution_detail_days, :day)

    Repo.exists?(
      from execution in Execution,
        as: :execution,
        where: execution.status in ^@terminal_statuses,
        where: execution.updated_at < ^cutoff,
        where:
          not exists(
            from child in Execution,
              where: child.root_execution_id == parent_as(:execution).id
          )
    )
  end

  defp audit_due?(%DateTime{} = now) do
    cutoff = DateTime.add(now, -@audit_days, :day)
    Repo.exists?(from event in AuditEvent, where: event.inserted_at < ^cutoff)
  end

  defp oauth_due?(%DateTime{} = now) do
    Repo.exists?(
      from state in OauthState,
        where: not is_nil(state.consumed_at) or state.expires_at < ^now
    )
  end

  defp sessions_due?(%DateTime{} = now) do
    Repo.exists?(
      from session in UserSession,
        where:
          not is_nil(session.revoked_at) or session.idle_expires_at < ^now or
            session.absolute_expires_at < ^now
    )
  end

  defp record_run(run), do: :persistent_term.put(@last_run_key, run)

  defp emit(kind, counts, correlation_id, installation_id) do
    metadata =
      %{source: Atom.to_string(kind), correlation_id: correlation_id}
      |> maybe_put(:installation_id, installation_id)

    :telemetry.execute(@telemetry_event ++ [kind], measurements(counts), metadata)
  end

  defp measurements(counts) do
    %{
      receipts: counts.receipts,
      executions: counts.executions,
      audit_events: counts.audit_events,
      oauth_states: counts.oauth_states,
      sessions: counts.sessions,
      tenant_rows: counts.tenant_rows
    }
  end

  defp maybe_put(metadata, _key, nil), do: metadata
  defp maybe_put(metadata, key, value), do: Map.put(metadata, key, value)
end
