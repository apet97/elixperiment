defmodule PumbleAutomation.Installations.LifecycleTest do
  @moduledoc """
  Revocation, uninstall, and the retention purge.

  Every claim about a deleted credential is checked by reading the column back
  through SQL rather than through the schema, because the schema decrypts and a
  struct field would look the same whether the ciphertext went or not. Every
  claim about tenant scoping is checked against a second installation whose rows
  are created for no other purpose than to still be there afterwards.
  """

  use PumbleAutomation.DataCase, async: true

  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Executions.Workers.RetentionWorker
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Lifecycle
  alias PumbleAutomation.Installations.OauthState
  alias PumbleAutomation.Installations.OauthStates
  alias PumbleAutomation.Installations.Service
  alias PumbleAutomation.Installations.Sessions
  alias PumbleAutomation.Installations.UserAuthorization
  alias PumbleAutomation.Installations.UserSession
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.PumbleFake

  describe "revoke_user_authorization/3" do
    test "revokes the row, deletes the ciphertext, and revokes that person's sessions" do
      %{installation: installation, member: member} = install()

      assert {:ok, authorization} =
               Lifecycle.revoke_user_authorization(installation.id, "pumble-user-1")

      assert authorization.status == "revoked"
      assert authorization.revoked_at
      assert stored_access_token(authorization.id) == nil
      assert sessions_revoked?(member.id)
      assert Repo.get!(Installation, installation.id).status == "active"
    end

    test "is idempotent: a second call writes nothing and appends no audit row" do
      %{installation: installation} = install()

      {:ok, _first} = Lifecycle.revoke_user_authorization(installation.id, "pumble-user-1")
      before = audit_count("credential.user_authorization_revoked")

      assert {:ok, again} = Lifecycle.revoke_user_authorization(installation.id, "pumble-user-1")
      assert again.status == "revoked"
      assert audit_count("credential.user_authorization_revoked") == before
    end

    test "an unknown authorization is not found" do
      %{installation: installation} = install()

      assert {:error, error} = Lifecycle.revoke_user_authorization(installation.id, "nobody")
      assert error.class == :not_found
    end
  end

  describe "mark_unauthorized/2" do
    test "deletes the bot ciphertext, revokes sessions, and moves the status to revoked" do
      %{installation: installation, member: member} = install()

      assert {:ok, revoked} = Lifecycle.mark_unauthorized(installation.id)

      assert revoked.status == "revoked"
      assert revoked.revoked_at
      assert stored_bot_token(installation.id) == nil
      assert stored_bot_key_version(installation.id) == nil
      assert sessions_revoked?(member.id)
    end

    test "leaves the user grants alone, because they are a separate authorization" do
      %{installation: installation, authorization: authorization} = install()

      {:ok, _revoked} = Lifecycle.mark_unauthorized(installation.id)

      assert Repo.get!(UserAuthorization, authorization.id).status == "active"
      refute stored_access_token(authorization.id) == nil
    end

    test "is idempotent: a duplicate event appends no second audit row" do
      %{installation: installation} = install()

      {:ok, first} = Lifecycle.mark_unauthorized(installation.id)
      before = audit_count("installation.unauthorized")

      assert {:ok, again} = Lifecycle.mark_unauthorized(installation.id)
      assert again.status == "revoked"
      assert again.revoked_at == first.revoked_at
      assert audit_count("installation.unauthorized") == before
    end
  end

  describe "uninstall/2" do
    test "marks uninstalled, deletes every credential, revokes sessions, and schedules deletion" do
      %{installation: installation, member: member, authorization: authorization} = install()
      now = DateTime.utc_now()

      assert {:ok, uninstalled} = Lifecycle.uninstall(installation.id, now: now)

      assert uninstalled.status == "uninstalled"
      assert uninstalled.uninstalled_at == now

      assert DateTime.diff(uninstalled.deletion_scheduled_at, now, :day) ==
               Lifecycle.retention_days()

      assert stored_bot_token(installation.id) == nil
      assert stored_access_token(authorization.id) == nil
      assert Repo.get!(UserAuthorization, authorization.id).status == "revoked"
      assert sessions_revoked?(member.id)
    end

    test "erases the ciphertext of an expired grant too, not only the active ones" do
      %{installation: installation, authorization: authorization} = install()

      authorization
      |> UserAuthorization.changeset(%{status: "expired"})
      |> Repo.update!()

      {:ok, _uninstalled} = Lifecycle.uninstall(installation.id)

      assert stored_access_token(authorization.id) == nil
      assert Repo.get!(UserAuthorization, authorization.id).status == "expired"
    end

    test "enqueues exactly one retention job on the maintenance queue" do
      %{installation: installation} = install()

      {:ok, uninstalled} = Lifecycle.uninstall(installation.id)

      assert [job] = retention_jobs(installation.id)
      assert job.queue == "maintenance"
      assert job.worker == "PumbleAutomation.Executions.Workers.RetentionWorker"
      assert DateTime.compare(job.scheduled_at, uninstalled.deletion_scheduled_at) == :eq
    end

    test "is idempotent: a duplicate uninstall enqueues no second job and audits once" do
      %{installation: installation} = install()

      {:ok, first} = Lifecycle.uninstall(installation.id)

      assert {:ok, again} = Lifecycle.uninstall(installation.id)
      assert again.uninstalled_at == first.uninstalled_at
      assert again.deletion_scheduled_at == first.deletion_scheduled_at
      assert audit_count("installation.uninstalled") == 1
      assert length(retention_jobs(installation.id)) == 1
    end

    test "an unknown installation is not found" do
      assert {:error, error} = Lifecycle.uninstall(Ecto.UUID.generate())
      assert error.class == :not_found
    end
  end

  describe "the retention worker" do
    test "purges the tenant and leaves every other tenant untouched" do
      %{installation: installation} = install()
      sentinel = install(user: "pumble-user-2")
      {:ok, uninstalled} = Lifecycle.uninstall(installation.id)

      :ok = expire_retention(uninstalled)
      assert :ok = perform(installation.id)

      assert Repo.get!(Installation, installation.id).status == "deleted"

      assert tenant_rows(installation.id) == %{
               authorizations: 0,
               members: 0,
               sessions: 0,
               states: 0
             }

      assert tenant_rows(sentinel.installation.id) == %{
               authorizations: 1,
               members: 1,
               sessions: 1,
               states: 1
             }

      assert Repo.get!(Installation, sentinel.installation.id).status == "active"
    end

    test "keeps the installation row and its audit history" do
      %{installation: installation} = install()
      {:ok, uninstalled} = Lifecycle.uninstall(installation.id)

      :ok = expire_retention(uninstalled)
      :ok = perform(installation.id)

      assert Repo.get(Installation, installation.id)
      assert audit_count("installation.uninstalled") == 1
      assert audit_count("installation.data_deleted") == 1
    end

    test "snoozes while the retention window has not passed" do
      %{installation: installation} = install()
      {:ok, _uninstalled} = Lifecycle.uninstall(installation.id)

      assert {:snooze, seconds} = perform(installation.id)
      assert seconds > 0
      assert Repo.get!(Installation, installation.id).status == "uninstalled"
    end

    test "does nothing for an installation that is no longer uninstalled" do
      %{installation: installation} = install()

      assert :ok = perform(installation.id)
      assert Repo.aggregate(WorkspaceMember, :count) == 1
      assert Repo.get!(Installation, installation.id).status == "active"
    end

    test "does nothing for an installation that no longer exists" do
      assert :ok = perform(Ecto.UUID.generate())
    end

    test "resumes: a second run over an already purged tenant is a no-op" do
      %{installation: installation} = install()
      {:ok, uninstalled} = Lifecycle.uninstall(installation.id)
      :ok = expire_retention(uninstalled)

      :ok = perform(installation.id)

      # The status is `deleted` now, so the guard stops the second run before it
      # touches anything.
      assert :ok = perform(installation.id)
      assert Repo.get!(Installation, installation.id).status == "deleted"
    end
  end

  describe "reinstall by a different person" do
    test "revokes the sessions the previous installer's grant issued" do
      %{installation: installation, member: member, session: session} = install()

      {:ok, result} = reinstall(installation, "pumble-user-9")

      assert Repo.get!(UserSession, session.id).revoked_at
      assert sessions_revoked?(member.id)
      refute Repo.get!(UserSession, result.session.id).revoked_at
    end

    test "keeps the sessions when the same person reinstalls" do
      %{installation: installation, session: session} = install()

      {:ok, _result} = reinstall(installation, "pumble-user-1")

      refute Repo.get!(UserSession, session.id).revoked_at
    end
  end

  # Each installation gets a workspace id of its own. The service takes a
  # PostgreSQL advisory lock keyed on that id, and the test sandbox never
  # commits, so two async tests sharing an id would serialize and eventually
  # deadlock on each other's uncommitted rows.
  defp install(opts \\ []) do
    workspace = Keyword.get_lazy(opts, :workspace, &unique_workspace/0)
    user = Keyword.get(opts, :user, "pumble-user-1")

    {:ok, result} =
      Service.complete_oauth(
        consumed_state("install"),
        PumbleFake.tokens(%{pumble_workspace_id: workspace, pumble_user_id: user})
      )

    # A live state row for this installation, so that the purge has one to find.
    {:ok, _token, _state} = OauthStates.create("signin", installation_id: result.installation.id)

    result
  end

  defp reinstall(%Installation{} = installation, pumble_user_id) do
    Service.complete_oauth(
      consumed_state("reinstall", installation_id: installation.id),
      PumbleFake.tokens(%{
        pumble_workspace_id: installation.pumble_workspace_id,
        pumble_user_id: pumble_user_id
      })
    )
  end

  defp unique_workspace, do: "pumble-workspace-lifecycle-#{System.unique_integer([:positive])}"

  defp consumed_state(intent, opts \\ []) do
    {:ok, token, _state} = OauthStates.create(intent, opts)
    {:ok, consumed} = OauthStates.consume(token)
    consumed
  end

  defp perform(installation_id) do
    RetentionWorker.perform(%Oban.Job{args: %{"installation_id" => installation_id}})
  end

  # The worker reads the wall clock, so a test that wants the window to have
  # passed moves the deletion date into the past rather than the clock forward.
  defp expire_retention(%Installation{} = installation) do
    {1, _rows} =
      Repo.update_all(
        from(i in Installation, where: i.id == ^installation.id),
        set: [deletion_scheduled_at: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

    :ok
  end

  defp tenant_rows(installation_id) do
    %{
      authorizations:
        Repo.aggregate(
          from(a in UserAuthorization, where: a.installation_id == ^installation_id),
          :count
        ),
      members:
        Repo.aggregate(
          from(m in WorkspaceMember, where: m.installation_id == ^installation_id),
          :count
        ),
      sessions:
        Repo.aggregate(
          from(s in UserSession,
            where: s.workspace_member_id in subquery(Sessions.member_ids(installation_id))
          ),
          :count
        ),
      states:
        Repo.aggregate(
          from(s in OauthState, where: s.installation_id == ^installation_id),
          :count
        )
    }
  end

  defp sessions_revoked?(member_id) do
    not Repo.exists?(
      from s in UserSession, where: s.workspace_member_id == ^member_id and is_nil(s.revoked_at)
    )
  end

  defp audit_count(action) do
    Repo.aggregate(from(e in AuditEvent, where: e.action == ^action), :count)
  end

  defp retention_jobs(installation_id) do
    Repo.all(
      from job in Oban.Job,
        where: job.worker == "PumbleAutomation.Executions.Workers.RetentionWorker",
        where: fragment("? ->> 'installation_id' = ?", job.args, ^installation_id)
    )
  end

  # Read back through SQL, not through the schema: the schema decrypts, so a
  # struct field looks the same whether the ciphertext is still there or not.
  defp stored_bot_token(id) do
    scalar("SELECT encrypted_bot_token FROM installations WHERE id = $1", id)
  end

  defp stored_bot_key_version(id) do
    scalar("SELECT token_key_version FROM installations WHERE id = $1", id)
  end

  defp stored_access_token(id) do
    scalar("SELECT encrypted_access_token FROM user_authorizations WHERE id = $1", id)
  end

  defp scalar(sql, id) do
    %{rows: [[value]]} = Repo.query!(sql, [Ecto.UUID.dump!(id)])
    value
  end
end
