defmodule PumbleAutomationWeb.OauthControllerTest do
  @moduledoc """
  The browser round trip, end to end against a stubbed Pumble.

  These tests exercise the ordering the controller depends on — consume, then
  exchange, then persist — because that order is what makes a duplicate callback
  safe. A test that only checked the happy path would pass against a controller
  that exchanged first and consumed afterwards.

  The suite is `async: false`: the redaction test lowers the global log level to
  prove the authorization code never reaches a log line at any level.
  """

  use PumbleAutomationWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.OauthState
  alias PumbleAutomation.Installations.OauthStates
  alias PumbleAutomation.Installations.ReturnPaths
  alias PumbleAutomation.Installations.UserSession
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.PumbleFake
  alias PumbleAutomation.Repo
  alias PumbleAutomationWeb.OauthController

  describe "GET /oauth/install" do
    test "mints a state and redirects to the configured consent screen", %{conn: conn} do
      conn = get(conn, ~p"/oauth/install")

      assert redirected_to(conn, 302) =~ "https://app.pumble.com/access-request"

      assert [state] = Repo.all(OauthState)
      assert state.intent == "install"
      assert is_nil(state.consumed_at)
    end

    test "the consent URL carries the client id, the redirect URI, and the state", %{conn: conn} do
      conn = get(conn, ~p"/oauth/install")

      %URI{query: query} = URI.parse(redirected_to(conn, 302))
      params = URI.decode_query(query)

      assert params["clientId"] == "test-client-id"
      assert params["redirectUrl"] == "http://localhost:4002/oauth/callback"
      assert is_binary(params["state"])

      # The state travelling to Pumble is the token; the database holds its digest.
      assert [stored] = Repo.all(OauthState)
      assert stored.state_digest == OauthState.digest(params["state"])
      refute stored.state_digest == params["state"]
    end

    test "a reinstall is flagged as one", %{conn: conn} do
      conn = get(conn, ~p"/oauth/install?intent=reinstall")

      params = conn |> redirected_to(302) |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      assert params["isReinstall"] == "true"
      assert [state] = Repo.all(OauthState)
      assert state.intent == "reinstall"
    end

    test "an install is not flagged as a reinstall", %{conn: conn} do
      conn = get(conn, ~p"/oauth/install")

      params = conn |> redirected_to(302) |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      refute Map.has_key?(params, "isReinstall")
    end

    test "passes a workspace hint through when one is given", %{conn: conn} do
      conn = get(conn, ~p"/oauth/install?workspace=ws-42")

      params = conn |> redirected_to(302) |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      assert params["defaultWorkspaceId"] == "ws-42"
    end

    test "refuses an unknown intent without minting a state", %{conn: conn} do
      conn = get(conn, ~p"/oauth/install?intent=become_owner")

      assert redirected_to(conn) == ReturnPaths.failure_path()
      assert Repo.aggregate(OauthState, :count) == 0
    end

    test "refuses an off-origin return destination without minting a state", %{conn: conn} do
      for hostile <- ["https://evil.test", "//evil.test", "/etc/passwd"] do
        conn = get(conn, ~p"/oauth/install?return=#{hostile}")

        assert redirected_to(conn) == ReturnPaths.failure_path()
        assert Repo.aggregate(OauthState, :count) == 0
      end
    end
  end

  describe "GET /oauth/callback success" do
    test "installs the workspace and sets the session cookie", %{conn: conn} do
      PumbleFake.stub_success()
      token = mint_state("install")

      conn = get(conn, ~p"/oauth/callback?code=auth-code&state=#{token}")

      assert redirected_to(conn) == "/"

      assert [installation] = Repo.all(Installation)
      assert installation.pumble_workspace_id == "pumble-workspace-1"
      assert [member] = Repo.all(WorkspaceMember)
      assert member.role == "owner"
      assert [session] = Repo.all(UserSession)

      cookie = conn.resp_cookies[OauthController.session_cookie()]

      assert cookie.http_only
      assert cookie.secure
      assert cookie.same_site == "Lax"
      assert cookie.path == "/"
      assert session.token_digest == UserSession.digest(cookie.value)
    end

    test "the cookie carries the token and the database carries only its digest", %{conn: conn} do
      PumbleFake.stub_success()
      token = mint_state("install")

      conn = get(conn, ~p"/oauth/callback?code=auth-code&state=#{token}")

      value = conn.resp_cookies[OauthController.session_cookie()].value

      assert [session] = Repo.all(UserSession)
      refute session.token_digest == value
      assert session.token_digest == UserSession.digest(value)
    end

    test "returns the browser to the destination the state named", %{conn: conn} do
      PumbleFake.stub_success()
      token = mint_state("install", return_path_key: "home")

      conn = get(conn, ~p"/oauth/callback?code=auth-code&state=#{token}")

      assert redirected_to(conn) == "/"
    end

    test "a sign-in sets a cookie without granting owner", %{conn: conn} do
      PumbleFake.stub_success()
      install_token = mint_state("install")
      _ = get(conn, ~p"/oauth/callback?code=auth-code&state=#{install_token}")

      PumbleFake.stub_success(%{"userId" => "pumble-user-2"})
      signin_token = mint_state("signin")

      conn = get(build_conn(), ~p"/oauth/callback?code=auth-code-2&state=#{signin_token}")

      assert redirected_to(conn) == "/"
      assert conn.resp_cookies[OauthController.session_cookie()]

      roles = WorkspaceMember |> Repo.all() |> Enum.map(& &1.role) |> Enum.sort()
      assert roles == ["owner", "viewer"]
    end
  end

  describe "GET /oauth/callback failure" do
    test "a reused state is refused and exchanges no code", %{conn: conn} do
      PumbleFake.stub_success()
      token = mint_state("install")

      first = get(conn, ~p"/oauth/callback?code=auth-code&state=#{token}")
      assert first.resp_cookies[OauthController.session_cookie()]

      # If the second callback reached the exchange, this stub would fail the test.
      Req.Test.stub(PumbleAutomation.Pumble.OauthClient, fn _conn ->
        flunk("a consumed state must never reach the code exchange")
      end)

      second = get(build_conn(), ~p"/oauth/callback?code=auth-code&state=#{token}")

      assert redirected_to(second) == ReturnPaths.failure_path()
      refute second.resp_cookies[OauthController.session_cookie()]
      assert Repo.aggregate(Installation, :count) == 1
      assert Repo.aggregate(UserSession, :count) == 1
    end

    test "an unknown state never reaches the exchange", %{conn: conn} do
      Req.Test.stub(PumbleAutomation.Pumble.OauthClient, fn _conn ->
        flunk("an unknown state must never reach the code exchange")
      end)

      conn = get(conn, ~p"/oauth/callback?code=auth-code&state=not-a-real-state")

      assert redirected_to(conn) == ReturnPaths.failure_path()
      assert_nothing_installed()
    end

    test "an expired state is refused", %{conn: conn} do
      past = DateTime.add(DateTime.utc_now(), -3_600, :second)
      {:ok, token, _state} = OauthStates.create("install", now: past)

      conn = get(conn, ~p"/oauth/callback?code=auth-code&state=#{token}")

      assert redirected_to(conn) == ReturnPaths.failure_path()
      assert_nothing_installed()
    end

    test "a missing code or a missing state fails closed", %{conn: conn} do
      token = mint_state("install")

      for query <- ["code=auth-code", "state=#{token}", ""] do
        result = get(build_conn(), "/oauth/callback?" <> query)

        assert redirected_to(result) == ReturnPaths.failure_path()
        refute result.resp_cookies[OauthController.session_cookie()]
      end

      assert_nothing_installed()
      assert conn.state == :unset
    end

    test "a malformed exchange response leaves the state consumed and nothing written",
         %{conn: conn} do
      PumbleFake.stub_malformed(:not_json)
      token = mint_state("install")

      conn = get(conn, ~p"/oauth/callback?code=auth-code&state=#{token}")

      assert redirected_to(conn) == ReturnPaths.failure_path()
      assert_nothing_installed()

      # Consumed, so the code cannot be replayed through the same state.
      assert [state] = Repo.all(OauthState)
      refute is_nil(state.consumed_at)
    end

    test "a timeout fails closed", %{conn: conn} do
      PumbleFake.stub_timeout()
      token = mint_state("install")

      conn = get(conn, ~p"/oauth/callback?code=auth-code&state=#{token}")

      assert redirected_to(conn) == ReturnPaths.failure_path()
      assert_nothing_installed()
    end

    test "a rejected exchange fails closed", %{conn: conn} do
      PumbleFake.stub_json(400, %{"error" => "invalid_grant"})
      token = mint_state("install")

      conn = get(conn, ~p"/oauth/callback?code=auth-code&state=#{token}")

      assert redirected_to(conn) == ReturnPaths.failure_path()
      assert_nothing_installed()
    end

    test "a grant without a bot token installs nothing", %{conn: conn} do
      PumbleFake.stub_success(%{"botToken" => nil, "botId" => nil})
      token = mint_state("install")

      conn = get(conn, ~p"/oauth/callback?code=auth-code&state=#{token}")

      assert redirected_to(conn) == ReturnPaths.failure_path()
      refute conn.resp_cookies[OauthController.session_cookie()]
      assert_nothing_installed()
    end

    test "a sign-in for a workspace that never installed fails closed", %{conn: conn} do
      PumbleFake.stub_success()
      token = mint_state("signin")

      conn = get(conn, ~p"/oauth/callback?code=auth-code&state=#{token}")

      assert redirected_to(conn) == ReturnPaths.failure_path()
      assert_nothing_installed()
    end

    test "records an audit event with a correlation id and no credential", %{conn: conn} do
      PumbleFake.stub_json(400, %{})
      token = mint_state("install")

      _conn = get(conn, ~p"/oauth/callback?code=auth-code-xyz&state=#{token}")

      assert [event] = Repo.all(AuditEvent)
      assert event.action == "oauth.callback_failed"
      assert event.actor_type == "system"
      assert is_nil(event.installation_id)
      assert {:ok, _uuid} = Ecto.UUID.cast(event.correlation_id)
      assert event.metadata["result"] == "error"
      assert event.metadata["reason"] == "oauth_exchange_rejected"

      refute inspect(event) =~ "auth-code-xyz"
    end
  end

  describe "the stored exchange fixtures" do
    test "a complete grant installs the workspace the fixture names", %{conn: conn} do
      PumbleFake.stub_oauth_fixture("exchange_success.json")
      body = PumbleFake.oauth_fixture_body("exchange_success.json")
      token = mint_state("install")

      conn = get(conn, ~p"/oauth/callback?code=auth-code&state=#{token}")

      assert redirected_to(conn) == "/"
      assert [installation] = Repo.all(Installation)
      assert installation.pumble_workspace_id == body["workspaceId"]
      assert installation.bot_user_id == body["botId"]
      assert installation.installed_by_pumble_user_id == body["userId"]
    end

    test "a grant without a bot token installs nothing", %{conn: conn} do
      PumbleFake.stub_oauth_fixture("exchange_success_without_bot_token.json")
      token = mint_state("install")

      conn = get(conn, ~p"/oauth/callback?code=auth-code&state=#{token}")

      assert redirected_to(conn) == ReturnPaths.failure_path()
      assert_nothing_installed()
    end

    test "a response missing a required field installs nothing", %{conn: conn} do
      PumbleFake.stub_oauth_fixture("exchange_malformed.json")
      token = mint_state("install")

      conn = get(conn, ~p"/oauth/callback?code=auth-code&state=#{token}")

      assert redirected_to(conn) == ReturnPaths.failure_path()
      assert_nothing_installed()
    end

    test "a response that is not JSON installs nothing", %{conn: conn} do
      PumbleFake.stub_oauth_fixture("exchange_not_json.json")
      token = mint_state("install")

      conn = get(conn, ~p"/oauth/callback?code=auth-code&state=#{token}")

      assert redirected_to(conn) == ReturnPaths.failure_path()
      assert_nothing_installed()
    end

    test "a rejected exchange installs nothing", %{conn: conn} do
      PumbleFake.stub_oauth_fixture("exchange_error.json")
      token = mint_state("install")

      conn = get(conn, ~p"/oauth/callback?code=auth-code&state=#{token}")

      assert redirected_to(conn) == ReturnPaths.failure_path()
      assert_nothing_installed()
    end

    test "no fixture anywhere carries a value that could be a real credential or id" do
      # Every fixture, not only the OAuth ones: a leaked secret is a leaked
      # secret whichever directory it was committed to.
      root = Application.app_dir(:pumble_automation, "priv/pumble/fixtures")
      files = Path.wildcard(Path.join(root, "**/*.json"))

      assert length(files) > 1, "the fixture set must actually be found"

      for path <- files do
        contents = File.read!(path)
        name = Path.relative_to(path, root)

        refute contents =~ "test-client-secret", "#{name} carries a configured secret"

        refute contents =~ ~r/"(accessToken|botToken|signing_secret)":\s*"(?!FAKE)/,
               "#{name} carries a token that is not marked fake"

        # The optional backslashes matter: a signature fixture carries its body
        # as an escaped JSON string, so the identifiers inside it are written
        # `\"aId\": \"…\"` and a pattern without them would silently pass.
        refute contents =~
                 ~r/\\?"(userId|botId|workspaceId|aId|cId|mId)\\?":\s*\\?"(?![UBWCM]_FAKE)/,
               "#{name} carries an identifier that is not obviously fake"
      end
    end
  end

  describe "redaction" do
    setup do
      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)
    end

    test "the authorization code never reaches a log line or the response", %{conn: conn} do
      PumbleFake.stub_json(400, %{})
      token = mint_state("install")
      code = "code-3f9a2b7c-must-not-leak"

      log =
        capture_log(fn ->
          conn = get(conn, ~p"/oauth/callback?code=#{code}&state=#{token}")

          refute conn.resp_body =~ code
          refute redirected_to(conn) =~ code
        end)

      refute log =~ code
      refute log =~ "test-client-secret"
    end

    test "the state token never reaches a log line", %{conn: conn} do
      PumbleFake.stub_success()
      token = mint_state("install")

      log = capture_log(fn -> get(conn, ~p"/oauth/callback?code=auth-code&state=#{token}") end)

      refute log =~ token
    end

    test "the session token never reaches a log line", %{conn: conn} do
      PumbleFake.stub_success()
      token = mint_state("install")

      {log, session_token} =
        with_log(fn ->
          conn = get(conn, ~p"/oauth/callback?code=auth-code&state=#{token}")
          conn.resp_cookies[OauthController.session_cookie()].value
        end)

      refute log =~ session_token
    end

    test "one capture over a failing and a succeeding callback leaks nothing", %{conn: conn} do
      # Both halves in one capture, because the two paths write different lines:
      # a failure logs an error and an audit write, a success logs a redirect and
      # a session. A test that captured only one of them would prove only half.
      failing_code = "code-fail-8e21c4-must-not-leak"
      succeeding_code = "code-ok-5b73d9-must-not-leak"
      failing_state = mint_state("install")
      succeeding_state = mint_state("install")

      {log, session_token} =
        with_log(fn ->
          PumbleFake.stub_oauth_fixture("exchange_error.json")
          failed = get(conn, ~p"/oauth/callback?code=#{failing_code}&state=#{failing_state}")
          assert redirected_to(failed) == ReturnPaths.failure_path()

          PumbleFake.stub_oauth_fixture("exchange_success.json")

          ok =
            get(
              build_conn(),
              ~p"/oauth/callback?code=#{succeeding_code}&state=#{succeeding_state}"
            )

          assert redirected_to(ok) == "/"

          ok.resp_cookies[OauthController.session_cookie()].value
        end)

      for secret <- [
            failing_code,
            succeeding_code,
            failing_state,
            succeeding_state,
            session_token,
            "test-client-secret",
            PumbleFake.oauth_fixture_body("exchange_success.json")["botToken"],
            PumbleFake.oauth_fixture_body("exchange_success.json")["accessToken"]
          ] do
        refute log =~ secret, "#{String.slice(secret, 0, 8)}… reached a log line"
      end
    end

    test "Phoenix's parameter filter redacts the OAuth round trip" do
      # Asserted through the function that does the filtering rather than through
      # the configuration value, which Phoenix compiles into an opaque form at
      # boot. This is what a request log would actually contain.
      filtered =
        Phoenix.Logger.filter_values(%{
          "code" => "auth-code-must-not-leak",
          "state" => "state-token-must-not-leak",
          "intent" => "install"
        })

      assert filtered["code"] == "[FILTERED]"
      assert filtered["state"] == "[FILTERED]"
      assert filtered["intent"] == "install", "a non-secret parameter stays readable"
    end
  end

  defp mint_state(intent, opts \\ []) do
    {:ok, token, _state} = OauthStates.create(intent, opts)
    token
  end

  defp assert_nothing_installed do
    assert Repo.aggregate(Installation, :count) == 0
    assert Repo.aggregate(WorkspaceMember, :count) == 0
    assert Repo.aggregate(UserSession, :count) == 0
  end
end
