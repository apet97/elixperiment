defmodule PumbleAutomationWeb.Browser.AcceptanceJourneyTest do
  @moduledoc """
  P15-T06 discoverable LiveView/browser acceptance. The runner is
  `Phoenix.LiveViewTest` against fake Pumble and isolated tenants. Wallaby and
  Playwright were not added: they do not buy assertions this harness cannot
  already make, and no extra hex dependency is approved.
  """

  use PumbleAutomationWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Connections
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.OauthStates
  alias PumbleAutomation.Installations.Sessions
  alias PumbleAutomation.Installations.UserSession
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.PumbleFake
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomationWeb.BrowserSession
  alias PumbleAutomationWeb.Plugs.SecurityHeaders

  test "a fake-Pumble install callback reaches onboarding" do
    workspace = InstallationsFixtures.unique_workspace()
    PumbleFake.stub_success(%{"workspaceId" => workspace})
    {:ok, state_token, _state} = OauthStates.create("install")

    conn = get(build_conn(), ~p"/oauth/callback?code=auth-code&state=#{state_token}")
    assert redirected_to(conn) == "/"

    cookie = conn.resp_cookies[BrowserSession.cookie()].value
    {:ok, view, _html} = live(log_in(build_conn(), cookie), ~p"/")

    assert has_element?(view, "#onboarding-page[data-state=installed_empty]")
    assert has_element?(view, "#skip-to-main")
    assert has_element?(view, "main#main-content")
    assert [%Installation{pumble_workspace_id: ^workspace}] = Repo.all(Installation)
  end

  test "keyboard create, nested edit, two-session conflict, and remount" do
    %{session_token: token, installation: installation, member: member} =
      InstallationsFixtures.install(role: "editor")

    {:ok, index, _html} = live(log_in(build_conn(), token), ~p"/workflows")
    index |> element("#create-workflow-action") |> render_click()

    index
    |> form("#workflow-create-form", workflow: %{name: "Acceptance draft", template: "blank"})
    |> render_submit()

    assert {:ok, [%Workflow{id: workflow_id, name: "Acceptance draft"}]} =
             Workflows.list_workflows(Scope.new(member))

    path = ~p"/workflows/#{workflow_id}/edit"
    {:ok, editor, _html} = live(log_in(build_conn(), token), path)
    editor |> element("#root-add-step") |> render_click()
    editor |> element("#add-type-condition") |> render_click()
    editor |> element("#editor-save") |> render_click()
    assert has_element?(editor, ~s(#editor-save-state[data-state="saved"]))

    assert {:ok, saved} = Workflows.get_workflow(Scope.new(member), workflow_id)
    assert {:ok, outline} = Workflow.draft(saved)
    [%Node{id: condition_id, type: :condition}] = outline.steps

    editor |> element("#branch-add-#{condition_id}-if_true") |> render_click()
    editor |> element("#add-type-stop") |> render_click()
    editor |> element("#editor-save") |> render_click()

    {:ok, session_a, _html} = live(log_in(build_conn(), token), path)
    {:ok, session_b, _html} = live(log_in(build_conn(), token), path)
    assert has_element?(session_a, "#step-#{condition_id}")
    assert has_element?(session_a, "#step-move-up-#{condition_id}[disabled]")

    session_a |> element("#step-add-after-#{condition_id}") |> render_click()
    session_a |> element("#add-type-delay") |> render_click()
    session_a |> element("#editor-save") |> render_click()
    assert has_element?(session_a, ~s(#editor-save-state[data-state="saved"]))

    session_b |> element("#step-add-after-#{condition_id}") |> render_click()
    session_b |> element("#add-type-approval") |> render_click()
    session_b |> element("#editor-save") |> render_click()
    assert has_element?(session_b, "#editor-conflict")
    assert has_element?(session_b, ~s(#editor-save-state[data-state="conflict"]))

    {:ok, remount, _html} = live(log_in(build_conn(), token), path)
    refute has_element?(remount, "#editor-conflict")
    refute has_element?(remount, "#activate-confirm")
    assert has_element?(remount, ~s(#editor-save-state[data-state="saved"]))

    assert {:ok, final} = Workflows.get_workflow(Scope.new(member), workflow_id)
    assert {:ok, nested} = Workflow.draft(final)
    assert Enum.map(nested.steps, & &1.type) == [:condition, :delay]
    updated = Enum.find(nested.steps, &(&1.type == :condition))
    assert [%Node{type: :stop}] = Node.branch(updated, :if_true)
    assert installation.id == final.installation_id
  end

  test "validate, dry-run, activate, timeline, and cancel stay on the server" do
    %{session_token: token, installation: installation, member: member} =
      InstallationsFixtures.install(role: "editor")

    delay = delay_node()
    halt = stop_node()

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([delay, halt]))
      })

    {:ok, view, _html} = live(log_in(build_conn(), token), ~p"/workflows/#{workflow.id}")
    view |> element("#workflow-validation-run") |> render_click()
    assert has_element?(view, "#workflow-validation")

    view
    |> form("#dry-run-form", %{"dry_run" => %{"sample" => "{}"}})
    |> render_submit()

    assert has_element?(view, ~s(#dry-run-trace[data-status="completed"]))
    assert has_element?(view, ~s(#dry-run-step-1[data-node-id="#{delay.id}"]))

    view |> element("#activate-prompt") |> render_click()
    assert has_element?(view, "#activate-confirm")
    view |> element("#activate-submit") |> render_click()
    assert Repo.get!(Workflow, workflow.id).status == "active"

    scope = Scope.new(member)
    {:ok, [version]} = Workflows.list_versions(scope, workflow.id)

    {:ok, execution} =
      Engine.create(scope, %{
        workflow_version_id: version.id,
        execution_key: "ui-#{System.unique_integer([:positive])}"
      })

    {:ok, show, _html} =
      live(log_in(build_conn(), token), ~p"/executions/#{execution.id}")

    assert has_element?(show, "#execution-show")
    assert has_element?(show, "#cancel-prompt")
    show |> element("#cancel-prompt") |> render_click()
    assert has_element?(show, "#cancel-confirm")
    show |> element("#cancel-submit") |> render_click()
    assert has_element?(show, ~s(#execution-show[data-status="cancelled"]))
    assert Repo.get!(Execution, execution.id).status == "cancelled"
  end

  test "an owner can resolve uncertainty; a viewer cannot cancel" do
    %{session_token: token, installation: installation, member: member} =
      InstallationsFixtures.install(role: "owner")

    scope = Scope.new(member)
    execution = paused_execution(scope, installation.id)
    {:ok, view, _html} = live(log_in(build_conn(), token), ~p"/executions/#{execution.id}")

    assert has_element?(view, "#resolve-failed-prompt")
    view |> element("#resolve-failed-prompt") |> render_click()
    view |> element("#uncertain-failed-submit") |> render_click()
    assert Repo.get!(Execution, execution.id).status == "failed"

    viewer_install = InstallationsFixtures.install()
    viewer_scope = Scope.new(viewer_install.member)

    queued_workflow =
      drafted_workflow(viewer_install.installation.id, %{
        draft_definition: Definition.encode(definition([delay_node()]))
      })

    {:ok, queued_activated} = Workflows.activate_workflow(viewer_scope, queued_workflow.id, 0)
    queued = queued_execution(viewer_scope, queued_activated.version)
    InstallationsFixtures.set_role(viewer_install.member, "viewer")

    {:ok, readonly, _html} =
      live(
        log_in(build_conn(), viewer_install.session_token),
        ~p"/executions/#{queued.id}"
      )

    refute has_element?(readonly, "#cancel-prompt")
    html = render_click(readonly, "confirm_cancel", %{})
    assert html =~ "You do not have permission to do that."
    assert Repo.get!(Execution, queued.id).status == "queued"
  end

  test "a unique canary secret never appears in HTML or captured logs" do
    canary = canary()
    %{session_token: token, member: member} = InstallationsFixtures.install()

    log =
      capture_log(fn ->
        {:ok, view, html} = live(log_in(build_conn(), token), ~p"/secrets/new")
        refute html =~ canary

        submitted =
          view
          |> form("#secret-form",
            secret: %{name: "ACCEPTANCE_TOKEN", kind: "generic", value: canary}
          )
          |> render_submit()

        refute submitted =~ canary
        refute render(view) =~ canary
        assert has_element?(view, "#secret-index")
      end)

    refute log =~ canary
    assert {:ok, [secret]} = Connections.list_secrets(Scope.new(member))
    assert secret.name == "ACCEPTANCE_TOKEN"
    refute Map.has_key?(secret, :value)
  end

  test "connections, members, audit, and sign-out stay tenant-authorized" do
    %{session_token: token, member: member, session: session} =
      InstallationsFixtures.install(role: "owner")

    {:ok, connections, _html} = live(log_in(build_conn(), token), ~p"/connections/new")

    connections
    |> form("#connection-form",
      connection: %{
        name: "Tickets",
        base_origin: "https://api.example.test",
        base_path_prefix: "/v1",
        enabled: "true"
      }
    )
    |> render_submit()

    assert {:ok, [connection]} = Connections.list_connections(Scope.new(member))
    assert connection.name == "Tickets"

    {:ok, members, html} = live(log_in(build_conn(), token), ~p"/members")
    assert has_element?(members, "#member-#{member.id}")
    assert html =~ "There is no email invite"

    {:ok, audit, _html} = live(log_in(build_conn(), token), ~p"/audit")
    assert has_element?(audit, "#audit-index")
    refute has_element?(audit, "#audit-delete")
    assert has_element?(audit, "#sign-out")

    conn =
      build_conn()
      |> log_in(token)
      |> Plug.Test.init_test_session(%{})
      |> delete(~p"/session/sign-out")

    assert redirected_to(conn) == BrowserSession.sign_in_path()
    refute is_nil(Repo.get!(UserSession, session.id).revoked_at)
    assert Sessions.fetch(token, DateTime.utc_now()) == :error
  end

  test "narrow layout, CSP, and static assets have no console-side holes" do
    %{session_token: token} = InstallationsFixtures.install(role: "editor")
    {:ok, view, html} = live(log_in(build_conn(), token), ~p"/workflows")

    assert has_element?(view, "#app-shell[data-layout='responsive']")
    assert html =~ "lg:grid-cols-[15rem_minmax(0,1fr)]"
    assert html =~ "min-w-0"
    assert has_element?(view, "a#skip-to-main")
    assert has_element?(view, "nav#app-shell-nav")

    conn = get(build_conn(), ~p"/")
    page = html_response(conn, 200)
    [csp] = get_resp_header(conn, "content-security-policy")
    assert csp == SecurityHeaders.csp()
    assert csp =~ "script-src 'self'"
    refute csp =~ "unsafe-eval"
    refute page =~ ~r/<script(?![^>]*\bsrc=)/i
    assert page =~ ~s(src="/assets/js/app.js")

    js = get(build_conn(), "/assets/js/app.js")
    css = get(build_conn(), "/assets/css/app.css")
    assert js.status == 200
    assert css.status == 200
  end

  defp paused_execution(scope, installation_id) do
    workflow =
      drafted_workflow(installation_id, %{
        draft_definition: Definition.encode(definition([stop_node()]))
      })

    {:ok, activated} = Workflows.activate_workflow(scope, workflow.id, 0)
    execution = queued_execution(scope, activated.version)

    {:ok, snapshot} =
      Engine.claim(%{
        "installation_id" => execution.installation_id,
        "execution_id" => execution.id,
        "expected_node_id" => execution.current_node_id,
        "generation" => execution.lock_version
      })

    {:ok, outcome} =
      Outcome.new(%{
        kind: :uncertain,
        error_class: "side_effect_uncertain",
        message: "The remote write may have succeeded.",
        remote_reference: "req-ui-1"
      })

    {:ok, paused} = Engine.finalize(snapshot, outcome)
    assert paused.status == "paused_uncertain"
    paused
  end

  defp queued_execution(scope, version) do
    {:ok, execution} =
      Engine.create(scope, %{
        workflow_version_id: version.id,
        execution_key: "ui-#{System.unique_integer([:positive])}"
      })

    Repo.get!(Execution, execution.id)
  end

  defp canary do
    "CANARY-P15T06-#{System.unique_integer([:positive])}-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
  end

  defp log_in(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
  end
end
