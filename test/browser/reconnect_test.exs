defmodule PumbleAutomationWeb.Browser.ReconnectTest do
  @moduledoc """
  Remount is the LiveView reconnect. Server state wins; secrets stay cleared.
  """

  use PumbleAutomationWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Connections
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomationWeb.BrowserSession

  @planted "planted-secret-value-never-shown"

  test "an unsaved editor remount restores the saved outline", %{conn: conn} do
    %{session_token: token, installation: installation, member: member} =
      InstallationsFixtures.install(role: "editor")

    existing = delay_node()

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([existing]))
      })

    path = ~p"/workflows/#{workflow.id}/edit"
    {:ok, view, _html} = live(log_in(conn, token), path)

    view |> element("#step-add-after-#{existing.id}") |> render_click()
    view |> element("#add-type-stop") |> render_click()
    assert render(view) =~ "Stop"

    pid = view.pid
    ref = Process.monitor(pid)
    GenServer.stop(pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    {:ok, view, _html} = live(log_in(conn, token), path)
    refute render(view) =~ "Stop"
    assert has_element?(view, "#step-#{existing.id}")
    assert has_element?(view, ~s(#editor-save-state[data-state="saved"]))

    assert {:ok, saved} = Workflows.get_workflow(Scope.new(member), workflow.id)
    assert {:ok, outline} = Workflow.draft(saved)
    assert Enum.map(outline.steps, & &1.type) == [:delay]
  end

  test "activation confirm does not fire across remount", %{conn: conn} do
    %{session_token: token, installation: installation, member: member} =
      InstallationsFixtures.install(role: "editor")

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([delay_node()]))
      })

    path = ~p"/workflows/#{workflow.id}"
    {:ok, view, _html} = live(log_in(conn, token), path)
    view |> element("#activate-prompt") |> render_click()
    assert has_element?(view, "#activate-confirm")

    {:ok, view, _html} = live(log_in(conn, token), path)
    refute has_element?(view, "#activate-confirm")
    assert Repo.get!(Workflow, workflow.id).status == "draft"

    view |> element("#activate-prompt") |> render_click()
    view |> element("#activate-submit") |> render_click()
    assert Repo.get!(Workflow, workflow.id).status == "active"
    assert {:ok, [version]} = Workflows.list_versions(Scope.new(member), workflow.id)
    assert version.version_number == 1
  end

  test "execution cancel confirm does not cancel across remount", %{conn: conn} do
    %{session_token: token, installation: installation, member: member} =
      InstallationsFixtures.install(role: "editor")

    execution = queued_execution(Scope.new(member), installation.id)
    path = ~p"/executions/#{execution.id}"

    {:ok, view, _html} = live(log_in(conn, token), path)
    view |> element("#cancel-prompt") |> render_click()
    assert has_element?(view, "#cancel-confirm")

    {:ok, view, html} = live(log_in(conn, token), path)
    refute has_element?(view, "#cancel-confirm")
    refute html =~ @planted
    assert Repo.get!(Execution, execution.id).status == "queued"
  end

  test "a secret value is gone after submit and after remount", %{conn: conn} do
    %{session_token: token, member: member} = InstallationsFixtures.install()

    {:ok, view, html} = live(log_in(conn, token), ~p"/secrets/new")
    refute html =~ @planted
    assert has_element?(view, "#secret-form")
    assert has_element?(view, ~s(#secret-value[type="password"]))

    {:ok, view, html} = live(log_in(conn, token), ~p"/secrets/new")
    refute html =~ @planted
    assert has_element?(view, "#secret-value")

    html =
      view
      |> form("#secret-form",
        secret: %{name: "RECONNECT_TOKEN", kind: "generic", value: @planted}
      )
      |> render_submit()

    refute html =~ @planted
    refute has_element?(view, "#secret-form")

    {:ok, _view, html} = live(log_in(conn, token), ~p"/secrets")
    refute html =~ @planted

    assert {:ok, [secret]} = Connections.list_secrets(Scope.new(member))
    assert secret.name == "RECONNECT_TOKEN"
  end

  defp queued_execution(scope, installation_id) do
    workflow =
      drafted_workflow(installation_id, %{
        draft_definition: Definition.encode(definition([delay_node()]))
      })

    {:ok, activated} = Workflows.activate_workflow(scope, workflow.id, 0)

    {:ok, execution} =
      Engine.create(scope, %{
        workflow_version_id: activated.version.id,
        execution_key: "ui-#{System.unique_integer([:positive])}"
      })

    Repo.get!(Execution, execution.id)
  end

  defp log_in(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
  end
end
