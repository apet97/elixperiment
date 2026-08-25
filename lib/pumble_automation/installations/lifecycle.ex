defmodule PumbleAutomation.Installations.Lifecycle do
  @moduledoc """
  The three ways an installation stops being usable, and what each one erases.

  `revoke_user_authorization/3` ends one person's grant. `mark_unauthorized/2`
  ends the workspace's bot credential. `uninstall/2` ends the tenancy. This
  module implements the lifecycle steps, with each transition run as one
  transaction so that a half-applied revocation cannot exist.

  ## What is deleted, and when

      operation                    installation token   user tokens   sessions   data
      revoke_user_authorization    kept                 that one      that one   kept
      mark_unauthorized            deleted              kept          all        kept
      uninstall                    deleted              all           all        purged later

  `mark_unauthorized` leaves user grants alone on purpose. A bot token that
  Pumble stopped honouring says nothing about the separate grants individual
  people made, and deleting them would force everyone to re-authorize because of
  a fault that was not theirs. An unauthorized installation does not delete
  tenant data; only the affected credential goes.

  `uninstall` deletes every credential immediately and schedules the rest for
  erasure after `retention_days/0`, which is the recovery window a reinstall
  uses. `PumbleAutomation.Executions.Workers.RetentionWorker` performs that
  erasure.

  ## Duplicate events do nothing twice

  Every entry point locks its row `FOR UPDATE`, re-reads the status inside the
  transaction, and returns the row unchanged when the transition has already
  happened. A second uninstall callback therefore writes no audit row, revokes
  nothing again, and enqueues no second purge — it returns `{:ok, installation}`
  exactly as the first one did. Pumble retries callbacks; that is the reason this
  is a property and not an accident.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias PumbleAutomation.Audit.Writer
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Workers.RetentionWorker
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Service
  alias PumbleAutomation.Installations.Sessions
  alias PumbleAutomation.Installations.UserAuthorization
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.Oban, as: Jobs
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Retention

  @doc "The number of days tenant data survives an uninstall."
  @spec retention_days() :: pos_integer()
  def retention_days, do: Retention.uninstall_grace_days()

  @doc """
  Revokes one person's authorization inside one installation.

  Marks the row revoked, deletes its ciphertext so the token cannot be used
  again, and revokes that person's browser sessions. Already revoked or expired
  authorizations are returned unchanged.

  Options: `:now`, `:correlation_id`, `:actor_type`, `:actor_id`, `:reason`.
  """
  @spec revoke_user_authorization(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, UserAuthorization.t()} | {:error, Error.t()}
  def revoke_user_authorization(installation_id, pumble_user_id, opts \\ [])
      when is_binary(pumble_user_id) do
    now = now(opts)
    correlation_id = correlation_id(opts)

    Multi.new()
    |> Service.as_multi()
    |> Multi.run(:current, fn repo, _changes ->
      lock_authorization(repo, installation_id, pumble_user_id)
    end)
    |> Multi.run(:guard, fn _repo, %{current: current} ->
      guard(current.status == "active", current)
    end)
    |> Multi.update(:authorization, fn %{current: current} ->
      UserAuthorization.changeset(current, %{
        status: "revoked",
        revoked_at: now,
        encrypted_access_token: nil,
        token_key_version: nil
      })
    end)
    |> Multi.run(:sessions, fn repo, _changes ->
      {:ok, revoke_member_sessions(repo, installation_id, pumble_user_id, now)}
    end)
    |> Writer.append(:audit, fn changes ->
      installation_id
      |> base_audit("credential.user_authorization_revoked", opts)
      |> put_metadata(%{previous_state: "active", next_state: "revoked"}, opts)
      |> Map.put(:resource_type, "user_authorization")
      |> Map.put(:resource_id, changes.authorization.id)
      |> Map.put(:correlation_id, correlation_id)
    end)
    |> Repo.transaction()
    |> finish(:authorization)
  end

  @doc """
  Marks an installation unauthorized: its bot credential no longer works.

  Deletes the bot token ciphertext, revokes every browser session of the
  installation, and moves the status to `revoked`. The named
  `degrade_dependent_workflows/1` hook is still a no-op. An installation that
  is already revoked, uninstalled, or deleted is returned unchanged.

  Options: `:now`, `:correlation_id`, `:actor_type`, `:actor_id`, `:reason`.
  """
  @spec mark_unauthorized(Ecto.UUID.t(), keyword()) ::
          {:ok, Installation.t()} | {:error, Error.t()}
  def mark_unauthorized(installation_id, opts \\ []) do
    now = now(opts)
    correlation_id = correlation_id(opts)

    Multi.new()
    |> Service.as_multi()
    |> Multi.run(:current, fn repo, _changes -> lock_installation(repo, installation_id) end)
    |> Multi.run(:guard, fn _repo, %{current: current} ->
      guard(current.status in ~w(active degraded), current)
    end)
    |> Multi.update(:installation, fn %{current: current} ->
      Installation.changeset(current, %{
        status: "revoked",
        revoked_at: now,
        encrypted_bot_token: nil,
        token_key_version: nil
      })
    end)
    |> Multi.run(:sessions, fn repo, _changes ->
      {:ok, Sessions.revoke_all_for_installation(repo, installation_id, now)}
    end)
    |> Multi.run(:workflows, fn _repo, _changes ->
      {:ok, degrade_dependent_workflows(installation_id)}
    end)
    |> Writer.append(:audit, fn changes ->
      installation_id
      |> base_audit("installation.unauthorized", opts)
      |> put_metadata(
        %{previous_state: changes.current.status, next_state: "revoked"},
        opts
      )
      |> Map.put(:correlation_id, correlation_id)
    end)
    |> Repo.transaction()
    |> finish(:installation)
  end

  @doc """
  Marks an installation uninstalled and schedules the erasure of its data.

  One transaction: the status becomes `uninstalled`, every credential ciphertext
  in the tenant is set to null, every browser session is revoked, the deletion
  date is set `retention_days/0` ahead, the audit row is appended, and the
  retention job is enqueued on the maintenance queue for that date. An
  installation that is already uninstalled or deleted is returned unchanged and
  no second job is enqueued.

  Options: `:now`, `:correlation_id`, `:actor_type`, `:actor_id`, `:reason`.
  """
  @spec uninstall(Ecto.UUID.t(), keyword()) :: {:ok, Installation.t()} | {:error, Error.t()}
  def uninstall(installation_id, opts \\ []) do
    now = now(opts)
    correlation_id = correlation_id(opts)
    deletion_at = DateTime.add(now, Retention.uninstall_grace_days() * 24 * 60 * 60, :second)

    Multi.new()
    |> Service.as_multi()
    |> Multi.run(:current, fn repo, _changes -> lock_installation(repo, installation_id) end)
    |> Multi.run(:guard, fn _repo, %{current: current} ->
      guard(current.status not in ~w(uninstalled deleted), current)
    end)
    |> Multi.update(:installation, fn %{current: current} ->
      Installation.changeset(current, %{
        status: "uninstalled",
        uninstalled_at: now,
        deletion_scheduled_at: deletion_at,
        encrypted_bot_token: nil,
        token_key_version: nil
      })
    end)
    |> Multi.run(:authorizations, fn repo, _changes ->
      {:ok, revoke_all_authorizations(repo, installation_id, now)}
    end)
    |> Multi.run(:sessions, fn repo, _changes ->
      {:ok, Sessions.revoke_all_for_installation(repo, installation_id, now)}
    end)
    |> Multi.run(:workflows, fn _repo, _changes ->
      {:ok, degrade_dependent_workflows(installation_id)}
    end)
    |> Writer.append(:audit, fn changes ->
      installation_id
      |> base_audit("installation.uninstalled", opts)
      |> put_metadata(
        %{
          previous_state: changes.current.status,
          next_state: "uninstalled",
          count: changes.sessions
        },
        opts
      )
      |> Map.put(:correlation_id, correlation_id)
    end)
    |> Jobs.insert(
      :retention,
      fn %{installation: installation} ->
        RetentionWorker.new(%{installation_id: installation.id},
          scheduled_at: installation.deletion_scheduled_at
        )
      end
    )
    |> Repo.transaction()
    |> finish(:installation)
  end

  @doc """
  Hook for credential loss to disable what depended on that credential.

  Still a no-op: uninstall and deleted tenants are excluded from matching,
  and the engine refuses to create work for a non-active installation.
  Revoked tenants can still match; admission fails later. Do not fold
  workflow writes into the lifecycle transaction here.
  """
  @spec degrade_dependent_workflows(Ecto.UUID.t()) :: :ok
  def degrade_dependent_workflows(_installation_id), do: :ok

  defp lock_installation(repo, installation_id) do
    case repo.one(from i in Installation, where: i.id == ^installation_id, lock: "FOR UPDATE") do
      nil -> {:error, not_found("installation")}
      installation -> {:ok, installation}
    end
  end

  defp lock_authorization(repo, installation_id, pumble_user_id) do
    query =
      from authorization in UserAuthorization,
        where:
          authorization.installation_id == ^installation_id and
            authorization.pumble_user_id == ^pumble_user_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      nil -> {:error, not_found("authorization")}
      authorization -> {:ok, authorization}
    end
  end

  # The transition has already happened. Rolling the transaction back with the
  # row as the reason is how the caller gets `{:ok, row}` and no side effect.
  defp guard(true, _row), do: {:ok, :proceed}
  defp guard(false, row), do: {:error, {:noop, row}}

  # Two statements, because they answer different questions. Every ciphertext in
  # the tenant goes, whatever status its row holds: an `expired` grant is still a
  # stored credential, and "all credential ciphertext is removed" is the gate.
  # Only an `active` row changes status, so a row that was already revoked keeps
  # the moment it was revoked at.
  defp revoke_all_authorizations(repo, installation_id, now) do
    tenant = from(a in UserAuthorization, where: a.installation_id == ^installation_id)

    {_erased, _rows} =
      repo.update_all(tenant,
        set: [encrypted_access_token: nil, token_key_version: nil, updated_at: now]
      )

    {count, _rows} =
      repo.update_all(from(a in tenant, where: a.status == "active"),
        set: [status: "revoked", revoked_at: now, updated_at: now]
      )

    count
  end

  defp revoke_member_sessions(repo, installation_id, pumble_user_id, now) do
    member =
      repo.get_by(WorkspaceMember,
        installation_id: installation_id,
        pumble_user_id: pumble_user_id
      )

    case member do
      nil -> 0
      %WorkspaceMember{id: id} -> Sessions.revoke_all_for_member(repo, id, now)
    end
  end

  defp base_audit(installation_id, action, opts) do
    %{
      installation_id: installation_id,
      actor_type: Keyword.get(opts, :actor_type, "system"),
      actor_id: Keyword.get(opts, :actor_id),
      action: action,
      resource_type: "installation",
      resource_id: installation_id
    }
  end

  defp put_metadata(attrs, metadata, opts) do
    metadata =
      metadata
      |> Map.put(:result, "ok")
      |> Map.put(:source, "lifecycle")
      |> maybe_put_reason(Keyword.get(opts, :reason))

    Map.put(attrs, :metadata, metadata)
  end

  defp maybe_put_reason(metadata, nil), do: metadata
  defp maybe_put_reason(metadata, reason), do: Map.put(metadata, :reason, to_string(reason))

  defp finish({:ok, changes}, key), do: {:ok, Map.fetch!(changes, key)}
  defp finish({:error, _step, {:noop, row}, _changes}, _key), do: {:ok, row}
  defp finish({:error, step, reason, _changes}, _key), do: {:error, to_error(step, reason)}

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
  defp correlation_id(opts), do: Keyword.get_lazy(opts, :correlation_id, &Ecto.UUID.generate/0)

  defp not_found(kind) do
    Error.new(:not_found, :installation_not_found,
      message: "The installation could not be found.",
      details: %{kind: kind}
    )
  end

  defp to_error(_step, %Error{} = error), do: error

  defp to_error(step, %Ecto.Changeset{} = changeset) do
    Error.new(:validation, :lifecycle_write_rejected,
      message: "The lifecycle change could not be applied.",
      details: %{step: step, fields: Keyword.keys(changeset.errors)}
    )
  end

  defp to_error(step, reason) do
    Error.new(:internal, :lifecycle_write_failed,
      message: "The lifecycle change could not be applied.",
      details: %{step: step},
      cause: reason
    )
  end
end
