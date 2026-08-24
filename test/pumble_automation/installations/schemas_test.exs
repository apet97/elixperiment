defmodule PumbleAutomation.Installations.SchemasTest do
  # Not async: the unique-installation test runs two processes against one
  # sandboxed connection.
  use PumbleAutomation.DataCase, async: false

  import ExUnit.CaptureLog

  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.OauthState
  alias PumbleAutomation.Installations.UserAuthorization
  alias PumbleAutomation.Installations.UserSession
  alias PumbleAutomation.Installations.WorkspaceMember

  require Logger

  @token "xoxb-schema-sentinel-token"

  describe "the migration" do
    test "creates every identity table" do
      for table <-
            ~w(installations user_authorizations workspace_members oauth_states user_sessions) do
        assert %{rows: [[found]]} = Repo.query!("SELECT to_regclass('public.#{table}')::text")
        assert found == table
      end
    end

    test "indexes the expiries that a sweep and a lookup depend on" do
      assert index_definitions("oauth_states") =~ "(expires_at)"
      assert index_definitions("user_sessions") =~ "(absolute_expires_at)"
      assert index_definitions("user_sessions") =~ "(idle_expires_at)"

      assert index_definitions("installations") =~ "deletion_scheduled_at"
    end

    test "makes workspace, member, state, and session identity unique" do
      assert index_definitions("installations") =~ "UNIQUE"
      assert index_definitions("installations") =~ "(pumble_workspace_id)"
      assert index_definitions("workspace_members") =~ "(installation_id, pumble_user_id)"
      assert index_definitions("user_authorizations") =~ "(installation_id, pumble_user_id)"
      assert index_definitions("oauth_states") =~ "(state_digest)"
      assert index_definitions("user_sessions") =~ "(token_digest)"
    end

    test "constrains every status, role, and intent in the database" do
      assert check_constraints("installations") == ["installations_status_check"]
      assert check_constraints("user_authorizations") == ["user_authorizations_status_check"]
      assert check_constraints("workspace_members") == ["workspace_members_role_check"]
      assert check_constraints("oauth_states") == ["oauth_states_intent_check"]
      assert check_constraints("user_sessions") == ["user_sessions_expiry_order_check"]
    end

    test "points audit events at installations without cascading" do
      assert %{rows: [[action]]} =
               Repo.query!("""
               SELECT confdeltype FROM pg_constraint
               WHERE conname = 'audit_events_installation_id_fkey'
               """)

      # 'a' is NO ACTION: audit history survives its installation.
      assert action == "a"
    end

    test "cascades tenant-owned rows from the installation" do
      installation = insert_installation()
      member = insert_member(installation)
      insert_session(member)
      insert_authorization(installation)

      Repo.delete_all(from(i in Installation, where: i.id == ^installation.id))

      assert Repo.aggregate(WorkspaceMember, :count) == 0
      assert Repo.aggregate(UserAuthorization, :count) == 0
      assert Repo.aggregate(UserSession, :count) == 0
    end
  end

  describe "Installation.changeset/2" do
    test "requires the workspace id" do
      changeset = Installation.changeset(%Installation{}, %{})
      assert "can't be blank" in errors_on(changeset).pumble_workspace_id
    end

    test "defaults to the active status" do
      installation = insert_installation()
      assert installation.status == "active"
    end

    test "refuses a status outside the lifecycle" do
      changeset =
        Installation.changeset(%Installation{}, %{
          pumble_workspace_id: "ws-1",
          status: "paused"
        })

      assert errors_on(changeset).status != []
    end

    test "allows a documented transition" do
      installation = insert_installation()

      for next <- Installation.next_statuses("active") do
        changeset = Installation.changeset(installation, %{status: next})
        assert changeset.valid?, "expected active -> #{next} to be allowed"
      end
    end

    test "refuses a transition the lifecycle does not allow" do
      installation = insert_installation()

      {:ok, deleted} =
        installation |> Installation.changeset(%{status: "uninstalled"}) |> Repo.update()

      {:ok, deleted} = deleted |> Installation.changeset(%{status: "deleted"}) |> Repo.update()

      changeset = Installation.changeset(deleted, %{status: "active"})

      assert "cannot move from deleted to active" in errors_on(changeset).status
    end

    test "keeps the workspace id immutable" do
      installation = insert_installation()

      changeset = Installation.changeset(installation, %{pumble_workspace_id: "ws-other"})

      assert "cannot be changed" in errors_on(changeset).pumble_workspace_id
      assert {:error, _changeset} = Repo.update(changeset)
    end

    test "accepts a write that repeats the workspace id it already has" do
      installation = insert_installation()

      changeset =
        Installation.changeset(installation, %{
          pumble_workspace_id: installation.pumble_workspace_id,
          workspace_name_snapshot: "Acme"
        })

      assert changeset.valid?
    end

    test "normalizes scopes to a sorted, unique list" do
      installation =
        insert_installation(%{
          bot_scopes: ["chat:write", " channels:read ", "chat:write", ""],
          user_scopes: ["users:read"]
        })

      assert installation.bot_scopes == ["channels:read", "chat:write"]
      assert installation.user_scopes == ["users:read"]
    end

    test "requires a key version next to a stored token" do
      changeset =
        Installation.changeset(%Installation{}, %{
          pumble_workspace_id: "ws-1",
          encrypted_bot_token: @token
        })

      assert errors_on(changeset).token_key_version != []
    end

    test "stores the bot token as ciphertext and reads it back" do
      installation = insert_installation(%{encrypted_bot_token: @token, token_key_version: 1})

      assert Repo.get!(Installation, installation.id).encrypted_bot_token == @token
      refute stored_token(installation.id) =~ @token
    end
  end

  describe "one installation per workspace" do
    test "lets exactly one of two concurrent inserts win" do
      workspace_id = "ws-" <> Ecto.UUID.generate()

      results =
        [workspace_id, workspace_id]
        |> Enum.map(fn id -> Task.async(fn -> insert_workspace(id) end) end)
        |> Task.await_many()

      assert Enum.count(results, &match?({:ok, _installation}, &1)) == 1
      assert [{:error, changeset}] = Enum.filter(results, &match?({:error, _changeset}, &1))
      assert "has already been taken" in errors_on(changeset).pumble_workspace_id
      assert Repo.aggregate(Installation, :count) == 1
    end
  end

  describe "UserAuthorization.changeset/2" do
    test "requires an installation and a user" do
      changeset = UserAuthorization.changeset(%UserAuthorization{}, %{})

      assert errors_on(changeset).installation_id != []
      assert errors_on(changeset).pumble_user_id != []
    end

    test "keeps one authorization per user per installation" do
      installation = insert_installation()
      assert %UserAuthorization{} = insert_authorization(installation, "user-1")

      assert {:error, changeset} =
               %UserAuthorization{}
               |> UserAuthorization.changeset(authorization_attrs(installation, "user-1"))
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).installation_id
    end

    test "allows the same user under a different installation" do
      first = insert_installation()
      second = insert_installation()

      assert %UserAuthorization{} = insert_authorization(first, "user-1")
      assert %UserAuthorization{} = insert_authorization(second, "user-1")
    end

    test "refuses an unknown status" do
      installation = insert_installation()
      attrs = installation |> authorization_attrs("user-1") |> Map.put(:status, "maybe")

      changeset = UserAuthorization.changeset(%UserAuthorization{}, attrs)
      assert errors_on(changeset).status != []
    end

    test "reports a missing installation as a constraint error, not an exception" do
      attrs = %{
        installation_id: Ecto.UUID.generate(),
        pumble_user_id: "user-1",
        status: "active"
      }

      assert {:error, changeset} =
               %UserAuthorization{} |> UserAuthorization.changeset(attrs) |> Repo.insert()

      assert errors_on(changeset).installation_id != []
    end

    test "stores the access token as ciphertext" do
      installation = insert_installation()
      authorization = insert_authorization(installation, "user-1")

      assert Repo.get!(UserAuthorization, authorization.id).encrypted_access_token == @token
    end
  end

  describe "WorkspaceMember.changeset/2" do
    test "accepts each local role" do
      installation = insert_installation()

      for role <- WorkspaceMember.roles() do
        assert %WorkspaceMember{} = insert_member(installation, role)
      end
    end

    test "refuses a role outside the three" do
      installation = insert_installation()
      attrs = installation |> member_attrs("user-1") |> Map.put(:role, "admin")

      changeset = WorkspaceMember.changeset(%WorkspaceMember{}, attrs)
      assert errors_on(changeset).role != []
    end

    test "keeps one member row per user per installation" do
      installation = insert_installation()
      assert %WorkspaceMember{} = insert_member(installation, "viewer", "user-1")

      assert {:error, changeset} =
               %WorkspaceMember{}
               |> WorkspaceMember.changeset(member_attrs(installation, "user-1"))
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).installation_id
    end

    test "defaults the profile snapshot to an empty map" do
      installation = insert_installation()
      member = insert_member(installation)

      assert member.profile_snapshot == %{}
    end
  end

  describe "OauthState.changeset/2" do
    test "requires a digest, an intent, and an expiry" do
      changeset = OauthState.changeset(%OauthState{}, %{})

      assert errors_on(changeset).state_digest != []
      assert errors_on(changeset).intent != []
      assert errors_on(changeset).expires_at != []
    end

    test "accepts each intent" do
      for intent <- OauthState.intents() do
        assert {:ok, _state} =
                 %OauthState{}
                 |> OauthState.changeset(state_attrs(%{intent: intent}))
                 |> Repo.insert()
      end
    end

    test "refuses an unknown intent" do
      changeset = OauthState.changeset(%OauthState{}, state_attrs(%{intent: "guess"}))
      assert errors_on(changeset).intent != []
    end

    test "refuses anything that is not a 32 byte digest" do
      changeset = OauthState.changeset(%OauthState{}, state_attrs(%{state_digest: "raw-token"}))

      assert "must be a 32 byte SHA-256 digest" in errors_on(changeset).state_digest
    end

    test "keeps a state digest unique" do
      digest = OauthState.digest("token-1")
      assert {:ok, _state} = insert_state(%{state_digest: digest})

      assert {:error, changeset} = insert_state(%{state_digest: digest})
      assert "has already been taken" in errors_on(changeset).state_digest
    end

    test "treats a consumed or expired state as unusable" do
      now = DateTime.utc_now()
      fresh = %OauthState{expires_at: DateTime.add(now, 600, :second)}

      assert OauthState.usable?(fresh, now)
      refute OauthState.usable?(%{fresh | consumed_at: now}, now)
      refute OauthState.usable?(%OauthState{expires_at: DateTime.add(now, -1, :second)}, now)
    end
  end

  describe "UserSession.changeset/2" do
    test "has no column that could hold a raw token" do
      columns = column_names("user_sessions")

      assert "token_digest" in columns
      refute Enum.any?(columns, &(&1 in ~w(token session_token raw_token)))
    end

    test "requires the member, the digest, and both expiries" do
      changeset = UserSession.changeset(%UserSession{}, %{})

      assert errors_on(changeset).workspace_member_id != []
      assert errors_on(changeset).token_digest != []
      assert errors_on(changeset).idle_expires_at != []
      assert errors_on(changeset).absolute_expires_at != []
    end

    test "refuses an idle expiry beyond the absolute expiry" do
      installation = insert_installation()
      member = insert_member(installation)
      now = DateTime.utc_now()

      attrs =
        member
        |> session_attrs()
        |> Map.merge(%{
          idle_expires_at: DateTime.add(now, 7200, :second),
          absolute_expires_at: DateTime.add(now, 60, :second)
        })

      changeset = UserSession.changeset(%UserSession{}, attrs)
      assert "cannot be after the absolute expiry" in errors_on(changeset).idle_expires_at
    end

    test "keeps a token digest unique" do
      installation = insert_installation()
      member = insert_member(installation)
      digest = UserSession.digest("session-token")

      assert %UserSession{} = insert_session(member, %{token_digest: digest})

      assert {:error, changeset} =
               %UserSession{}
               |> UserSession.changeset(session_attrs(member, %{token_digest: digest}))
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).token_digest
    end

    test "treats a revoked or expired session as unusable" do
      now = DateTime.utc_now()

      usable = %UserSession{
        idle_expires_at: DateTime.add(now, 900, :second),
        absolute_expires_at: DateTime.add(now, 3600, :second)
      }

      assert UserSession.usable?(usable, now)
      refute UserSession.usable?(%{usable | revoked_at: now}, now)
      refute UserSession.usable?(%{usable | idle_expires_at: DateTime.add(now, -1, :second)}, now)

      refute UserSession.usable?(
               %{usable | absolute_expires_at: DateTime.add(now, -1, :second)},
               now
             )
    end
  end

  describe "redaction" do
    test "no credential and no digest survives inspect or a log line" do
      installation = insert_installation(%{encrypted_bot_token: @token, token_key_version: 1})
      member = insert_member(installation)
      authorization = insert_authorization(installation, "user-1")
      digest_token = "session-token"
      session = insert_session(member, %{token_digest: UserSession.digest(digest_token)})
      {:ok, state} = insert_state()

      rendered = Enum.map_join([installation, authorization, session, state], "\n", &inspect/1)
      log = capture_log(fn -> Logger.warning(rendered) end)

      refute rendered =~ @token
      refute log =~ @token
      refute rendered =~ "encrypted_bot_token"
      refute rendered =~ "encrypted_access_token"
      refute rendered =~ "token_digest"
      refute rendered =~ "state_digest"
      refute rendered =~ "user_agent_hash"
      refute rendered =~ Base.encode16(session.token_digest, case: :lower)
      refute rendered =~ Base.encode16(state.state_digest, case: :lower)
    end
  end

  defp insert_workspace(workspace_id) do
    %Installation{}
    |> Installation.changeset(%{pumble_workspace_id: workspace_id})
    |> Repo.insert()
  end

  defp insert_installation(attrs \\ %{}) do
    attrs = Map.put_new(attrs, :pumble_workspace_id, "ws-" <> Ecto.UUID.generate())

    %Installation{}
    |> Installation.changeset(attrs)
    |> Repo.insert!()
  end

  defp authorization_attrs(installation, user_id) do
    %{
      installation_id: installation.id,
      pumble_user_id: user_id,
      encrypted_access_token: @token,
      token_key_version: 1,
      scopes: ["users:read", "chat:write"],
      status: "active",
      authorized_at: DateTime.utc_now()
    }
  end

  defp insert_authorization(installation, user_id \\ "user-1") do
    %UserAuthorization{}
    |> UserAuthorization.changeset(authorization_attrs(installation, user_id))
    |> Repo.insert!()
  end

  defp member_attrs(installation, user_id, role \\ "viewer") do
    %{installation_id: installation.id, pumble_user_id: user_id, role: role}
  end

  defp insert_member(installation, role \\ "viewer", user_id \\ nil) do
    user_id = user_id || "user-" <> Ecto.UUID.generate()

    %WorkspaceMember{}
    |> WorkspaceMember.changeset(member_attrs(installation, user_id, role))
    |> Repo.insert!()
  end

  defp state_attrs(overrides) do
    Map.merge(
      %{
        state_digest: OauthState.digest(Ecto.UUID.generate()),
        intent: "install",
        return_path_key: "workflows_index",
        expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
      },
      overrides
    )
  end

  defp insert_state(overrides \\ %{}) do
    %OauthState{}
    |> OauthState.changeset(state_attrs(overrides))
    |> Repo.insert()
  end

  defp session_attrs(member, overrides \\ %{}) do
    now = DateTime.utc_now()

    Map.merge(
      %{
        workspace_member_id: member.id,
        token_digest: UserSession.digest(Ecto.UUID.generate()),
        issued_at: now,
        last_used_at: now,
        idle_expires_at: DateTime.add(now, 900, :second),
        absolute_expires_at: DateTime.add(now, 3600, :second),
        user_agent_hash: UserSession.digest("agent")
      },
      overrides
    )
  end

  defp insert_session(member, overrides \\ %{}) do
    %UserSession{}
    |> UserSession.changeset(session_attrs(member, overrides))
    |> Repo.insert!()
  end

  defp stored_token(id) do
    %{rows: [[token]]} =
      Repo.query!("SELECT encrypted_bot_token FROM installations WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    token
  end

  defp index_definitions(table) do
    %{rows: rows} = Repo.query!("SELECT indexdef FROM pg_indexes WHERE tablename = $1", [table])
    Enum.map_join(rows, "\n", fn [definition] -> definition end)
  end

  defp check_constraints(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT con.conname FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        WHERE rel.relname = $1 AND con.contype = 'c'
        """,
        [table]
      )

    rows |> Enum.map(fn [name] -> name end) |> Enum.sort()
  end

  defp column_names(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = $1",
        [table]
      )

    Enum.map(rows, fn [name] -> name end)
  end
end
