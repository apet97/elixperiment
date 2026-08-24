defmodule PumbleAutomation.Installations.IdentityContractTest do
  @moduledoc """
  The identity lifecycle as one contract, from the stored OAuth fixtures.

  `service_test.exs`, `lifecycle_test.exs`, and `sessions_test.exs` each prove one
  module. This file proves the transitions *between* them: what a second person
  signing in does to a tenant someone else installed, what a reinstall does to a
  scope snapshot that has changed on both sides, what survives a full uninstall,
  and what happens to a session while it is in use. None of those live inside a
  single module, so none of them are covered by a single module's tests.

  Every fact comes from `priv/pumble/fixtures/oauth`, never from an inline map,
  so the shape being asserted against is the one written down and reviewed. The
  cases that a fixture cannot settle are listed in
  `docs/evidence/identity_live_probes.md`.

  Not async: the reinstall scope test changes the requested scopes, which
  `PumbleAutomation.Installations.Service` reads from application configuration.
  """

  use PumbleAutomation.DataCase, async: false

  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Lifecycle
  alias PumbleAutomation.Installations.OauthStates
  alias PumbleAutomation.Installations.Service
  alias PumbleAutomation.Installations.Sessions
  alias PumbleAutomation.Installations.UserAuthorization
  alias PumbleAutomation.Installations.UserSession
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.PumbleFake

  @success "exchange_success.json"
  @without_bot_token "exchange_success_without_bot_token.json"

  describe "a second person signs in to a workspace someone else installed" do
    test "joins the existing tenant without becoming a second owner" do
      workspace = unique_workspace()
      %{installation: installation} = complete("install", workspace, "U_FAKE001")

      %{installation: second, member: member, session_token: token} =
        complete("signin", workspace, "U_FAKE002")

      assert second.id == installation.id
      assert member.role == "viewer"
      assert is_binary(token)

      assert Repo.aggregate(Installation, :count) == 1
      assert Repo.aggregate(WorkspaceMember, :count) == 2
      assert Repo.aggregate(UserAuthorization, :count) == 2
      assert Repo.aggregate(UserSession, :count) == 2
    end

    test "leaves the bot credentials and the installer untouched" do
      workspace = unique_workspace()
      %{installation: installation} = complete("install", workspace, "U_FAKE001")
      before = stored_bot_token(installation.id)

      _second = complete("signin", workspace, "U_FAKE002")

      reloaded = Repo.get!(Installation, installation.id)

      assert stored_bot_token(installation.id) == before
      assert reloaded.installed_by_pumble_user_id == "U_FAKE001"
      assert reloaded.bot_user_id == installation.bot_user_id
    end

    test "the two people hold separate authorizations and separate sessions" do
      workspace = unique_workspace()
      first = complete("install", workspace, "U_FAKE001")
      second = complete("signin", workspace, "U_FAKE002")

      refute first.authorization.id == second.authorization.id
      refute first.session_token == second.session_token

      now = DateTime.utc_now()
      assert {:ok, _resolved} = Sessions.fetch(first.session_token, now)
      assert {:ok, _resolved} = Sessions.fetch(second.session_token, now)
    end
  end

  describe "a reinstall whose scopes changed on both sides" do
    test "replaces the snapshot rather than merging it" do
      put_scopes(bot_scopes: ["channels:read", "messages:write"], user_scopes: ["profile:read"])

      workspace = unique_workspace()
      %{installation: installed} = complete("install", workspace, "U_FAKE001")

      assert installed.bot_scopes == ["channels:read", "messages:write"]
      assert installed.user_scopes == ["profile:read"]

      # `messages:write` is dropped and `reactions:write` is added, so a merge
      # and a replacement produce visibly different rows.
      put_scopes(bot_scopes: ["channels:read", "reactions:write"], user_scopes: ["profile:write"])

      %{installation: reinstalled, authorization: authorization} =
        complete("reinstall", workspace, "U_FAKE001")

      assert reinstalled.id == installed.id
      assert reinstalled.bot_scopes == ["channels:read", "reactions:write"]
      refute "messages:write" in reinstalled.bot_scopes
      assert reinstalled.user_scopes == ["profile:write"]
      assert authorization.scopes == ["profile:write"]
    end

    test "a failed reinstall leaves the previous snapshot in place" do
      put_scopes(bot_scopes: ["channels:read"], user_scopes: ["profile:read"])

      workspace = unique_workspace()
      %{installation: installed} = complete("install", workspace, "U_FAKE001")

      put_scopes(bot_scopes: ["everything:always"], user_scopes: ["everything:always"])

      assert {:error, error} =
               attempt(
                 "reinstall",
                 PumbleFake.tokens_from_fixture(@without_bot_token,
                   pumble_workspace_id: workspace
                 )
               )

      assert error.code == :bot_token_missing

      reloaded = Repo.get!(Installation, installed.id)
      assert reloaded.bot_scopes == ["channels:read"]
      assert reloaded.user_scopes == ["profile:read"]
    end
  end

  describe "an unauthorized installation" do
    test "keeps its revoked status and its erased bot credential when someone signs in" do
      workspace = unique_workspace()
      %{installation: installation} = complete("install", workspace, "U_FAKE001")

      assert {:ok, _unauthorized} = Lifecycle.mark_unauthorized(installation.id)
      assert Repo.get!(Installation, installation.id).status == "revoked"
      assert stored_bot_token(installation.id) == nil

      # The sign-in succeeds: it is a person proving who they are, and it neither
      # reads nor writes a bot credential. What it must not do is make the
      # workspace look installed again, which is the assertion that matters.
      assert {:ok, %{session_token: token}} =
               attempt(
                 "signin",
                 PumbleFake.tokens_from_fixture(@success,
                   pumble_workspace_id: workspace,
                   pumble_user_id: "U_FAKE002"
                 )
               )

      assert is_binary(token)

      reloaded = Repo.get!(Installation, installation.id)
      assert reloaded.status == "revoked"
      assert stored_bot_token(installation.id) == nil
      assert {:ok, _resolved} = Sessions.fetch(token, DateTime.utc_now())
    end

    test "sign-in after uninstall is refused; reinstall is the recovery" do
      workspace = unique_workspace()
      %{installation: installation} = complete("install", workspace, "U_FAKE001")
      {:ok, _uninstalled} = Lifecycle.uninstall(installation.id)

      assert {:error, error} =
               attempt(
                 "signin",
                 PumbleFake.tokens_from_fixture(@success,
                   pumble_workspace_id: workspace,
                   pumble_user_id: "U_FAKE002"
                 )
               )

      assert error.code == :installation_unusable
      assert Repo.get!(Installation, installation.id).status == "uninstalled"
    end

    test "a reinstall is what restores it, and it restores the credential too" do
      workspace = unique_workspace()
      %{installation: installation} = complete("install", workspace, "U_FAKE001")
      {:ok, _unauthorized} = Lifecycle.mark_unauthorized(installation.id)

      %{installation: reinstalled} = complete("reinstall", workspace, "U_FAKE001")

      assert reinstalled.id == installation.id
      assert reinstalled.status == "active"
      assert stored_bot_token(installation.id)
    end
  end

  describe "a full uninstall followed by a reinstall" do
    test "issues fresh credentials and preserves the tenant" do
      workspace = unique_workspace()
      %{installation: installation, member: member} = complete("install", workspace, "U_FAKE001")
      original_ciphertext = stored_bot_token(installation.id)
      audit_before = Repo.aggregate(AuditEvent, :count)

      assert {:ok, uninstalled} = Lifecycle.uninstall(installation.id)
      assert uninstalled.status == "uninstalled"
      assert stored_bot_token(installation.id) == nil

      %{installation: reinstalled} =
        complete("reinstall", workspace, "U_FAKE001", bot_token: "FAKE_BOT_ACCESS_TOKEN_0009")

      assert reinstalled.id == installation.id
      assert reinstalled.pumble_workspace_id == workspace
      assert reinstalled.status == "active"

      ciphertext = stored_bot_token(installation.id)
      assert is_binary(ciphertext)
      refute ciphertext == original_ciphertext

      assert Repo.get!(WorkspaceMember, member.id).role == "owner"
      assert Repo.aggregate(AuditEvent, :count) > audit_before
    end

    test "the sessions the uninstall revoked stay revoked" do
      workspace = unique_workspace()

      %{installation: installation, session_token: token} =
        complete("install", workspace, "U_FAKE001")

      {:ok, _uninstalled} = Lifecycle.uninstall(installation.id)
      assert Sessions.fetch(token, DateTime.utc_now()) == :error

      %{session_token: fresh} = complete("reinstall", workspace, "U_FAKE001")

      assert Sessions.fetch(token, DateTime.utc_now()) == :error
      assert {:ok, _resolved} = Sessions.fetch(fresh, DateTime.utc_now())
    end
  end

  describe "a state that is both expired and reused" do
    test "is refused on the first attempt and on every attempt after it" do
      past = DateTime.add(DateTime.utc_now(), -3_600, :second)
      {:ok, token, _state} = OauthStates.create("install", now: past)

      assert {:error, first} = OauthStates.consume(token)
      assert {:error, second} = OauthStates.consume(token)

      assert first.code == second.code
      assert Repo.aggregate(Installation, :count) == 0
    end

    test "a consumed state is refused again once it has also expired" do
      {:ok, token, _state} = OauthStates.create("install")
      assert {:ok, _state} = OauthStates.consume(token)

      assert {:error, error} = OauthStates.consume(token)
      assert error.class in [:not_found, :conflict, :validation]
    end
  end

  describe "session revocation while a session is in use" do
    test "a revoked session stops resolving from that moment" do
      workspace = unique_workspace()

      %{installation: installation, session_token: token} =
        complete("install", workspace, "U_FAKE001")

      now = DateTime.utc_now()
      assert {:ok, _resolved} = Sessions.fetch(token, now)

      assert Sessions.revoke_all_for_installation(Repo, installation.id, now) == 1
      assert Sessions.fetch(token, now) == :error
    end

    test "a reinstall by a different person ends the sessions issued under the old grant" do
      workspace = unique_workspace()
      %{session_token: first} = complete("install", workspace, "U_FAKE001")

      %{session_token: second} =
        complete("reinstall", workspace, "U_FAKE002", access_token: "FAKE_USER_ACCESS_TOKEN_0002")

      now = DateTime.utc_now()

      assert Sessions.fetch(first, now) == :error
      assert {:ok, _resolved} = Sessions.fetch(second, now)
    end

    test "revocation stops at the tenant boundary" do
      first = complete("install", unique_workspace(), "U_FAKE001")
      second = complete("install", unique_workspace(), "U_FAKE002")

      now = DateTime.utc_now()
      Sessions.revoke_all_for_installation(Repo, first.installation.id, now)

      assert Sessions.fetch(first.session_token, now) == :error
      assert {:ok, _resolved} = Sessions.fetch(second.session_token, now)
    end
  end

  defp complete(intent, workspace, user, overrides \\ []) do
    tokens =
      PumbleFake.tokens_from_fixture(
        @success,
        overrides
        |> Map.new()
        |> Map.merge(%{pumble_workspace_id: workspace, pumble_user_id: user})
      )

    {:ok, result} = attempt(intent, tokens)

    result
  end

  defp attempt(intent, tokens) do
    {:ok, token, _state} = OauthStates.create(intent)
    {:ok, state} = OauthStates.consume(token)

    Service.complete_oauth(state, tokens)
  end

  # Read through SQL, because the schema decrypts: a struct field looks the same
  # whether the ciphertext is still there or not.
  defp stored_bot_token(installation_id) do
    %Postgrex.Result{rows: [[value]]} =
      Repo.query!("SELECT encrypted_bot_token FROM installations WHERE id = $1", [
        Ecto.UUID.dump!(installation_id)
      ])

    value
  end

  defp put_scopes(scopes) do
    pumble = Application.fetch_env!(:pumble_automation, :pumble)
    on_exit(fn -> Application.put_env(:pumble_automation, :pumble, pumble) end)

    Application.put_env(
      :pumble_automation,
      :pumble,
      Keyword.merge(pumble, scopes)
    )
  end

  defp unique_workspace, do: "W_FAKE#{System.unique_integer([:positive])}"
end
