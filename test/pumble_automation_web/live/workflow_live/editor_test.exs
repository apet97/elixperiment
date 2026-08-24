defmodule PumbleAutomationWeb.WorkflowLive.EditorTest do
  @moduledoc """
  Nested outline editor: structure edits, conflict, limits, keyboard, reconnect.
  """

  use PumbleAutomationWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Limits
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomationWeb.BrowserSession

  describe "auth and roles" do
    test "a visitor is sent to sign-in", %{conn: conn} do
      id = Ecto.UUID.generate()
      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/workflows/#{id}/edit")
      assert to == BrowserSession.sign_in_path()
    end

    test "another workspace's workflow does not leak existence", %{conn: conn} do
      %{session_token: token} = InstallationsFixtures.install(role: "editor")
      other = InstallationsFixtures.install()
      theirs = drafted_workflow(other.installation.id)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(log_in(conn, token), ~p"/workflows/#{theirs.id}/edit")

      assert to == ~p"/workflows"
    end

    test "a viewer can open the outline without mutation controls", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "viewer")

      node = delay_node()
      workflow = workflow_with(installation.id, [node])

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      assert has_element?(view, "#workflow-editor")
      assert has_element?(view, "#workflow-trigger")
      assert has_element?(view, "#step-#{node.id}")
      refute has_element?(view, "#root-add-step")
      refute has_element?(view, "#step-delete-#{node.id}")
      refute has_element?(view, "#editor-save")
    end

    test "viewer mutation events are denied server-side", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "viewer")

      node = delay_node()
      workflow = workflow_with(installation.id, [node])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      html = render_click(view, "save", %{})
      assert html =~ "You do not have permission to do that."
      assert has_element?(view, "#step-#{node.id}")
    end
  end

  describe "edit operations" do
    test "an editor can add before, after, and into a branch", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      nested = stop_node()
      condition = condition_node(if_true: [nested])
      workflow = workflow_with(installation.id, [condition])

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      view |> element("#step-add-before-#{condition.id}") |> render_click()
      view |> element("#add-type-delay") |> render_click()

      view |> element("#step-add-after-#{condition.id}") |> render_click()
      view |> element("#add-type-stop") |> render_click()

      view |> element("#branch-add-#{condition.id}-if_false") |> render_click()
      view |> element("#add-type-http_action") |> render_click()

      view |> element("#editor-save") |> render_click()

      assert {:ok, saved} = Workflows.get_workflow(Scope.new(member), workflow.id)
      assert {:ok, definition} = Workflow.draft(saved)
      assert Enum.map(definition.steps, & &1.type) == [:delay, :condition, :stop]

      updated = Enum.find(definition.steps, &(&1.id == condition.id))
      assert [%Node{id: nested_id}] = Node.branch(updated, :if_true)
      assert nested_id == nested.id
      assert [%Node{type: :http_action}] = Node.branch(updated, :if_false)
    end

    test "deleting a subtree asks for confirmation and then removes it", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      leaf = stop_node()
      condition = condition_node(if_true: [leaf])
      workflow = workflow_with(installation.id, [condition])

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      view |> element("#step-delete-#{condition.id}") |> render_click()
      assert has_element?(view, "#editor-confirm-delete")
      assert has_element?(view, "#step-#{condition.id}")
      assert has_element?(view, "#step-#{leaf.id}")

      view |> element("#editor-confirm-delete-submit") |> render_click()
      refute has_element?(view, "#step-#{condition.id}")
      refute has_element?(view, "#step-#{leaf.id}")

      view |> element("#editor-save") |> render_click()
      assert {:ok, saved} = Workflows.get_workflow(Scope.new(member), workflow.id)
      assert {:ok, definition} = Workflow.draft(saved)
      assert definition.steps == []
    end

    test "keyboard buttons reorder a sequence", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      first = delay_node()
      second = stop_node()
      workflow = workflow_with(installation.id, [first, second])

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      assert has_element?(view, "#step-number-#{first.id}", "1")
      view |> element("#step-move-down-#{first.id}") |> render_click()
      assert has_element?(view, "#step-number-#{first.id}", "2")
      assert has_element?(view, "#step-number-#{second.id}", "1")

      view |> element("#editor-save") |> render_click()
      assert {:ok, saved} = Workflows.get_workflow(Scope.new(member), workflow.id)
      assert {:ok, definition} = Workflow.draft(saved)
      assert Enum.map(definition.steps, & &1.id) == [second.id, first.id]
    end

    test "a drag reorder event uses ids and a branch path, not indexes", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      first = delay_node()
      second = stop_node()
      workflow = workflow_with(installation.id, [first, second])

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      view
      |> element("#workflow-outline")
      |> render_hook("reorder", %{
        "source_id" => first.id,
        "target_id" => second.id,
        "branch_path" => "root"
      })

      assert has_element?(view, "#step-number-#{first.id}", "2")
      view |> element("#editor-save") |> render_click()

      assert {:ok, saved} = Workflows.get_workflow(Scope.new(member), workflow.id)
      assert {:ok, definition} = Workflow.draft(saved)
      assert Enum.map(definition.steps, & &1.id) == [second.id, first.id]
    end
  end

  describe "conflict, reconnect, limits, and abuse" do
    test "two sessions keep local intent on a revision conflict", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      existing = delay_node()
      workflow = workflow_with(installation.id, [existing])
      path = ~p"/workflows/#{workflow.id}/edit"

      {:ok, session_a, _html} = live(log_in(conn, token), path)
      {:ok, session_b, _html} = live(log_in(build_conn(), token), path)

      session_a |> element("#step-add-after-#{existing.id}") |> render_click()
      session_a |> element("#add-type-stop") |> render_click()
      session_a |> element("#editor-save") |> render_click()
      assert has_element?(session_a, ~s(#editor-save-state[data-state="saved"]))

      session_b |> element("#step-add-after-#{existing.id}") |> render_click()
      session_b |> element("#add-type-approval") |> render_click()
      session_b |> element("#editor-save") |> render_click()

      assert has_element?(session_b, "#editor-conflict")
      assert has_element?(session_b, ~s(#editor-save-state[data-state="conflict"]))
      assert render(session_b) =~ "Approval"

      session_b |> element("#editor-reload") |> render_click()
      refute has_element?(session_b, "#editor-conflict")
      assert render(session_b) =~ "Stop"
      refute render(session_b) =~ "Approval"

      assert {:ok, saved} = Workflows.get_workflow(Scope.new(member), workflow.id)
      assert {:ok, definition} = Workflow.draft(saved)
      assert Enum.map(definition.steps, & &1.type) == [:delay, :stop]
    end

    test "reconnect restores the saved outline", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      workflow = workflow_with(installation.id, [])
      path = ~p"/workflows/#{workflow.id}/edit"

      {:ok, view, _html} = live(log_in(conn, token), path)
      view |> element("#root-add-step") |> render_click()
      view |> element("#add-type-delay") |> render_click()
      view |> element("#editor-save") |> render_click()

      assert {:ok, saved} = Workflows.get_workflow(Scope.new(member), workflow.id)
      assert {:ok, definition} = Workflow.draft(saved)
      [%Node{id: node_id}] = definition.steps

      {:ok, view, _html} = live(log_in(conn, token), path)
      assert has_element?(view, "#step-#{node_id}")
      assert has_element?(view, ~s(#editor-save-state[data-state="saved"]))
    end

    test "node and depth limits are reported without applying the edit", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      full = Enum.map(1..Limits.max_nodes(), fn _index -> stop_node() end)
      workflow = workflow_with(installation.id, full)
      last = List.last(full)

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")
      view |> element("#step-add-after-#{last.id}") |> render_click()
      html = view |> element("#add-type-delay") |> render_click()
      assert html =~ "The workflow has too many steps."
      refute has_element?(view, "h3", "Delay")

      deep = nested_conditions(Limits.max_depth())
      deep_workflow = workflow_with(installation.id, [deep])
      innermost = deep_workflow |> loaded_definition() |> Definition.nodes() |> List.last()

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{deep_workflow.id}/edit")
      view |> element("#branch-add-#{innermost.id}-if_true") |> render_click()
      html = view |> element("#add-type-stop") |> render_click()
      assert html =~ "The workflow branches are nested too deeply."
      refute has_element?(view, "#sequence-#{innermost.id}-if_true [data-node-id]")
    end

    test "malformed payloads are ignored, audited, and do not crash", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      node = delay_node()
      workflow = workflow_with(installation.id, [node])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      html =
        render_hook(element(view, "#workflow-outline"), "reorder", %{
          "source_id" => node.id,
          "target_id" => node.id,
          "branch_path" => "root",
          "installation_id" => Ecto.UUID.generate(),
          "from" => "0",
          "to" => "9"
        })

      assert has_element?(view, "#step-#{node.id}")
      assert html =~ "Delay"

      render_click(view, "delete", %{
        "id" => "not-a-uuid",
        "installation_id" => Ecto.UUID.generate()
      })

      render_click(view, "move_up", %{"id" => Ecto.UUID.generate()})

      render_hook(element(view, "#workflow-outline"), "reorder", %{
        "source_id" => node.id,
        "from" => "0",
        "to" => "1"
      })

      assert has_element?(view, "#step-#{node.id}")

      events =
        Repo.all(
          from event in AuditEvent,
            where:
              event.action == "workflow.editor_event_rejected" and
                event.resource_id == ^workflow.id
        )

      assert events != []
    end
  end

  defp workflow_with(installation_id, nodes) do
    drafted_workflow(installation_id, %{draft_definition: Definition.encode(definition(nodes))})
  end

  defp loaded_definition(%Workflow{} = workflow) do
    {:ok, definition} = Workflow.draft(workflow)
    definition
  end

  defp nested_conditions(1), do: condition_node()

  defp nested_conditions(depth) when depth > 1 do
    condition_node(if_true: [nested_conditions(depth - 1)])
  end

  defp log_in(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
  end
end
