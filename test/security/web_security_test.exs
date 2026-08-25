defmodule PumbleAutomation.Security.WebSecurityTest do
  @moduledoc """
  Browser and HTTP security: headers, cookies, CSRF, Host allowlist, CORS
  denial, open redirects, body caps, production debug surfaces, and the
  revoked-installation sign-in decision.
  """

  use PumbleAutomationWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.ReturnPaths
  alias PumbleAutomation.Installations.Sessions
  alias PumbleAutomation.Installations.UserSession
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Limits
  alias PumbleAutomation.Repo
  alias PumbleAutomationWeb.BrowserSession
  alias PumbleAutomationWeb.Plugs.HostAllowlist
  alias PumbleAutomationWeb.Plugs.SecurityHeaders

  describe "security headers" do
    test "an HTML page sets CSP, HSTS, nosniff, frame, referrer, and permissions", %{
      conn: conn
    } do
      conn = get(conn, ~p"/")
      assert html_response(conn, 200)
      assert_security_headers(conn)
    end

    test "a JSON health response carries the same headers", %{conn: conn} do
      conn = get(conn, ~p"/health/live")
      assert json_response(conn, 200)
      assert_security_headers(conn)
    end

    test "the router CSP matches the canonical policy" do
      assert SecurityHeaders.csp() =~ "script-src 'self'"
      assert SecurityHeaders.csp() =~ "frame-ancestors 'self'"
      assert SecurityHeaders.csp() =~ "frame-src 'none'"
      refute SecurityHeaders.csp() =~ "*"
      refute SecurityHeaders.csp() =~ "unsafe-eval"
    end
  end

  describe "cookies" do
    test "the Phoenix session cookie is Secure, HttpOnly, and SameSite=Lax", %{conn: conn} do
      conn = get(conn, ~p"/")
      cookie = conn.resp_cookies["_pumble_automation_key"]

      assert cookie.http_only
      assert cookie.secure
      assert cookie.same_site == "Lax"
    end

    test "the browser session cookie keeps its security attributes on sign-in", %{conn: conn} do
      %{session_token: token} = InstallationsFixtures.install()

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
        |> get(~p"/")

      assert html_response(conn, 200)
      opts = BrowserSession.cookie_options()
      assert opts[:http_only]
      assert opts[:secure]
      assert opts[:same_site] == "Lax"
    end
  end

  describe "CSRF" do
    test "sign-out with the browser token revokes the session", %{conn: conn} do
      %{session_token: token, session: session} = InstallationsFixtures.install()

      conn =
        conn
        |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
        |> Plug.Test.init_test_session(%{})
        |> delete(~p"/session/sign-out")

      assert redirected_to(conn) == BrowserSession.sign_in_path()
      assert Repo.get!(UserSession, session.id).revoked_at
    end

    test "sign-out without a CSRF token is refused", %{conn: conn} do
      %{session_token: token, session: session} = InstallationsFixtures.install()

      conn =
        conn
        |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> Plug.Test.init_test_session(%{})

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        delete(conn, ~p"/session/sign-out")
      end

      refute Repo.get!(UserSession, session.id).revoked_at
    end
  end

  describe "host spoofing" do
    @hosts ["automation.example"]

    test "a Host that is not on the allowlist is 400" do
      conn =
        :get
        |> Plug.Test.conn("/")
        |> Map.put(:host, "evil.example")
        |> HostAllowlist.call(allowed_hosts: @hosts)

      assert conn.status == 400
      assert conn.halted
    end

    test "the configured host is admitted" do
      conn =
        :get
        |> Plug.Test.conn("/")
        |> Map.put(:host, "automation.example")
        |> HostAllowlist.call(allowed_hosts: @hosts)

      refute conn.halted
    end

    test "health probes are admitted on any host" do
      conn =
        :get
        |> Plug.Test.conn("/health/live")
        |> Map.put(:host, "evil.example")
        |> HostAllowlist.call(allowed_hosts: @hosts)

      refute conn.halted
    end

    test "X-Forwarded-Host cannot rename the request host" do
      conn =
        :get
        |> Plug.Test.conn("/")
        |> Map.put(:host, "automation.example")
        |> Plug.Conn.put_req_header("x-forwarded-host", "evil.example")
        |> HostAllowlist.call(allowed_hosts: @hosts)

      refute conn.halted
    end

    test "an empty configuration fails closed when an allowlist is required" do
      conn =
        :get
        |> Plug.Test.conn("/")
        |> Map.put(:host, "automation.example")
        |> HostAllowlist.call(allowed_hosts: [])

      assert conn.status == 400
      assert conn.halted
    end
  end

  describe "CORS" do
    test "a cross-origin GET is answered without Access-Control-Allow-Origin", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "https://evil.example")
        |> get(~p"/")

      assert html_response(conn, 200)
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "an OPTIONS preflight does not grant a cross-origin API", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "https://evil.example")
        |> put_req_header("access-control-request-method", "POST")
        |> options("/")

      assert get_resp_header(conn, "access-control-allow-origin") == []
      refute conn.status in [200, 204]
    end
  end

  describe "open redirects" do
    test "OAuth install refuses an off-origin return and stays on a local path", %{conn: conn} do
      for hostile <- ["https://evil.test/steal", "//evil.test", "/\\evil.test"] do
        conn = get(conn, ~p"/oauth/install?return=#{hostile}")

        assert redirected_to(conn) == ReturnPaths.failure_path()
        assert ReturnPaths.local_path?(redirected_to(conn))
      end
    end

    test "the consent redirect uses the configured Pumble host", %{conn: conn} do
      conn = get(conn, ~p"/oauth/install")
      location = redirected_to(conn, 302)

      assert URI.parse(location).host == "app.pumble.com"
      refute location =~ "evil"
    end
  end

  describe "production debug surfaces" do
    test "LiveDashboard is not compiled into this router" do
      refute Application.get_env(:pumble_automation, :dev_routes)

      paths = Enum.map(PumbleAutomationWeb.Router.__routes__(), & &1.path)
      refute Enum.any?(paths, &String.contains?(&1, "dashboard"))
      refute Enum.any?(paths, &String.starts_with?(&1, "/dev"))
    end

    test "the code reloader is off outside development" do
      endpoint = Application.get_env(:pumble_automation, PumbleAutomationWeb.Endpoint)
      refute Keyword.get(endpoint, :code_reloader, false)
    end

    test "production force_ssl exclude is a valid Plug.SSL configuration" do
      {header, _exclude, _host, _rewrite, _log} =
        Plug.SSL.init(
          rewrite_on: [:x_forwarded_proto],
          hsts: true,
          expires: 31_536_000,
          exclude: [
            paths: ["/health/live", "/health/ready"],
            hosts: ["localhost", "127.0.0.1"]
          ]
        )

      assert is_binary(header)
      assert header =~ "max-age=31536000"
    end
  end

  describe "body limits" do
    test "an ordinary JSON POST one byte over the cap is 413", %{conn: conn} do
      body = json_of_size(Limits.get(:max_request_body_bytes) + 1)

      assert_error_sent 413, fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/", body)
      end
    end
  end

  describe "CSP and the page source" do
    test "the public document has no inline script and loads app.js from self", %{conn: conn} do
      conn = get(conn, ~p"/")
      html = html_response(conn, 200)

      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp == SecurityHeaders.csp()
      refute html =~ ~r/<script(?![^>]*\bsrc=)/i
      assert html =~ ~s(src="/assets/js/app.js")
    end
  end

  describe "parameter filtering" do
    test "credential names are listed in the Phoenix filter configuration" do
      source = File.read!("config/config.exs")

      for name <-
            ~w(code state token secret authorization cookie x-webhook-token x-pumble-request-signature) do
        assert source =~ ~s("#{name}")
      end
    end

    test "a planted authorization code does not reach a debug log line", %{conn: conn} do
      code = "code-web-security-must-not-leak"
      level = Logger.level()
      Logger.configure(level: :debug)

      log =
        try do
          capture_log(fn ->
            get(conn, ~p"/oauth/callback?code=#{code}&state=not-a-state")
          end)
        after
          Logger.configure(level: level)
        end

      refute log =~ code
    end
  end

  describe "revoked installation sign-in" do
    test "a new session on a revoked tenant still resolves and does not restore the bot token" do
      %{member: member, installation: installation} = InstallationsFixtures.install()

      installation
      |> Installation.changeset(%{
        status: "revoked",
        revoked_at: DateTime.utc_now(),
        encrypted_bot_token: nil,
        token_key_version: nil
      })
      |> Repo.update!()

      {:ok, %{token: token}} = Sessions.issue(Repo, member)
      assert {:ok, resolved} = Sessions.fetch(token, DateTime.utc_now())
      assert resolved.installation.status == "revoked"
      assert resolved.installation.encrypted_bot_token == nil
    end
  end

  defp assert_security_headers(conn) do
    [csp] = get_resp_header(conn, "content-security-policy")
    assert csp == SecurityHeaders.csp()
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "x-frame-options") == ["SAMEORIGIN"]
    assert get_resp_header(conn, "referrer-policy") == ["strict-origin-when-cross-origin"]

    assert get_resp_header(conn, "strict-transport-security") == [
             "max-age=31536000; includeSubDomains"
           ]

    [permissions] = get_resp_header(conn, "permissions-policy")
    assert permissions =~ "camera=()"
    assert get_resp_header(conn, "cross-origin-resource-policy") == ["same-origin"]
  end

  defp json_of_size(bytes) do
    envelope = ~s({"pad":""})
    padding = bytes - byte_size(envelope)
    ~s({"pad":"#{String.duplicate("x", padding)}"})
  end
end
