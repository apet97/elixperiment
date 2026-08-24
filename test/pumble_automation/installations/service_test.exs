defmodule PumbleAutomation.Installations.ServiceTest do
  @moduledoc """
  `complete_oauth/3`: the transaction that turns an exchange into a tenant.

  The tests are organised by the invariant they defend rather than by function,
  because the function has one entry point and four behaviours. Where a test
  asserts that nothing was written, it counts rows in every table the transaction
  touches — asserting only that the call returned an error would pass against a
  transaction that leaked.
  """

  use PumbleAutomation.DataCase, async: true

  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.OauthState
  alias PumbleAutomation.Installations.OauthStates
  alias PumbleAutomation.Installations.Service
  alias PumbleAutomation.Installations.UserAuthorization
  alias PumbleAutomation.Installations.UserSession
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.PumbleFake

  setup do
    workspace = InstallationsFixtures.unique_workspace()
    Process.put({__MODULE__, :workspace}, workspace)
    :ok
  end

  describe "install" do
    test "creates the tenant, the member, the authorization, the session, and the audit row" do
      state = consumed_state("install")

      assert {:ok, result} = Service.complete_oauth(state, tokens())

      assert result.intent == "install"
      assert result.installation.pumble_workspace_id == workspace()
      assert result.installation.status == "active"
      assert result.installation.bot_user_id == "pumble-bot-1"
      assert result.member.pumble_user_id == "pumble-user-1"
      assert result.authorization.status == "active"
      assert result.session.workspace_member_id == result.member.id

      assert Repo.aggregate(Installation, :count) == 1
      assert Repo.aggregate(WorkspaceMember, :count) == 1
      assert Repo.aggregate(UserAuthorization, :count) == 1
      assert Repo.aggregate(UserSession, :count) == 1
    end

    test "returns the session token once and stores only its digest" do
      state = consumed_state("install")

      {:ok, result} = Service.complete_oauth(state, tokens())

      assert is_binary(result.session_token)
      assert byte_size(result.session_token) >= 43

      persisted = Repo.get!(UserSession, result.session.id)
      assert persisted.token_digest == UserSession.digest(result.session_token)

      refute persisted
             |> Map.from_struct()
             |> Map.values()
             |> Enum.any?(&(&1 == result.session_token))
    end

    test "the credentials are ciphertext in the database and plaintext in the struct" do
      state = consumed_state("install")

      {:ok, result} = Service.complete_oauth(state, tokens())

      assert result.installation.encrypted_bot_token == "bot-access-token"

      %{rows: [[stored_bot]]} =
        Repo.query!("SELECT encrypted_bot_token FROM installations WHERE id = $1", [
          Ecto.UUID.dump!(result.installation.id)
        ])

      refute stored_bot == "bot-access-token"
      refute String.contains?(stored_bot, "bot-access-token")

      %{rows: [[stored_access]]} =
        Repo.query!("SELECT encrypted_access_token FROM user_authorizations WHERE id = $1", [
          Ecto.UUID.dump!(result.authorization.id)
        ])

      refute String.contains?(stored_access, "user-access-token")
    end

    test "records the key version alongside every stored credential" do
      state = consumed_state("install")

      {:ok, result} = Service.complete_oauth(state, tokens())

      version = Application.fetch_env!(:pumble_automation, :encryption)[:key_version]

      assert result.installation.token_key_version == version
      assert result.authorization.token_key_version == version
    end

    test "snapshots the scopes this application asked for" do
      state = consumed_state("install")

      {:ok, result} = Service.complete_oauth(state, tokens())

      pumble = Application.fetch_env!(:pumble_automation, :pumble)

      assert result.installation.bot_scopes == Keyword.get(pumble, :bot_scopes, [])
      assert result.installation.user_scopes == Keyword.get(pumble, :user_scopes, [])
      assert result.authorization.scopes == Keyword.get(pumble, :user_scopes, [])
    end

    test "appends one audit event naming the workspace and the actor" do
      state = consumed_state("install")

      {:ok, result} =
        Service.complete_oauth(state, tokens(), correlation_id: "corr-1")

      assert [event] = Repo.all(AuditEvent)
      assert event.action == "oauth.install_completed"
      assert event.installation_id == result.installation.id
      assert event.actor_type == "pumble_user"
      assert event.actor_id == "pumble-user-1"
      assert event.correlation_id == "corr-1"
      assert event.metadata["result"] == "ok"
      assert event.metadata["actor_role"] == "owner"
    end

    test "the audit event carries no credential and no workspace id in metadata" do
      state = consumed_state("install")

      {:ok, _result} = Service.complete_oauth(state, tokens())

      assert [event] = Repo.all(AuditEvent)

      rendered = inspect(event.metadata)

      refute rendered =~ "bot-access-token"
      refute rendered =~ "user-access-token"
      refute rendered =~ workspace()
    end

    test "fails without writing anything when the grant carried no bot token" do
      state = consumed_state("install")

      assert {:error, error} =
               Service.complete_oauth(state, tokens(%{bot_token: nil}))

      assert error.code == :bot_token_missing
      assert_nothing_written()
    end

    test "records the installing user on the tenant" do
      state = consumed_state("install")

      {:ok, result} = Service.complete_oauth(state, tokens())

      assert result.installation.installed_by_pumble_user_id == "pumble-user-1"
      refute is_nil(result.installation.authorized_at)
    end
  end

  describe "first owner" do
    test "the first installer becomes owner" do
      {:ok, result} = Service.complete_oauth(consumed_state("install"), tokens())

      assert result.member.role == "owner"
    end

    test "a second installer does not become a second owner" do
      {:ok, first} = Service.complete_oauth(consumed_state("install"), tokens())

      {:ok, second} =
        Service.complete_oauth(
          consumed_state("install"),
          tokens(%{pumble_user_id: "pumble-user-2"})
        )

      assert first.member.role == "owner"
      assert second.member.role == "viewer"
      assert owner_count(second.installation.id) == 1
    end

    test "repeated first installers produce exactly one owner" do
      # The unsandboxed database race test proves the advisory lock across real
      # connections. This sandboxed test proves the repeated-install decision rule.
      workspace_id = workspace()

      results =
        Enum.map(1..8, fn index ->
          Service.complete_oauth(
            consumed_state("install"),
            PumbleFake.tokens(%{
              pumble_workspace_id: workspace_id,
              pumble_user_id: "pumble-user-#{index}"
            })
          )
        end)

      assert Enum.all?(results, &match?({:ok, _result}, &1))

      assert Repo.aggregate(Installation, :count) == 1,
             "one workspace must produce one installation"

      installation = Repo.one!(Installation)
      assert owner_count(installation.id) == 1
      assert Repo.aggregate(WorkspaceMember, :count) == 8
    end

    test "an existing member keeps its role: OAuth never changes authority" do
      {:ok, first} = Service.complete_oauth(consumed_state("install"), tokens())

      {:ok, editor} =
        first.member
        |> WorkspaceMember.changeset(%{role: "editor"})
        |> Repo.update()

      {:ok, again} = Service.complete_oauth(consumed_state("signin"), tokens())

      assert editor.role == "editor"
      assert again.member.role == "editor"
      assert again.member.id == first.member.id
    end

    test "a sign-in never grants owner, even when the workspace has none" do
      installation = installation_fixture()
      assert owner_count(installation.id) == 0

      state = consumed_state("signin")

      {:ok, result} = Service.complete_oauth(state, tokens())

      assert result.member.role == "viewer"
      assert owner_count(installation.id) == 0
    end
  end

  describe "reinstall" do
    test "replaces the credentials and preserves the tenant row and its members" do
      {:ok, first} = Service.complete_oauth(consumed_state("install"), tokens())

      {:ok, second} =
        Service.complete_oauth(
          consumed_state("reinstall"),
          tokens(%{bot_token: "rotated-bot-token", access_token: "rotated-access"})
        )

      assert second.installation.id == first.installation.id
      assert second.member.id == first.member.id
      assert second.member.role == "owner"

      assert second.installation.encrypted_bot_token == "rotated-bot-token"

      assert Repo.get!(Installation, first.installation.id).encrypted_bot_token ==
               "rotated-bot-token"

      assert Repo.aggregate(Installation, :count) == 1
      assert Repo.aggregate(WorkspaceMember, :count) == 1
    end

    test "the workspace id is immutable across a reinstall" do
      {:ok, first} = Service.complete_oauth(consumed_state("install"), tokens())

      {:ok, second} = Service.complete_oauth(consumed_state("reinstall"), tokens())

      assert second.installation.pumble_workspace_id == first.installation.pumble_workspace_id
      assert second.installation.pumble_workspace_id == workspace()
    end

    test "brings an uninstalled workspace back without losing its data" do
      {:ok, first} = Service.complete_oauth(consumed_state("install"), tokens())

      {:ok, _uninstalled} =
        first.installation
        |> Installation.changeset(%{status: "uninstalled", uninstalled_at: DateTime.utc_now()})
        |> Repo.update()

      {:ok, second} = Service.complete_oauth(consumed_state("reinstall"), tokens())

      assert second.installation.id == first.installation.id
      assert second.installation.status == "active"
      assert second.member.id == first.member.id
    end

    test "a reinstall of a workspace that never installed fails and writes nothing" do
      state = consumed_state("reinstall")

      assert {:error, error} = Service.complete_oauth(state, tokens())
      assert error.code == :installation_not_found
      assert_nothing_written()
    end

    test "a reinstall without a bot token fails and leaves the old credentials intact" do
      {:ok, first} = Service.complete_oauth(consumed_state("install"), tokens())

      assert {:error, error} =
               Service.complete_oauth(
                 consumed_state("reinstall"),
                 tokens(%{bot_token: nil})
               )

      assert error.code == :bot_token_missing

      assert Repo.get!(Installation, first.installation.id).encrypted_bot_token ==
               "bot-access-token"
    end
  end

  describe "signin" do
    test "requires an existing installation" do
      state = consumed_state("signin")

      assert {:error, error} = Service.complete_oauth(state, tokens())
      assert error.code == :installation_not_found
      assert_nothing_written()
    end

    test "creates a session without touching the bot credentials" do
      {:ok, first} = Service.complete_oauth(consumed_state("install"), tokens())

      {:ok, result} =
        Service.complete_oauth(
          consumed_state("signin"),
          tokens(%{bot_token: "should-be-ignored", bot_user_id: "other-bot"})
        )

      assert result.installation.encrypted_bot_token == "bot-access-token"
      assert result.installation.bot_user_id == first.installation.bot_user_id
      refute is_nil(result.session_token)
    end

    test "fails when the state names a different workspace than Pumble did" do
      other = installation_fixture("other-workspace")

      state = consumed_state("signin", installation_id: other.id)

      _installation = installation_fixture()

      assert {:error, error} = Service.complete_oauth(state, tokens())
      assert error.code == :oauth_workspace_mismatch
      assert error.class == :conflict

      assert Repo.aggregate(WorkspaceMember, :count) == 0
      assert Repo.aggregate(UserSession, :count) == 0
    end

    test "fails when the state names an installation and Pumble names an unknown workspace" do
      installation = installation_fixture()

      state = consumed_state("signin", installation_id: installation.id)

      assert {:error, error} =
               Service.complete_oauth(
                 state,
                 tokens(%{pumble_workspace_id: "never-seen"})
               )

      assert error.code == :oauth_workspace_mismatch
    end

    test "succeeds when the state's hint matches the workspace Pumble named" do
      {:ok, first} = Service.complete_oauth(consumed_state("install"), tokens())

      state = consumed_state("signin", installation_id: first.installation.id)

      assert {:ok, result} = Service.complete_oauth(state, tokens())
      assert result.installation.id == first.installation.id
    end

    test "is allowed on a revoked installation and does not restore the bot token" do
      {:ok, first} = Service.complete_oauth(consumed_state("install"), tokens())

      {:ok, revoked} =
        first.installation
        |> Installation.changeset(%{
          status: "revoked",
          revoked_at: DateTime.utc_now(),
          encrypted_bot_token: nil,
          token_key_version: nil
        })
        |> Repo.update()

      {:ok, result} = Service.complete_oauth(consumed_state("signin"), tokens())

      assert result.session_token
      reloaded = Repo.get!(Installation, revoked.id)
      assert reloaded.status == "revoked"
      assert reloaded.encrypted_bot_token == nil
    end

    test "is refused after uninstall" do
      {:ok, first} = Service.complete_oauth(consumed_state("install"), tokens())

      {:ok, _uninstalled} =
        first.installation
        |> Installation.changeset(%{status: "uninstalled", uninstalled_at: DateTime.utc_now()})
        |> Repo.update()

      assert {:error, error} =
               Service.complete_oauth(consumed_state("signin"), tokens())

      assert error.code == :installation_unusable
      assert Repo.aggregate(UserSession, :count) == 1
    end
  end

  describe "connect_user" do
    test "refreshes the authorization and creates no session" do
      {:ok, first} = Service.complete_oauth(consumed_state("install"), tokens())

      sessions_before = Repo.aggregate(UserSession, :count)

      {:ok, result} =
        Service.complete_oauth(
          consumed_state("connect_user"),
          tokens(%{access_token: "refreshed-access"})
        )

      assert is_nil(result.session)
      assert is_nil(result.session_token)
      assert result.authorization.encrypted_access_token == "refreshed-access"
      assert result.authorization.id == first.authorization.id
      assert Repo.aggregate(UserSession, :count) == sessions_before
    end

    test "never grants owner" do
      _installation = installation_fixture()

      {:ok, result} = Service.complete_oauth(consumed_state("connect_user"), tokens())

      assert result.member.role == "viewer"
    end
  end

  describe "atomicity" do
    test "a failure after a successful exchange leaves no partial rows" do
      # A user agent hash of the wrong size fails the session changeset, which is
      # the last step before the audit row. Everything earlier has already been
      # written inside the transaction, so this proves the rollback rather than
      # an early return.
      state = consumed_state("install")

      assert {:error, error} =
               Service.complete_oauth(state, tokens(), user_agent_hash: "not-a-32-byte-digest")

      assert error.code == :installation_write_rejected
      assert error.details.step == :session
      assert_nothing_written()
    end

    test "the audit row rolls back with the change it describes" do
      state = consumed_state("install")

      assert {:error, _error} =
               Service.complete_oauth(state, tokens(), user_agent_hash: "not-a-32-byte-digest")

      assert Repo.aggregate(AuditEvent, :count) == 0
    end

    test "an unknown intent cannot reach the writes" do
      state = %OauthState{intent: "escalate", installation_id: nil}

      assert {:error, error} = Service.complete_oauth(state, tokens())
      assert error.code == :installation_not_found
      assert_nothing_written()
    end
  end

  describe "sessions" do
    test "both expiries are set and ordered" do
      now = DateTime.utc_now()
      state = consumed_state("install")

      {:ok, result} = Service.complete_oauth(state, tokens(), now: now)

      session = result.session

      assert DateTime.diff(session.idle_expires_at, now, :second) ==
               Service.session_idle_seconds()

      assert DateTime.diff(session.absolute_expires_at, now, :second) ==
               Service.session_absolute_seconds()

      assert DateTime.compare(session.idle_expires_at, session.absolute_expires_at) == :lt
      assert UserSession.usable?(session, now)
    end

    test "stores a hash of the user agent, never the user agent" do
      state = consumed_state("install")
      hash = :crypto.hash(:sha256, "Mozilla/5.0 (test)")

      {:ok, result} = Service.complete_oauth(state, tokens(), user_agent_hash: hash)

      assert result.session.user_agent_hash == hash
      assert byte_size(result.session.user_agent_hash) == 32
    end

    test "a second sign-in issues a distinct session token" do
      {:ok, first} = Service.complete_oauth(consumed_state("install"), tokens())
      {:ok, second} = Service.complete_oauth(consumed_state("signin"), tokens())

      refute first.session_token == second.session_token
      assert Repo.aggregate(UserSession, :count) == 2
    end
  end

  # The service takes an already-consumed row. Minting and consuming it through
  # the real functions keeps these tests honest about the order the controller
  # uses: consume first, then act.
  defp consumed_state(intent, opts \\ []) do
    {:ok, token, _state} = OauthStates.create(intent, opts)
    {:ok, consumed} = OauthStates.consume(token)
    consumed
  end

  defp workspace, do: Process.get({__MODULE__, :workspace})

  defp tokens(overrides \\ %{}) do
    PumbleFake.tokens(Map.merge(%{pumble_workspace_id: workspace()}, overrides))
  end

  defp installation_fixture(workspace_id \\ nil) do
    Repo.insert!(
      Installation.changeset(%Installation{}, %{
        pumble_workspace_id: workspace_id || workspace(),
        status: "active"
      })
    )
  end

  defp owner_count(installation_id) do
    Repo.aggregate(
      from(member in WorkspaceMember,
        where: member.installation_id == ^installation_id and member.role == "owner"
      ),
      :count
    )
  end

  defp assert_nothing_written do
    assert Repo.aggregate(WorkspaceMember, :count) == 0
    assert Repo.aggregate(UserAuthorization, :count) == 0
    assert Repo.aggregate(UserSession, :count) == 0
    assert Repo.aggregate(AuditEvent, :count) == 0
  end
end
