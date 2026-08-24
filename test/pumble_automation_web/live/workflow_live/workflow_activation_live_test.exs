defmodule PumbleAutomationWeb.WorkflowLive.WorkflowActivationLiveTest do
  @moduledoc """
  Validation, dry-run, live test, activation, and version controls.
  """

  use PumbleAutomationWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Ingress.WebhookEndpoint
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Pumble.Client.Transport
  alias PumbleAutomation.PumbleFake
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomation.Workflows.WorkflowVersion
  alias PumbleAutomationWeb.BrowserSession

  describe "auth and roles" do
    test "a visitor is sent to sign-in", %{conn: conn} do
      id = Ecto.UUID.generate()
      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/workflows/#{id}")
      assert to == BrowserSession.sign_in_path()
    end

    test "another workspace's workflow does not leak existence", %{conn: conn} do
      %{session_token: token} = InstallationsFixtures.install(role: "editor")
      other = InstallationsFixtures.install()
      theirs = drafted_workflow(other.installation.id)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(log_in(conn, token), ~p"/workflows/#{theirs.id}")

      assert to == ~p"/workflows"
    end

    test "a viewer can validate and dry-run but cannot activate or live-test", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "viewer")

      node = delay_node()
      workflow = workflow_with(installation.id, [node])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}")

      assert has_element?(view, "#workflow-show")
      assert has_element?(view, "#workflow-validation")
      assert has_element?(view, "#dry-run-form")
      refute has_element?(view, "#activate-prompt")
      refute has_element?(view, "#live-test-prompt")
      refute has_element?(view, "#deactivate-prompt")

      html = render_click(view, "confirm_activate", %{})
      assert html =~ "You do not have permission to do that."

      html = render_click(view, "confirm_live_test", %{})
      assert html =~ "You do not have permission to do that."
    end
  end

  describe "validation navigation" do
    test "issues are grouped by node and focusing selects the card", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      condition = Node.new(:condition, %{combinator: :all, predicates: []})
      workflow = workflow_with(installation.id, [condition])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}")

      assert has_element?(view, "#workflow-validation-status")
      assert has_element?(view, ~s(#validation-issue-0[data-node-id="#{condition.id}"]))
      refute has_element?(view, ~s(#focus-card-#{condition.id}[data-focused="true"]))

      view |> element("#validation-issue-0") |> render_click()

      assert has_element?(view, ~s(#focus-card-#{condition.id}[data-focused="true"]))
    end

    test "saving a draft in the editor validates and focuses the selected card", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      condition = Node.new(:condition, %{combinator: :all, predicates: []})
      workflow = workflow_with(installation.id, [condition])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      view |> element("#step-add-after-#{condition.id}") |> render_click()
      view |> element("#add-type-stop") |> render_click()
      view |> element("#editor-save") |> render_click()

      assert has_element?(view, "#workflow-validation-status")
      view |> element("#validation-issue-0") |> render_click()
      assert has_element?(view, ~s(#step-#{condition.id}[data-focused="true"]))
    end

    test "warnings are not shown as a proof of success", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      workflow = workflow_with(installation.id, [stop_node(), delay_node()])
      {:ok, view, html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}")

      assert has_element?(view, "#workflow-validation-status")
      assert html =~ "Warnings only"
      assert html =~ "not a proof of success"
      refute html =~ "Validation succeeded"
    end
  end

  describe "dry-run" do
    test "previews the compiled graph without Pumble or client transport", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      send_node = message_node()
      halt = stop_node()
      workflow = workflow_with(installation.id, [send_node, halt])
      planted = "s3cret-value-must-not-leak"

      handler = "show-dry-run-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach_many(
        handler,
        [Transport.telemetry_event() ++ [:start], Transport.telemetry_event() ++ [:stop]],
        fn event, _measurements, metadata, _config ->
          id = Map.get(metadata, :correlation_id) || ""

          if String.starts_with?(id, "dry-run/") do
            send(test_pid, {:client, event, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      PumbleFake.stub_api_routes(self(), [
        {"POST", "/v1/channels/channel-1/messages", 200, %{"id" => "message1"}}
      ])

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}")

      view
      |> form("#dry-run-form", %{
        "dry_run" => %{"sample" => Jason.encode!(%{"data" => %{"text" => planted}})}
      })
      |> render_submit()

      assert has_element?(view, ~s(#dry-run-trace[data-status="completed"]))
      assert has_element?(view, ~s(#dry-run-step-1[data-node-id="#{send_node.id}"]))
      refute_received {:pumble_api_request, _}
      refute_received {:client, _, _}

      stored = Repo.get!(Workflow, workflow.id)
      refute inspect(stored.draft_definition) =~ planted
    end
  end

  describe "live-test confirmation and role" do
    test "an editor confirms a live test of the active version", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      workflow = workflow_with(installation.id, [delay_node()])
      scope = Scope.new(member)
      {:ok, activated} = Workflows.activate_workflow(scope, workflow.id, 0)

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}")

      refute has_element?(view, "#live-test-confirm")
      view |> element("#live-test-prompt") |> render_click()
      assert has_element?(view, "#live-test-confirm")
      assert render(view) =~ "not a dry-run"

      view |> element("#live-test-submit") |> render_click()
      refute has_element?(view, "#live-test-confirm")

      assert [%Execution{} = execution] =
               Repo.all(from e in Execution, where: e.workflow_id == ^workflow.id)

      assert execution.workflow_version_id == activated.version.id
      assert execution.context["execution"]["run_mode"] == "live"
    end
  end

  describe "activation success and rollback" do
    test "an active webhook remount shows the persistent caller-setup status", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "owner")

      definition =
        Definition.new(Trigger.new(:webhook, %{require_signature: true}), [delay_node()])

      workflow =
        drafted_workflow(installation.id, %{
          draft_definition: Definition.encode(definition)
        })

      stored_version = version(workflow)

      workflow
      |> Workflow.changeset(%{status: "active", active_version_id: stored_version.id})
      |> Repo.update!()

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}")

      refute has_element?(view, "#webhook-credentials-reveal")
      assert has_element?(view, ~s(#webhook-credentials-required[role="status"]))

      assert has_element?(
               view,
               "#webhook-credentials-required-message",
               "Rotation is only for lost or compromised credentials"
             )

      assert has_element?(
               view,
               "#webhook-credentials-required-message",
               "HMAC signing secret"
             )

      assert has_element?(view, ~s(#webhook-credentials-settings-link[href="/settings"]))
    end

    test "hidden webhook status does not claim a signing secret when HMAC is disabled", %{
      conn: conn
    } do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "owner")

      definition =
        Definition.new(Trigger.new(:webhook, %{require_signature: false}), [delay_node()])

      workflow =
        drafted_workflow(installation.id, %{
          draft_definition: Definition.encode(definition)
        })

      stored_version = version(workflow)

      workflow
      |> Workflow.changeset(%{status: "active", active_version_id: stored_version.id})
      |> Repo.update!()

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}")

      assert has_element?(
               view,
               "#webhook-credentials-required-message",
               "This endpoint does not require an HMAC signing secret"
             )

      refute has_element?(
               view,
               "#webhook-credentials-required-message",
               "Caller setup uses the endpoint URL, bearer token, and HMAC signing secret"
             )
    end

    test "an editor can activate a proved draft", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      workflow = workflow_with(installation.id, [delay_node()])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}")

      view |> element("#activate-prompt") |> render_click()
      assert has_element?(view, "#activate-confirm")
      assert has_element?(view, "#activate-scopes")
      assert has_element?(view, "#activate-warnings")

      view |> element("#activate-submit") |> render_click()

      assert has_element?(view, "#version-1")
      assert has_element?(view, "#version-live-1")
      refute has_element?(view, "#webhook-credentials-required")

      assert {:ok, stored} = Workflows.get_workflow(Scope.new(member), workflow.id)
      assert stored.status == "active"
      assert stored.active_version_id
    end

    test "an owner sees new webhook credentials once and lists never retain them", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "owner")

      definition =
        Definition.new(Trigger.new(:webhook, %{require_signature: true}), [delay_node()])

      workflow =
        drafted_workflow(installation.id, %{
          draft_definition: Definition.encode(definition)
        })

      path = ~p"/workflows/#{workflow.id}"
      {:ok, view, _html} = live(log_in(conn, token), path)

      view |> element("#activate-prompt") |> render_click()
      view |> element("#activate-submit") |> render_click()

      assert has_element?(view, "#webhook-credentials-reveal")
      assert has_element?(view, "#activated-webhook-url")
      assert has_element?(view, "#activated-webhook-token")
      assert has_element?(view, "#activated-webhook-signing-secret")
      assert has_element?(view, ~s(#activated-webhook-reveal-status[role="status"]))

      assert has_element?(
               view,
               ~s(#activated-webhook-token-copy-control[phx-hook="CopyToClipboard"][phx-update="ignore"])
             )

      assert has_element?(
               view,
               ~s(#activated-webhook-token-copy[aria-label="Copy Bearer token"])
             )

      assert has_element?(
               view,
               ~s(#activated-webhook-token-copy-status[role="status"][aria-live="polite"][aria-atomic="true"])
             )

      refute has_element?(view, "#webhook-credentials-required")

      [endpoint] =
        Repo.all(
          from endpoint in WebhookEndpoint,
            where:
              endpoint.workflow_id == ^workflow.id and
                (endpoint.enabled or endpoint.signature_enabled)
        )

      with_secret =
        Repo.one!(WebhookEndpoint.by_id_for_rotation(installation.id, endpoint.id))

      assert render(view) =~ with_secret.signing_secret

      view |> element("#dismiss-activated-webhook-credentials") |> render_click()
      refute has_element?(view, "#webhook-credentials-reveal")
      assert has_element?(view, "#webhook-credentials-required")

      assert has_element?(
               view,
               "#webhook-credentials-required-message",
               "Rotation is only for lost or compromised credentials"
             )

      assert has_element?(view, ~s(#webhook-credentials-settings-link[href="/settings"]))

      {:ok, remounted, html} = live(log_in(build_conn(), token), path)
      refute has_element?(remounted, "#webhook-credentials-reveal")
      assert has_element?(remounted, "#webhook-credentials-required")
      refute html =~ with_secret.signing_secret
    end

    test "an editor activates a webhook without receiving owner-only credentials", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      definition =
        Definition.new(Trigger.new(:webhook, %{require_signature: true}), [delay_node()])

      workflow =
        drafted_workflow(installation.id, %{
          draft_definition: Definition.encode(definition)
        })

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}")
      view |> element("#activate-prompt") |> render_click()
      view |> element("#activate-submit") |> render_click()

      refute has_element?(view, "#webhook-credentials-reveal")
      assert has_element?(view, "#webhook-credentials-required")

      assert has_element?(
               view,
               "#webhook-credentials-required-message",
               "If not, ask an owner to rotate the credentials in Settings and copy a new set"
             )

      assert Repo.exists?(
               from endpoint in WebhookEndpoint,
                 where:
                   endpoint.workflow_id == ^workflow.id and
                     (endpoint.enabled or endpoint.signature_enabled)
             )
    end

    test "activate without the confirm assign does not publish", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      workflow = workflow_with(installation.id, [delay_node()])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}")

      render_click(view, "activate", %{})
      refute has_element?(view, "#version-1")
      assert Repo.get!(Workflow, workflow.id).status == "draft"
    end

    test "dependency loss leaves the old live version intact and shows safe issues", %{
      conn: conn
    } do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      workflow = workflow_with(installation.id, [delay_node()])
      scope = Scope.new(member)
      {:ok, first} = Workflows.activate_workflow(scope, workflow.id, 0)

      missing =
        Node.new(:http_action, %{
          method: :post,
          url: "https://example.test/hook",
          headers: %{"accept" => "text/plain"},
          body: "token={{ secret.MISSING_TOKEN }}"
        })

      {:ok, drafted} =
        Workflows.update_draft(
          scope,
          workflow.id,
          definition([missing]),
          first.workflow.draft_revision
        )

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{drafted.id}")

      html = render_click(view, "confirm_activate", %{})
      assert html =~ "This workflow cannot be activated."
      assert has_element?(view, ~s(#workflow-validation [data-code="secret_not_found"]))

      stored = Repo.get!(Workflow, workflow.id)
      assert stored.status == "active"
      assert stored.active_version_id == first.version.id
    end

    test "deactivate does not cancel in-flight executions", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      workflow = workflow_with(installation.id, [delay_node()])
      scope = Scope.new(member)
      {:ok, _} = Workflows.activate_workflow(scope, workflow.id, 0)

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}")
      view |> element("#live-test-prompt") |> render_click()
      view |> element("#live-test-submit") |> render_click()

      assert [%Execution{status: status, id: execution_id}] =
               Repo.all(from e in Execution, where: e.workflow_id == ^workflow.id)

      refute status == "cancelled"

      view |> element("#deactivate-prompt") |> render_click()
      assert has_element?(view, "#deactivate-confirm")
      assert render(view) =~ "not cancelled"
      view |> element("#deactivate-submit") |> render_click()

      stored = Repo.get!(Workflow, workflow.id)
      assert stored.status == "inactive"
      assert is_nil(stored.active_version_id)

      execution = Repo.get!(Execution, execution_id)
      refute execution.status == "cancelled"
    end
  end

  describe "version reactivation" do
    test "an editor can inspect a diff and reactivate a prior version", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      first_node = delay_node()
      workflow = workflow_with(installation.id, [first_node])
      scope = Scope.new(member)
      {:ok, first} = Workflows.activate_workflow(scope, workflow.id, 0)

      second_definition = definition([first_node, stop_node()])

      {:ok, drafted} =
        Workflows.update_draft(
          scope,
          workflow.id,
          second_definition,
          first.workflow.draft_revision
        )

      {:ok, second} = Workflows.activate_workflow(scope, drafted.id, drafted.draft_revision)
      assert second.version.version_number == 2

      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}")

      view |> element("#version-select-1") |> render_click()
      assert has_element?(view, "#version-detail")
      assert has_element?(view, "#version-diff")
      assert render(view) =~ "Step count changed"

      view |> element("#version-reactivate-1") |> render_click()
      assert has_element?(view, "#reactivate-confirm")
      view |> element("#reactivate-submit") |> render_click()

      stored = Repo.get!(Workflow, workflow.id)
      assert stored.status == "active"
      assert stored.active_version_id == first.version.id
      assert has_element?(view, "#version-live-1")
    end
  end

  describe "concurrent activation" do
    test "two sessions that share a revision produce one winner", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      workflow = workflow_with(installation.id, [delay_node()])
      path = ~p"/workflows/#{workflow.id}"

      {:ok, session_a, _html} = live(log_in(conn, token), path)
      {:ok, session_b, _html} = live(log_in(build_conn(), token), path)

      session_a |> element("#activate-prompt") |> render_click()
      session_b |> element("#activate-prompt") |> render_click()
      session_a |> element("#activate-submit") |> render_click()
      html = session_b |> element("#activate-submit") |> render_click()

      assert html =~ "The workflow draft changed since it was opened."

      stored = Repo.get!(Workflow, workflow.id)
      assert stored.status == "active"
      assert stored.draft_revision == 1

      versions =
        Repo.all(from v in WorkflowVersion, where: v.workflow_id == ^workflow.id)

      assert length(versions) == 1
    end
  end

  defp workflow_with(installation_id, nodes) do
    drafted_workflow(installation_id, %{draft_definition: Definition.encode(definition(nodes))})
  end

  defp log_in(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
  end
end
