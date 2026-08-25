defmodule PumbleAutomation.Installations.Members do
  @moduledoc """
  Changing what a member of an installation may do.

  One function, because one thing about a member is security-critical: the role.
  `update_role/4` is the wiring point for rotating the session after a role
  change.

  ## A role change ends the member's sessions

  The scope a session authorizes against is built at sign-in and is immutable, so
  a session issued to a viewer keeps viewer authority until it ends. Rather than
  patching live scopes, the change revokes every session that member holds; the
  next sign-in issues one carrying the new role. That is rotation with the only
  correct outcome for a *demotion*: authority drops immediately rather than at
  the end of the old session's idle window.

  `PumbleAutomation.Installations.Sessions.rotate/3` is the request-local form of
  the same idea, for a caller that can also write the replacement cookie.

  ## Another tenant's member does not exist

  The lookup is scoped to the caller's installation, so a member id from another
  workspace produces `PumbleAutomation.Installations.Policy.not_found/0` — the
  same answer as an id belonging to nobody, before any permission is considered.

  ## At least one owner remains

  Demoting the last enabled owner is refused. A workspace with nobody who can
  manage members cannot recover through the UI. The check runs after locking
  every member row of the tenant in id order, so two concurrent demotions cannot
  both observe two owners and leave zero.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias PumbleAutomation.Audit.Writer
  alias PumbleAutomation.Error
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Installations.Service
  alias PumbleAutomation.Installations.Sessions
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope

  @doc """
  Sets a member's role and revokes that member's sessions.

  Requires the `:manage_members` capability, which only an owner holds. Setting
  the role a member already has is a no-op: no session is revoked and no audit
  row is written. Demoting the last enabled owner is a `:conflict`.

  Options: `:now`, `:correlation_id`.
  """
  @spec update_role(Scope.t(), Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, WorkspaceMember.t()} | {:error, Error.t()}
  def update_role(%Scope{} = scope, member_id, role, opts \\ []) when is_binary(role) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    correlation_id = Keyword.get_lazy(opts, :correlation_id, &Ecto.UUID.generate/0)

    Multi.new()
    |> Service.as_multi()
    |> Multi.run(:locked, fn repo, _changes ->
      {:ok, lock_members(repo, scope.installation_id)}
    end)
    |> Multi.run(:member, fn _repo, %{locked: members} ->
      pick_member(members, member_id, scope)
    end)
    |> Multi.run(:auth, fn _repo, _changes -> authorize_manage(scope) end)
    |> Multi.run(:guard, fn _repo, %{locked: members, member: member} ->
      guard_role(members, member, role)
    end)
    |> Multi.run(:updated, fn repo, %{member: member, guard: guard} ->
      persist_role(repo, member, role, guard)
    end)
    |> Multi.run(:sessions, fn repo, %{member: member, guard: guard} ->
      revoke_if_changed(repo, member, guard, now)
    end)
    |> Multi.merge(fn
      %{guard: :unchanged} ->
        Service.as_multi(Multi.new())

      %{guard: :change, member: member} ->
        Writer.append(Service.as_multi(Multi.new()), :audit, %{
          installation_id: scope.installation_id,
          actor_type: "user",
          actor_id: scope.member_id,
          action: "admin.member_role_changed",
          resource_type: "workspace_member",
          resource_id: member.id,
          correlation_id: correlation_id,
          metadata: %{
            result: "ok",
            source: "members",
            actor_role: scope.role,
            previous_state: member.role,
            next_state: role
          }
        })
    end)
    |> Repo.transaction()
    |> finish_role()
  end

  @doc """
  Lists the scope's members. Owner-only.

  Profile snapshots are display fields only. They are not used for authorization.
  """
  @spec list(Scope.t()) :: {:ok, [WorkspaceMember.t()]} | {:error, Error.t()}
  def list(%Scope{} = scope) do
    with :ok <- Policy.authorize(scope, :manage_members) do
      query =
        from member in WorkspaceMember,
          where: member.installation_id == ^scope.installation_id,
          order_by: [asc: member.inserted_at, asc: member.id]

      {:ok, query |> Repo.all() |> Enum.sort_by(&{role_rank(&1.role), member_sort_key(&1)})}
    end
  end

  @doc "How many enabled owners the tenant currently has."
  @spec owner_count(Scope.t()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def owner_count(%Scope{} = scope) do
    with :ok <- Policy.authorize(scope, :manage_members) do
      {:ok, count_owners(scope.installation_id)}
    end
  end

  @doc """
  Display names for member ids in this tenant.

  Unknown and foreign ids are omitted. The ids come from version rows the
  caller already loaded through a scoped query; this is not an authorization
  surface.
  """
  @spec labels(Scope.t(), [Ecto.UUID.t() | nil]) :: %{Ecto.UUID.t() => String.t()}
  def labels(%Scope{} = scope, ids) when is_list(ids) do
    ids = ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    if ids == [] do
      %{}
    else
      query =
        from member in WorkspaceMember,
          where: member.installation_id == ^scope.installation_id and member.id in ^ids

      Map.new(Repo.all(query), fn member -> {member.id, member_label(member)} end)
    end
  end

  defp lock_members(repo, installation_id) do
    repo.all(
      from member in WorkspaceMember,
        where: member.installation_id == ^installation_id,
        order_by: [asc: member.id],
        lock: "FOR UPDATE"
    )
  end

  defp pick_member(members, member_id, %Scope{} = scope) do
    case Ecto.UUID.cast(member_id) do
      :error ->
        {:error, Policy.not_found()}

      {:ok, id} ->
        case Enum.find(members, &(&1.id == id)) do
          nil -> Scope.refuse_unknown(WorkspaceMember, id, scope.installation_id, :members)
          member -> {:ok, member}
        end
    end
  end

  defp authorize_manage(scope) do
    case Policy.authorize(scope, :manage_members) do
      :ok -> {:ok, :ok}
      {:error, error} -> {:error, error}
    end
  end

  defp guard_role(members, %WorkspaceMember{} = member, role) do
    cond do
      member.role == role ->
        {:ok, :unchanged}

      last_owner_demotion?(members, member, role) ->
        {:error, Error.new(:conflict, :last_owner, message: "At least one owner must remain.")}

      true ->
        {:ok, :change}
    end
  end

  defp last_owner_demotion?(members, %WorkspaceMember{role: "owner"}, role)
       when role != "owner" do
    Enum.count(members, &(&1.role == "owner" and is_nil(&1.disabled_at))) <= 1
  end

  defp last_owner_demotion?(_members, _member, _role), do: false

  defp persist_role(_repo, member, _role, :unchanged), do: {:ok, member}

  defp persist_role(repo, member, role, :change) do
    repo.update(WorkspaceMember.changeset(member, %{role: role}))
  end

  defp revoke_if_changed(_repo, _member, :unchanged, _now), do: {:ok, 0}

  defp revoke_if_changed(repo, member, :change, now) do
    {:ok, Sessions.revoke_all_for_member(repo, member.id, now)}
  end

  defp finish_role({:ok, %{updated: member}}), do: {:ok, member}

  defp finish_role({:error, _step, %Error{} = error, _changes}), do: {:error, error}

  defp finish_role({:error, step, %Ecto.Changeset{} = changeset, _changes}) do
    {:error,
     Error.new(:validation, :member_write_rejected,
       message: "The member could not be changed.",
       details: %{step: step, fields: Keyword.keys(changeset.errors)}
     )}
  end

  defp finish_role({:error, step, reason, _changes}) do
    {:error,
     Error.new(:internal, :member_write_failed,
       message: "The member could not be changed.",
       details: %{step: step},
       cause: reason
     )}
  end

  defp count_owners(installation_id) do
    query =
      from member in WorkspaceMember,
        where: member.installation_id == ^installation_id,
        where: member.role == "owner",
        where: is_nil(member.disabled_at)

    Repo.aggregate(query, :count)
  end

  defp role_rank("owner"), do: 0
  defp role_rank("editor"), do: 1
  defp role_rank("viewer"), do: 2
  defp role_rank(_other), do: 3

  defp member_sort_key(%WorkspaceMember{} = member) do
    snapshot_name(member.profile_snapshot) || member.pumble_user_id
  end

  defp snapshot_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp snapshot_name(%{"display_name" => name}) when is_binary(name) and name != "", do: name
  defp snapshot_name(_snapshot), do: nil

  defp member_label(%WorkspaceMember{} = member) do
    snapshot_name(member.profile_snapshot) || member.pumble_user_id
  end
end
