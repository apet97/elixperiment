defmodule PumbleAutomationWeb.OnboardingLiveTest do
  @moduledoc """
  Onboarding states, role-aware navigation, and the CSP-compatible public shell.
  """

  use PumbleAutomationWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomation.WorkflowsFixtures
  alias PumbleAutomationWeb.BrowserSession

  describe "uninstalled" do
    test "a visitor without a session sees the recovery screen", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#onboarding-page[data-state=uninstalled]")
      assert has_element?(view, "#uninstalled-banner")
      assert has_element?(view, "#install-action")
      assert has_element?(view, "#sign-in-action")
      refute has_element?(view, "#app-shell-nav")
      refute has_element?(view, "#first-workflow-action")
    end

    test "the public page sets a Content-Security-Policy", %{conn: conn} do
      conn = get(conn, ~p"/")

      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'self'"
      assert csp =~ "script-src 'self'"
      assert csp =~ "frame-ancestors 'self'"
      refute csp =~ "unsafe-eval"
    end

    test "keyboard users can skip to main content", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "a#skip-to-main")
      assert has_element?(view, "main#main-content")
    end
  end

  describe "revoked" do
    test "a signed-in owner sees reconnect, not a restored workspace", %{conn: conn} do
      %{session_token: token, installation: installation} = InstallationsFixtures.install()

      installation
      |> Installation.changeset(%{
        status: "revoked",
        revoked_at: DateTime.utc_now(),
        encrypted_bot_token: nil,
        token_key_version: nil
      })
      |> Repo.update!()

      {:ok, view, html} = live(log_in(conn, token), ~p"/")

      assert has_element?(view, "#onboarding-page[data-state=revoked]")
      assert has_element?(view, "#revoked-banner")
      assert has_element?(view, "#reinstall-action")
      refute_secrets(html)
    end
  end

  describe "scope-degraded" do
    test "an installed workspace with reduced status shows reinstall", %{conn: conn} do
      %{session_token: token, installation: installation} = InstallationsFixtures.install()

      installation
      |> Installation.changeset(%{status: "degraded"})
      |> Repo.update!()

      {:ok, view, html} = live(log_in(conn, token), ~p"/")

      assert has_element?(view, "#onboarding-page[data-state=scope_degraded]")
      assert has_element?(view, "#scope-degraded-banner")
      assert has_element?(view, "#reinstall-action")
      assert has_element?(view, "#installation-status")
      assert has_element?(view, "#connection-status")
      refute_secrets(html)
    end
  end

  describe "installed with no workflows" do
    test "an editor can reach workflow creation", %{conn: conn} do
      %{session_token: token} = InstallationsFixtures.install(role: "editor")

      {:ok, view, html} = live(log_in(conn, token), ~p"/")

      assert has_element?(view, "#onboarding-page[data-state=installed_empty]")
      assert has_element?(view, "#workflows-empty")
      assert has_element?(view, "#first-workflow-action")
      assert has_element?(view, "#supported-capabilities")
      assert has_element?(view, "#pumble-setup")
      assert has_element?(view, "#pumble-home-state[data-status=pending_certification]")
      assert has_element?(view, "#scope-status", "Recorded install bot scopes")
      assert has_element?(view, "#scope-status", "Current requested bot scopes")
      assert has_element?(view, "#scope-status-note", "not provider-confirmed grants")
      refute has_element?(view, "#scope-status", "Granted bot scopes")
      refute_secrets(html)
    end

    test "a viewer sees the empty state without the create control", %{conn: conn} do
      %{session_token: token} = InstallationsFixtures.install(role: "viewer")

      {:ok, view, _html} = live(log_in(conn, token), ~p"/")

      assert has_element?(view, "#onboarding-page[data-state=installed_empty]")
      assert has_element?(view, "#first-workflow-viewer-note")
      refute has_element?(view, "#first-workflow-action")
    end
  end

  describe "installed with workflows" do
    test "an active workspace lists recent workflow names", %{conn: conn} do
      %{session_token: token, installation: installation} = InstallationsFixtures.install()
      workflow = WorkflowsFixtures.workflow(installation.id, %{name: "Nightly digest"})

      {:ok, view, html} = live(log_in(conn, token), ~p"/")

      assert has_element?(view, "#onboarding-page[data-state=installed_active]")
      assert has_element?(view, "#installed-active-banner")
      assert has_element?(view, "#workflow-name-#{workflow.id}")
      refute has_element?(view, "#first-workflow-action")
      refute_secrets(html)
    end
  end

  describe "role and navigation" do
    test "the signed-in shell stays compact below the desktop rail breakpoint", %{conn: conn} do
      %{session_token: token} = InstallationsFixtures.install(role: "viewer")

      {:ok, view, _html} = live(log_in(conn, token), ~p"/")

      assert has_element?(
               view,
               "aside#app-shell-sidebar[class*='grid-cols-2'][class*='lg:block']"
             )

      assert has_element?(
               view,
               "nav#app-shell-nav[class*='grid-cols-2'][class*='sm:grid-cols-4'][class*='lg:block']"
             )

      assert has_element?(
               view,
               "#workspace-identity[class*='text-right'][class*='lg:text-left']"
             )
    end

    test "every signed-in role sees home, workflows, and executions", %{conn: conn} do
      %{session_token: token} = InstallationsFixtures.install(role: "viewer")

      {:ok, view, _html} = live(log_in(conn, token), ~p"/")

      assert has_element?(view, "#app-shell-nav")
      assert has_element?(view, "#nav-home")
      assert has_element?(view, "#nav-workflows")
      assert has_element?(view, "#nav-executions")
      assert has_element?(view, "#nav-settings")
      assert has_element?(view, "#nav-audit")
      assert has_element?(view, "#role-badge")
      assert has_element?(view, "#sign-out")
      assert has_element?(view, "#workspace-identity")
    end

    test "a viewer does not see owner controls", %{conn: conn} do
      %{session_token: token} = InstallationsFixtures.install(role: "viewer")

      {:ok, view, _html} = live(log_in(conn, token), ~p"/")

      refute has_element?(view, "#nav-members")
      refute has_element?(view, "#nav-secrets")
      refute has_element?(view, "#nav-connections")
    end

    test "an editor does not see member or credential controls", %{conn: conn} do
      %{session_token: token} = InstallationsFixtures.install(role: "editor")

      {:ok, view, _html} = live(log_in(conn, token), ~p"/")

      refute has_element?(view, "#nav-members")
      refute has_element?(view, "#nav-secrets")
      refute has_element?(view, "#nav-connections")
      assert has_element?(view, "#nav-workflows")
    end

    test "an owner sees members, secrets, and connections", %{conn: conn} do
      %{session_token: token} = InstallationsFixtures.install()

      {:ok, view, _html} = live(log_in(conn, token), ~p"/")

      assert has_element?(view, "#nav-members")
      assert has_element?(view, "#nav-secrets")
      assert has_element?(view, "#nav-connections")
      assert has_element?(view, "nav#app-shell-nav[aria-label='Primary']")
    end
  end

  defp log_in(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
  end

  defp refute_secrets(html) do
    refute html =~ "bot-access-token"
    refute html =~ "user-access-token"
  end
end
