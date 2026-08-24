defmodule PumbleAutomationWeb.Browser.KeyboardTest do
  @moduledoc """
  Keyboard-operable primary flows. Drag is optional; buttons remain the path.
  """

  use PumbleAutomationWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomationWeb.BrowserSession

  test "an editor can create a draft with labelled controls", %{conn: conn} do
    %{session_token: token, member: member} = InstallationsFixtures.install(role: "editor")
    {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows")

    view |> element("#create-workflow-action") |> render_click()

    view
    |> form("#workflow-create-form", workflow: %{name: "Keyboard draft", template: "blank"})
    |> render_submit()

    assert {:ok, [%Workflow{name: "Keyboard draft"}]} =
             Workflows.list_workflows(Scope.new(member))
  end

  test "move buttons reorder a sequence without drag", %{conn: conn} do
    %{session_token: token, installation: installation, member: member} =
      InstallationsFixtures.install(role: "editor")

    first = delay_node()
    second = stop_node()

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([first, second]))
      })

    {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

    assert has_element?(view, "#step-move-up-#{first.id}[disabled]")
    assert has_element?(view, "#step-move-down-#{second.id}[disabled]")

    view |> element("#step-move-up-#{second.id}") |> render_click()
    view |> element("#editor-save") |> render_click()

    assert {:ok, saved} = Workflows.get_workflow(Scope.new(member), workflow.id)
    assert {:ok, outline} = Workflow.draft(saved)
    assert Enum.map(outline.steps, & &1.id) == [second.id, first.id]
  end

  test "a confirmation cancel control leaves the resource unchanged", %{conn: conn} do
    %{session_token: token, installation: installation} =
      InstallationsFixtures.install(role: "editor")

    leaf = stop_node()
    parent = condition_node(if_true: [leaf])

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([parent]))
      })

    {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

    view |> element("#step-delete-#{parent.id}") |> render_click()
    assert has_element?(view, "#editor-confirm-delete[role='dialog']")
    view |> element("#editor-cancel-delete") |> render_click()

    refute has_element?(view, "#editor-confirm-delete")
    assert has_element?(view, "#step-#{parent.id}")
    assert has_element?(view, "#step-#{leaf.id}")
  end

  test "Escape is wired on confirm dialogs", %{conn: conn} do
    %{session_token: token, installation: installation, member: member} =
      InstallationsFixtures.install(role: "editor")

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([delay_node()]))
      })

    {:ok, _} = Workflows.activate_workflow(Scope.new(member), workflow.id, 0)
    {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows")

    view |> element("#workflow-deactivate-#{workflow.id}") |> render_click()
    assert has_element?(view, ~s(#workflow-confirm-deactivate[phx-key="Escape"]))
    assert has_element?(view, "#workflow-confirm-deactivate[role='dialog']")

    view |> element("#workflow-cancel-confirm") |> render_click()
    refute has_element?(view, "#workflow-confirm-deactivate")
    assert Repo.get!(Workflow, workflow.id).status == "active"
  end

  defp log_in(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
  end
end
