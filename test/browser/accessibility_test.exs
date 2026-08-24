defmodule PumbleAutomationWeb.Browser.AccessibilityTest do
  @moduledoc """
  Landmarks, labels, dialogs, CSP, and field-error associations.
  """

  use PumbleAutomationWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomationWeb.BrowserSession

  describe "landmarks and headings" do
    test "the authenticated shell exposes skip, main, nav, aside, and header", %{conn: conn} do
      %{session_token: token} = InstallationsFixtures.install(role: "editor")
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows")

      assert has_element?(view, "a#skip-to-main[href='#main-content']")
      assert has_element?(view, "main#main-content")
      assert has_element?(view, "aside#app-shell-sidebar[aria-label='Workspace']")
      assert has_element?(view, "header#app-shell-topbar")
      assert has_element?(view, "nav#app-shell-nav[aria-label='Primary']")
      assert has_element?(view, "h1", "Workflows")
      assert has_element?(view, "#nav-workflows[aria-current='page']")
    end

    test "the public shell still skips to main content", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "a#skip-to-main[href='#main-content']")
      assert has_element?(view, "main#main-content")
      assert has_element?(view, "h1")
    end
  end

  describe "labels, dialogs, and errors" do
    test "list filters are labelled and the create dialog is a modal", %{conn: conn} do
      %{session_token: token} = InstallationsFixtures.install(role: "editor")
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows")

      assert has_element?(view, "label[for='filter_q']")
      assert has_element?(view, "#filter_q")
      assert has_element?(view, "label[for='filter_status']")

      view |> element("#create-workflow-action") |> render_click()

      assert has_element?(view, "#workflow-create-modal[role='dialog'][aria-modal='true']")
      assert has_element?(view, "#workflow-create-modal-title", "Create a workflow")
      assert has_element?(view, ~s(#workflow-create-modal[phx-key="Escape"]))
      assert has_element?(view, "label[for='workflow_name']")
    end

    test "a blocking node issue is announced as an alert", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      node = delay_node()
      workflow = drafted_workflow(installation.id, %{draft_definition: encode_steps([node])})
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      view
      |> form("#node-form-#{node.id}-form", %{"config" => %{"duration_seconds" => "0"}})
      |> render_change()

      assert has_element?(view, "#node-form-#{node.id}-issues[role='alert']")
      assert has_element?(view, "#node-form-#{node.id}-issues [data-code=out_of_range]")
    end

    test "theme controls are a labelled pressed group", %{conn: conn} do
      %{session_token: token} = InstallationsFixtures.install(role: "editor")
      {:ok, view, _html} = live(log_in(conn, token), ~p"/")

      assert has_element?(view, "#theme-toggle[role='group'][aria-label='Color theme']")
      assert has_element?(view, "#theme-system[aria-pressed]")
      assert has_element?(view, "#theme-light[aria-label='Use light theme']")
      assert has_element?(view, "#theme-dark[aria-pressed='false']")
    end
  end

  describe "content security policy" do
    test "an authenticated page keeps script-src self and no unsafe-eval", %{conn: conn} do
      %{session_token: token} = InstallationsFixtures.install(role: "editor")
      conn = conn |> log_in(token) |> get(~p"/workflows")

      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'self'"
      assert csp =~ "script-src 'self'"
      refute csp =~ "script-src 'self' 'unsafe-inline'"
      refute csp =~ "unsafe-eval"
    end
  end

  defp encode_steps(nodes) do
    Definition.encode(definition(nodes))
  end

  defp log_in(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
  end
end
