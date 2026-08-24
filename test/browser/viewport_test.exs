defmodule PumbleAutomationWeb.Browser.ViewportTest do
  @moduledoc """
  Responsive classes, shared empty/loading heights, and reduced-motion CSS.
  """

  use PumbleAutomationWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomationWeb.BrowserSession

  @css "assets/css/app.css"

  test "the shell stacks below lg and keeps the content column shrinkable", %{conn: conn} do
    %{session_token: token} = InstallationsFixtures.install(role: "editor")
    {:ok, view, html} = live(log_in(conn, token), ~p"/workflows")

    assert has_element?(view, "#app-shell[data-layout='responsive']")
    assert html =~ "lg:grid-cols-[15rem_minmax(0,1fr)]"
    assert html =~ "min-w-0"
    assert has_element?(view, "#workflows-empty.pa-state")
  end

  test "empty, error, and loading states share a minimum height", %{conn: conn} do
    %{session_token: token} = InstallationsFixtures.install(role: "viewer")
    {:ok, view, _html} = live(log_in(conn, token), ~p"/secrets")

    assert has_element?(view, "#secrets-forbidden.pa-state")
  end

  test "filters wrap on a narrow viewport", %{conn: conn} do
    %{session_token: token, installation: installation} =
      InstallationsFixtures.install(role: "editor")

    _workflow = workflow(installation.id, %{name: "Listed"})
    {:ok, view, html} = live(log_in(conn, token), ~p"/workflows")

    assert html =~ "flex-col gap-3 sm:flex-row"
    assert has_element?(view, "#workflow-filter-form")
  end

  test "design tokens document the viewport matrix and reduced motion", %{conn: _conn} do
    css = File.read!(@css)

    assert css =~ "360 mobile"
    assert css =~ "768 tablet"
    assert css =~ "1280 desktop"
    assert css =~ "prefers-reduced-motion"
    assert css =~ ".pa-state"
    assert css =~ "animation-duration: 0.01ms"
  end

  defp log_in(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
  end
end
