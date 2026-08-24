defmodule PumbleAutomationWeb.Browser.TextStressTest do
  @moduledoc """
  Long and translated-like names stay in-column and do not leak secrets.
  """

  use PumbleAutomationWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.ConnectionsFixtures
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomationWeb.BrowserSession

  @long_name "ワークフロー" <> String.duplicate("名", 24) <> " " <> String.duplicate("A", 80)
  @planted "planted-secret-value-never-shown"

  test "a long workflow name truncates on the list and the editor", %{conn: conn} do
    %{session_token: token, installation: installation} =
      InstallationsFixtures.install(role: "editor")

    workflow = workflow(installation.id, %{name: @long_name})
    {:ok, list, html} = live(log_in(conn, token), ~p"/workflows")

    assert has_element?(list, "#workflow-#{workflow.id} h2.truncate")
    assert html =~ "ワークフロー"
    refute html =~ @planted

    {:ok, editor, html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")
    assert has_element?(editor, "h1.pa-break")
    assert html =~ "ワークフロー"
    refute html =~ @planted
  end

  test "a long secret name truncates and never shows its value", %{conn: conn} do
    %{session_token: token, member: member} = InstallationsFixtures.install()
    name = "TOKEN_" <> String.duplicate("X", 48)

    secret = ConnectionsFixtures.secret(Scope.new(member), %{name: name, value: @planted})
    {:ok, view, html} = live(log_in(conn, token), ~p"/secrets")

    assert has_element?(view, "#secret-#{secret.id} h2.truncate")
    assert html =~ "TOKEN_"
    refute html =~ @planted
  end

  test "a long execution workflow name truncates on the timeline", %{conn: conn} do
    %{session_token: token, installation: installation, member: member} =
      InstallationsFixtures.install(role: "editor")

    scope = Scope.new(member)

    workflow =
      drafted_workflow(installation.id, %{
        name: @long_name,
        draft_definition: Definition.encode(definition([delay_node()]))
      })

    {:ok, activated} = Workflows.activate_workflow(scope, workflow.id, 0)

    {:ok, execution} =
      Engine.create(scope, %{
        workflow_version_id: activated.version.id,
        execution_key: "stress-#{System.unique_integer([:positive])}"
      })

    execution = Repo.reload(execution)
    {:ok, view, html} = live(log_in(conn, token), ~p"/executions/#{execution.id}")

    assert has_element?(view, "#execution-summary h2.truncate")
    assert html =~ "ワークフロー"
    refute html =~ @planted
  end

  defp log_in(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
  end
end
