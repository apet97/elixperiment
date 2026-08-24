defmodule PumbleAutomationWeb.WorkflowLive.IndexTest do
  @moduledoc """
  Workflow list, creation, duplication, role policy, and bounded queries.
  """

  use PumbleAutomationWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.ManualAlias
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomationWeb.BrowserSession

  describe "auth and roles" do
    test "a visitor is sent to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/workflows")
      assert to == BrowserSession.sign_in_path()
    end

    test "an editor sees create and duplicate controls", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      workflow = workflow(installation.id, %{name: "Nightly digest"})

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows")

      assert has_element?(view, "#workflow-index")
      assert has_element?(view, "#create-workflow-action")
      assert has_element?(view, "#workflow-#{workflow.id}")
      assert has_element?(view, "#workflow-duplicate-#{workflow.id}")
      refute has_element?(view, "#workflow-delete-#{workflow.id}")
      assert has_element?(view, "#nav-workflows")
    end

    test "a viewer sees the list without create, duplicate, or delete", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "viewer")

      workflow = workflow(installation.id, %{name: "Nightly digest"})

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows")

      assert has_element?(view, "#workflow-#{workflow.id}")
      refute has_element?(view, "#create-workflow-action")
      refute has_element?(view, "#workflow-duplicate-#{workflow.id}")
      refute has_element?(view, "#workflow-delete-#{workflow.id}")
      refute has_element?(view, "#workflow-deactivate-#{workflow.id}")
    end

    test "viewer create and duplicate events are denied server-side", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "viewer")

      workflow = workflow(installation.id, %{name: "Nightly digest"})
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows")

      html = render_click(view, "duplicate", %{"id" => workflow.id})
      assert html =~ "You do not have permission to do that."
      assert Repo.get(Workflow, workflow.id)

      html =
        render_click(view, "create", %{
          "workflow" => %{"name" => "Sneaky", "template" => "blank"}
        })

      assert html =~ "You do not have permission to do that."
      assert {:ok, []} = Workflows.list_workflows(Scope.new(member), q: "Sneaky")
    end

    test "a viewer who opens /workflows/new does not see the create form", %{conn: conn} do
      %{session_token: token} = InstallationsFixtures.install(role: "viewer")
      conn = log_in(conn, token)

      assert {:error, {:live_redirect, %{to: "/workflows", flash: flash}}} =
               live(conn, ~p"/workflows/new")

      assert flash["error"] =~ "You do not have permission to do that."

      {:ok, view, _html} = live(conn, ~p"/workflows")
      render_patch(view, ~p"/workflows/new")
      refute has_element?(view, "#workflow-create-modal")
      refute has_element?(view, "#workflow-create-form")
    end

    test "viewer confirm events are denied server-side", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "viewer")

      workflow = workflow(installation.id, %{name: "Nightly digest"})
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows")

      html = render_click(view, "confirm_deactivate", %{"id" => workflow.id})
      assert html =~ "You do not have permission to do that."
      refute has_element?(view, "#workflow-confirm-deactivate")

      html = render_click(view, "confirm_delete", %{"id" => workflow.id})
      assert html =~ "You do not have permission to do that."
      refute has_element?(view, "#workflow-confirm-delete")
    end

    test "another workspace's workflow is not listed", %{conn: conn} do
      %{session_token: token} = InstallationsFixtures.install()
      other = InstallationsFixtures.install()
      theirs = workflow(other.installation.id, %{name: "Foreign digest"})

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows")

      refute has_element?(view, "#workflow-#{theirs.id}")
    end

    test "duplicating another workspace's id does not leak existence", %{conn: conn} do
      %{session_token: token} = InstallationsFixtures.install()
      other = InstallationsFixtures.install()
      theirs = workflow(other.installation.id, %{name: "Foreign digest"})

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows")
      html = render_click(view, "duplicate", %{"id" => theirs.id})

      assert html =~ "That resource does not exist."
      assert Repo.get(Workflow, theirs.id)
    end
  end

  describe "empty, pagination, and filter" do
    test "an empty workspace shows the empty state", %{conn: conn} do
      %{session_token: token} = InstallationsFixtures.install(role: "editor")

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows")

      assert has_element?(view, "#workflows-empty")
      assert has_element?(view, "#first-workflow-action")
      refute has_element?(view, "#workflow-list")
    end

    test "search and status filter the page", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      alpha = workflow(installation.id, %{name: "Alpha digest"})
      beta = workflow(installation.id, %{name: "Beta digest", status: "inactive"})

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows")

      view
      |> form("#workflow-filter-form", filter: %{q: "Alpha"})
      |> render_change()

      assert has_element?(view, "#workflow-#{alpha.id}")
      refute has_element?(view, "#workflow-#{beta.id}")

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows")

      view
      |> form("#workflow-filter-form", filter: %{status: "inactive"})
      |> render_change()

      assert has_element?(view, "#workflow-#{beta.id}")
      refute has_element?(view, "#workflow-#{alpha.id}")
    end

    test "an active card separates its live and pending draft aliases", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      scope = Scope.new(member)
      live = manual_definition("live-route")

      workflow =
        drafted_workflow(installation.id, %{
          slug: "live-route",
          draft_definition: Definition.encode(live)
        })

      assert {:ok, activation} = Workflows.activate_workflow(scope, workflow.id, 0)

      assert {:ok, _saved} =
               Workflows.update_draft(
                 scope,
                 workflow.id,
                 manual_definition("next-route"),
                 activation.workflow.draft_revision
               )

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows")

      assert has_element?(view, "#workflow-live-alias-#{workflow.id}", "Live /live-route")

      assert has_element?(
               view,
               "#workflow-pending-alias-#{workflow.id}",
               "Pending draft /next-route"
             )

      view
      |> form("#workflow-filter-form", filter: %{q: "live-route"})
      |> render_change()

      assert has_element?(view, "#workflow-#{workflow.id}")
    end

    test "an archived card searches its historical binding without labeling it live", %{
      conn: conn
    } do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      scope = Scope.new(member)

      workflow =
        drafted_workflow(installation.id, %{
          slug: "live-route",
          draft_definition: Definition.encode(manual_definition("live-route"))
        })

      assert {:ok, activation} = Workflows.activate_workflow(scope, workflow.id, 0)

      assert {:ok, _saved} =
               Workflows.update_draft(
                 scope,
                 workflow.id,
                 manual_definition("next-route"),
                 activation.workflow.draft_revision
               )

      assert {:ok, _archived} = Workflows.archive_workflow(scope, workflow.id)

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows?status=archived")

      assert has_element?(
               view,
               "#workflow-#{workflow.id}[data-status=archived][data-validation=draft]"
             )

      refute has_element?(view, "#workflow-live-alias-#{workflow.id}")
      refute has_element?(view, "#workflow-pending-alias-#{workflow.id}")
      assert has_element?(view, "#workflow-editable-alias-#{workflow.id}", "Archived /next-route")

      view
      |> form("#workflow-filter-form", filter: %{q: "live-route", status: "archived"})
      |> render_change()

      assert has_element?(view, "#workflow-#{workflow.id}")
    end

    test "draft and inactive cards label aliases as non-live", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      draft =
        drafted_workflow(installation.id, %{
          name: "Draft route",
          slug: "draft-route",
          draft_definition: Definition.encode(manual_definition("draft-route"))
        })

      inactive =
        drafted_workflow(installation.id, %{
          name: "Inactive route",
          slug: "inactive-route",
          status: "inactive",
          draft_definition: Definition.encode(manual_definition("inactive-route"))
        })

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows")

      assert has_element?(view, "#workflow-editable-alias-#{draft.id}", "Draft /draft-route")

      assert has_element?(
               view,
               "#workflow-editable-alias-#{inactive.id}",
               "Inactive /inactive-route"
             )

      refute has_element?(view, "#workflow-live-alias-#{draft.id}")
      refute has_element?(view, "#workflow-live-alias-#{inactive.id}")
    end

    test "pagination walks a second page", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      workflows =
        for index <- 1..21 do
          workflow(installation.id, %{name: "Page item #{index}"})
        end

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows")

      assert has_element?(view, "#workflow-pagination")
      assert has_element?(view, "#pagination-next")
      refute has_element?(view, "#pagination-prev")

      view |> element("#pagination-next") |> render_click()

      assert has_element?(view, "#pagination-prev")
      visible = Enum.count(workflows, &has_element?(view, "#workflow-#{&1.id}"))
      assert visible == 1
    end
  end

  describe "create and duplicate ids" do
    test "an editor can create a blank draft and find it", %{conn: conn} do
      %{session_token: token, member: member} = InstallationsFixtures.install(role: "editor")

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows")

      view |> element("#create-workflow-action") |> render_click()
      assert has_element?(view, "#workflow-create-form")
      assert has_element?(view, ~s(#workflow_slug[maxlength="64"]))
      assert has_element?(view, ~s(#workflow_slug[pattern="[a-z0-9][a-z0-9_-]*"]))
      assert has_element?(view, ~s(#workflow_slug[aria-describedby~="workflow-slug-help"]))
      assert has_element?(view, "#workflow-slug-help", ManualAlias.message())

      view
      |> form("#workflow-create-form",
        workflow: %{name: "Nightly digest", slug: "nightly", template: "blank"}
      )
      |> render_submit()

      assert {:ok, [created]} = Workflows.list_workflows(Scope.new(member))
      assert created.slug == "nightly"
      assert {:ok, definition} = Workflow.draft(created)
      assert definition.trigger.config.manual_alias == "nightly"

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows")
      html = render(view)
      assert html =~ "Nightly digest"
      assert has_element?(view, "#workflow-list")
      refute has_element?(view, "#workflows-empty")
    end

    test "a welcome template is an ordinary definition with new ids each time", %{conn: conn} do
      %{session_token: token, member: member} = InstallationsFixtures.install(role: "editor")
      scope = Scope.new(member)

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/new")

      view
      |> form("#workflow-create-form",
        workflow: %{name: "Welcome one", template: "welcome"}
      )
      |> render_change()

      refute has_element?(view, "#workflow_slug")

      view
      |> form("#workflow-create-form", workflow: %{name: "Welcome one", template: "welcome"})
      |> render_submit()

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/new")

      view
      |> form("#workflow-create-form", workflow: %{name: "Welcome two", template: "welcome"})
      |> render_submit()

      assert {:ok, [second, first]} = Workflows.list_workflows(scope)
      assert is_nil(first.slug)
      assert is_nil(second.slug)
      assert {:ok, first_def} = Workflow.draft(first)
      assert {:ok, second_def} = Workflow.draft(second)
      assert first_def.trigger.type == :pumble_event
      assert second_def.trigger.type == :pumble_event
      assert first_def.trigger.id != second_def.trigger.id

      assert MapSet.disjoint?(
               MapSet.new(Definition.node_ids(first_def)),
               MapSet.new(Definition.node_ids(second_def))
             )
    end

    test "duplicate mints new workflow and node ids", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      source =
        drafted_workflow(installation.id, %{
          name: "Source",
          draft_definition: Definition.encode(definition([message_node()]))
        })

      {:ok, source_def} = Workflow.draft(source)
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows")

      view |> element("#workflow-duplicate-#{source.id}") |> render_click()

      assert has_element?(view, "#workflow-#{source.id}")
      copies = Enum.reject(Repo.all(Workflow), &(&1.id == source.id))
      assert [%Workflow{} = copy] = copies
      assert copy.created_by_member_id == member.id
      assert {:ok, copy_def} = Workflow.draft(copy)
      assert copy_def.trigger.id != source_def.trigger.id

      assert MapSet.disjoint?(
               MapSet.new(Definition.node_ids(source_def)),
               MapSet.new(Definition.node_ids(copy_def))
             )
    end

    test "invalid create preserves the form", %{conn: conn} do
      %{session_token: token} = InstallationsFixtures.install(role: "editor")

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/new")

      html =
        view
        |> form("#workflow-create-form", workflow: %{name: "", template: "scheduled"})
        |> render_submit()

      assert has_element?(view, "#workflow-create-form")
      assert html =~ "scheduled"
      assert html =~ "The workflow is not valid."
    end

    test "an invalid manual alias gets actionable validation copy", %{conn: conn} do
      %{session_token: token, member: member} = InstallationsFixtures.install(role: "editor")

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/new")

      html =
        view
        |> form("#workflow-create-form",
          workflow: %{name: "Deploy", slug: "Not valid", template: "blank"}
        )
        |> render_submit()

      assert html =~ ManualAlias.message()
      assert has_element?(view, "#workflow-create-form")
      assert {:ok, []} = Workflows.list_workflows(Scope.new(member))
    end
  end

  defp manual_definition(alias_name) do
    Definition.new(
      Trigger.new(:manual, %{manual_alias: alias_name, slash_command: true}),
      [delay_node()]
    )
  end

  describe "deactivate conflict" do
    test "an unconfirmed deactivate leaves the row unchanged", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      workflow =
        drafted_workflow(installation.id, %{
          draft_definition: Definition.encode(definition([delay_node()]))
        })

      {:ok, _} = Workflows.activate_workflow(Scope.new(member), workflow.id, 0)
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows")

      render_click(view, "deactivate", %{"id" => workflow.id})

      refute has_element?(view, "#workflow-confirm-deactivate")
      assert Repo.get!(Workflow, workflow.id).status == "active"
    end

    test "deactivating a draft after confirm is a typed conflict and keeps the row", %{
      conn: conn
    } do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      workflow = workflow(installation.id, %{name: "Still a draft"})
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows")

      render_click(view, "confirm_deactivate", %{"id" => workflow.id})
      html = render_click(view, "deactivate", %{"id" => workflow.id})

      assert html =~ "That workflow is not running."
      assert has_element?(view, "#workflow-#{workflow.id}")
      assert Repo.get!(Workflow, workflow.id).status == "draft"
    end

    test "an editor can confirm deactivation of a live workflow", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      workflow =
        drafted_workflow(installation.id, %{
          draft_definition: Definition.encode(definition([delay_node()]))
        })

      {:ok, _} = Workflows.activate_workflow(Scope.new(member), workflow.id, 0)
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows")

      assert has_element?(view, "#workflow-deactivate-#{workflow.id}")
      view |> element("#workflow-deactivate-#{workflow.id}") |> render_click()
      assert has_element?(view, "#workflow-confirm-deactivate")
      view |> element("#workflow-confirm-deactivate-submit") |> render_click()

      assert Repo.get!(Workflow, workflow.id).status == "inactive"
      refute has_element?(view, "#workflow-deactivate-#{workflow.id}")
    end
  end

  describe "query count" do
    test "listing many workflows does not add a query per row", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      for index <- 1..12, do: workflow(installation.id, %{name: "Row #{index}"})

      {_result, queries} =
        count_queries(fn -> live(log_in(conn, token), ~p"/workflows") end)

      assert queries < 12
    end
  end

  defp log_in(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
  end

  defp count_queries(fun) do
    handler = "workflow-index-query-count-#{System.unique_integer([:positive])}"
    counter = :counters.new(1, [])
    mine = self()

    :telemetry.attach(
      handler,
      [:pumble_automation, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == mine, do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    try do
      result = fun.()
      {result, :counters.get(counter, 1)}
    after
      :telemetry.detach(handler)
    end
  end
end
