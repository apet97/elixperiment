defmodule PumbleAutomationWeb.WorkflowLive.NodeFormsTest do
  @moduledoc """
  Node configuration forms: valid/invalid per type, secrets, references, HTTP, DST.
  """

  use PumbleAutomationWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.ConnectionsFixtures
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomationWeb.BrowserSession

  describe "auth and roles" do
    test "a viewer sees configuration without a save control", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "viewer")

      node = delay_node()
      workflow = workflow_with(installation.id, [node])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      assert has_element?(view, "#node-form-#{node.id}")
      refute has_element?(view, "#node-form-#{node.id}-save")
    end
  end

  describe "delay" do
    test "a valid duration persists through the AST", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      node = delay_node()
      workflow = workflow_with(installation.id, [node])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      view
      |> form("#node-form-#{node.id}-form", %{"config" => %{"duration_seconds" => "120"}})
      |> render_submit()

      view |> element("#editor-save") |> render_click()

      assert {:ok, saved} = Workflows.get_workflow(Scope.new(member), workflow.id)
      assert {:ok, definition} = Workflow.draft(saved)
      assert [%Node{config: %{duration_seconds: 120}}] = definition.steps
    end

    test "a field change is in the draft before Save configuration", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      node = delay_node()
      workflow = workflow_with(installation.id, [node])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      view
      |> form("#node-form-#{node.id}-form", %{"config" => %{"duration_seconds" => "120"}})
      |> render_change()

      view |> element("#editor-save") |> render_click()

      assert {:ok, saved} = Workflows.get_workflow(Scope.new(member), workflow.id)
      assert {:ok, definition} = Workflow.draft(saved)
      assert [%Node{config: %{duration_seconds: 120}}] = definition.steps
    end

    test "an out-of-range duration stays in the form with a stable code", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      node = delay_node()
      workflow = workflow_with(installation.id, [node])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      html =
        view
        |> form("#node-form-#{node.id}-form", %{"config" => %{"duration_seconds" => "0"}})
        |> render_change()

      assert has_element?(view, "#node-form-#{node.id}-issues [data-code=out_of_range]")
      assert html =~ "is too small"
    end
  end

  describe "stop" do
    test "a valid reason persists", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      node = stop_node()
      workflow = workflow_with(installation.id, [node])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      view
      |> form("#node-form-#{node.id}-form", %{"config" => %{"reason" => "halted"}})
      |> render_submit()

      view |> element("#editor-save") |> render_click()
      assert {:ok, saved} = Workflows.get_workflow(Scope.new(member), workflow.id)
      assert {:ok, definition} = Workflow.draft(saved)
      assert [%Node{config: %{reason: "halted"}}] = definition.steps
    end

    test "an overlong reason is refused with a stable code", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      node = stop_node()
      workflow = workflow_with(installation.id, [node])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      view
      |> form("#node-form-#{node.id}-form", %{
        "config" => %{"reason" => String.duplicate("x", 1025)}
      })
      |> render_change()

      assert has_element?(view, "#node-form-#{node.id}-issues [data-code=too_long]")
    end
  end

  describe "condition" do
    test "a valid comparison persists", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      node = condition_node()
      workflow = workflow_with(installation.id, [node])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      view
      |> form("#node-form-#{node.id}-form", %{
        "config" => %{
          "combinator" => "any",
          "predicates" => %{
            "0" => %{
              "left" => "{{ trigger.data.text }}",
              "comparator" => "eq",
              "right" => "ok"
            }
          }
        }
      })
      |> render_submit()

      view |> element("#editor-save") |> render_click()
      assert {:ok, saved} = Workflows.get_workflow(Scope.new(member), workflow.id)
      assert {:ok, definition} = Workflow.draft(saved)
      assert [%Node{config: config}] = definition.steps
      assert config.combinator == :any
      assert hd(config.predicates).comparator == :eq
    end

    test "the comparator dropdown includes in and is_present", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      node = condition_node()
      workflow = workflow_with(installation.id, [node])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      html = render(view)
      assert html =~ ~s(value="in")
      assert html =~ ~s(value="is_present")
    end

    test "an empty comparison list reports no_predicates", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      node = Node.new(:condition, %{combinator: :all, predicates: []})
      workflow = workflow_with(installation.id, [node])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      assert has_element?(view, "#node-form-#{node.id}-issues [data-code=no_predicates]")
    end
  end

  describe "pumble action" do
    test "a valid send_message persists", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      node = message_node()
      workflow = workflow_with(installation.id, [node])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      view
      |> form("#node-form-#{node.id}-form", %{
        "config" => %{
          "action" => "send_message",
          "channel_id" => "C123",
          "text" => "hello"
        }
      })
      |> render_submit()

      view |> element("#editor-save") |> render_click()
      assert {:ok, saved} = Workflows.get_workflow(Scope.new(member), workflow.id)
      assert {:ok, definition} = Workflow.draft(saved)
      assert [%Node{config: %{channel_id: "C123", text: "hello"}}] = definition.steps
    end

    test "a missing required field reports action_field_missing", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      node = message_node()
      workflow = workflow_with(installation.id, [node])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      view
      |> form("#node-form-#{node.id}-form", %{
        "config" => %{"action" => "send_message", "channel_id" => "", "text" => ""}
      })
      |> render_change()

      assert has_element?(view, "#node-form-#{node.id}-issues [data-code=action_field_missing]")
    end
  end

  describe "http action" do
    test "a valid request persists", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      node = http_node()
      workflow = workflow_with(installation.id, [node])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      view
      |> form("#node-form-#{node.id}-form", %{
        "config" => %{"method" => "get", "url" => "https://example.test/status"}
      })
      |> render_submit()

      view |> element("#editor-save") |> render_click()
      assert {:ok, saved} = Workflows.get_workflow(Scope.new(member), workflow.id)
      assert {:ok, definition} = Workflow.draft(saved)

      assert [%Node{config: %{method: :get, url: "https://example.test/status"}}] =
               definition.steps
    end

    test "a relative URL reports http_url_not_absolute", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      node = http_node()
      workflow = workflow_with(installation.id, [node])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      view
      |> form("#node-form-#{node.id}-form", %{
        "config" => %{"method" => "get", "url" => "/internal"}
      })
      |> render_change()

      assert has_element?(view, "#node-form-#{node.id}-issues [data-code=http_url_not_absolute]")
    end
  end

  describe "approval" do
    test "a valid approval persists", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      node = approval_node()
      workflow = workflow_with(installation.id, [node])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      view
      |> form("#node-form-#{node.id}-form", %{
        "config" => %{
          "prompt" => "Ship?",
          "approver_member_ids" => member.id,
          "timeout_seconds" => "600"
        }
      })
      |> render_submit()

      view |> element("#editor-save") |> render_click()
      assert {:ok, saved} = Workflows.get_workflow(Scope.new(member), workflow.id)
      assert {:ok, definition} = Workflow.draft(saved)
      assert [%Node{config: config}] = definition.steps
      assert config.timeout_seconds == 600
      assert config.approver_member_ids == [member.id]
    end

    test "missing approvers report no_approvers", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      node = Node.new(:approval, %{prompt: "Ship?", timeout_seconds: 60})
      workflow = workflow_with(installation.id, [node])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      assert has_element?(view, "#node-form-#{node.id}-issues [data-code=no_approvers]")
      assert has_element?(view, "#node-form-#{node.id}-approval-policy")
    end
  end

  describe "triggers" do
    test "a pumble event trigger persists", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      workflow = workflow_with(installation.id, [stop_node()])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      view
      |> form("#trigger-form-form", %{
        "config" => %{"event" => "NEW_MESSAGE", "ignore_bot_messages" => "true"}
      })
      |> render_submit()

      view |> element("#editor-save") |> render_click()
      assert {:ok, saved} = Workflows.get_workflow(Scope.new(member), workflow.id)
      assert {:ok, definition} = Workflow.draft(saved)
      assert definition.trigger.config.event == :new_message
    end

    test "an overlong keyword stays in the form", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      workflow = workflow_with(installation.id, [stop_node()])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      view
      |> form("#trigger-form-form", %{
        "config" => %{"keyword" => String.duplicate("k", 1025)}
      })
      |> render_change()

      assert has_element?(view, "#trigger-form-issues [data-code=too_long]")
    end

    test "a daily schedule persists", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      trigger =
        Trigger.new(:schedule, %{
          schedule_type: :daily,
          time_of_day: "09:00",
          timezone: "Etc/UTC"
        })

      workflow = workflow_from(installation.id, Definition.new(trigger, [stop_node()]))
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      view
      |> form("#trigger-form-form", %{
        "config" => %{
          "schedule_type" => "daily",
          "time_of_day" => "10:30",
          "timezone" => "Etc/UTC"
        }
      })
      |> render_submit()

      view |> element("#editor-save") |> render_click()
      assert {:ok, saved} = Workflows.get_workflow(Scope.new(member), workflow.id)
      assert {:ok, definition} = Workflow.draft(saved)
      assert definition.trigger.config.time_of_day == "10:30"
    end

    test "a test trigger is configurable without fields", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      trigger = Trigger.new(:manual_test, %{})
      workflow = workflow_from(installation.id, Definition.new(trigger, [stop_node()]))
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      assert has_element?(view, "#trigger-form-manual-test")

      view
      |> form("#trigger-form-form", %{})
      |> render_submit()

      view |> element("#editor-save") |> render_click()
      assert {:ok, saved} = Workflows.get_workflow(Scope.new(member), workflow.id)
      assert {:ok, definition} = Workflow.draft(saved)
      assert definition.trigger.type == :manual_test
    end

    test "an unknown schedule timezone stays in the form", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      trigger =
        Trigger.new(:schedule, %{schedule_type: :daily, time_of_day: "09:00", timezone: "Etc/UTC"})

      workflow = workflow_from(installation.id, Definition.new(trigger, [stop_node()]))
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      view
      |> form("#trigger-form-form", %{
        "config" => %{
          "schedule_type" => "daily",
          "time_of_day" => "09:00",
          "timezone" => "not a zone"
        }
      })
      |> render_change()

      assert has_element?(view, "#trigger-form-issues [data-code=invalid_timezone]")
    end

    test "a manual trigger persists", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      trigger = Trigger.new(:manual, %{slash_command: true, manual_alias: "run"})
      workflow = workflow_from(installation.id, Definition.new(trigger, [stop_node()]))
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      view
      |> form("#trigger-form-form", %{
        "config" => %{"manual_alias" => "deploy", "slash_command" => "true"}
      })
      |> render_submit()

      view |> element("#editor-save") |> render_click()
      assert {:ok, saved} = Workflows.get_workflow(Scope.new(member), workflow.id)
      assert {:ok, definition} = Workflow.draft(saved)
      assert definition.trigger.config.manual_alias == "deploy"
    end

    test "a webhook trigger persists", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      trigger = Trigger.new(:webhook, %{require_signature: false})
      workflow = workflow_from(installation.id, Definition.new(trigger, [stop_node()]))
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      assert has_element?(
               view,
               ~s(#trigger-form-form input[name="config[require_signature]"][aria-describedby="trigger-form-hmac-help"])
             )

      assert has_element?(view, "#trigger-form-hmac-help")

      view
      |> form("#trigger-form-form", %{
        "config" => %{"require_signature" => "true"}
      })
      |> render_submit()

      view |> element("#editor-save") |> render_click()

      assert {:ok, saved} = Workflows.get_workflow(Scope.new(member), workflow.id)
      assert {:ok, definition} = Workflow.draft(saved)
      assert definition.trigger.config.require_signature
    end
  end

  describe "secret write-only" do
    test "secret names are listed and values never appear", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "owner")

      ConnectionsFixtures.secret(Scope.new(member), %{
        name: "HTTP_TOKEN",
        value: "super-secret-value-never-show"
      })

      node = http_node()
      workflow = workflow_with(installation.id, [node])
      {:ok, view, html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      assert has_element?(view, "#node-form-#{node.id}-secrets-HTTP_TOKEN")
      refute html =~ "super-secret-value-never-show"
    end
  end

  describe "reference availability by branch" do
    test "a true-branch step cannot insert a false-branch output", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      prior = message_node()
      true_step = http_node()
      false_step = message_node()
      condition = condition_node(if_true: [true_step], if_false: [false_step])
      workflow = workflow_with(installation.id, [prior, condition])
      {:ok, view, html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      helper = "#node-form-#{true_step.id}-url-refs"
      assert has_element?(view, "#{helper}-steps-#{prior.id}-output")
      refute has_element?(view, "#{helper}-steps-#{false_step.id}-output")
      assert html =~ "steps.#{prior.id}.output"
      refute html =~ "steps.#{false_step.id}.output"
    end
  end

  describe "schedule preview and DST" do
    test "the form previews occurrences and states the DST policy", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      trigger =
        Trigger.new(:schedule, %{
          schedule_type: :daily,
          time_of_day: "02:30",
          timezone: "America/New_York"
        })

      workflow = workflow_from(installation.id, Definition.new(trigger, [stop_node()]))
      {:ok, view, html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      assert has_element?(view, "#schedule-preview")
      assert has_element?(view, "#schedule-dst-policy")
      assert html =~ "first valid instant after the"
      assert html =~ "earlier occurrence"
    end
  end

  describe "HTTP header blocklist" do
    test "a hop-by-hop header reports http_header_blocked", %{conn: conn} do
      %{session_token: token, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      node = http_node()
      workflow = workflow_with(installation.id, [node])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      view
      |> form("#node-form-#{node.id}-form", %{
        "config" => %{
          "method" => "get",
          "url" => "https://example.test/status",
          "headers" => %{"0" => %{"name" => "Host", "value" => "evil.test"}}
        }
      })
      |> render_change()

      assert has_element?(view, "#node-form-#{node.id}-issues [data-code=http_header_blocked]")
      assert has_element?(view, "#node-form-#{node.id}-blocked-targets")
      assert has_element?(view, "#node-form-#{node.id}-retry-policy")
    end

    test "an idempotency header is authored and persisted through the typed form", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install(role: "editor")

      node = http_node()
      workflow = workflow_with(installation.id, [node])
      {:ok, view, _html} = live(log_in(conn, token), ~p"/workflows/#{workflow.id}/edit")

      assert has_element?(view, "#node-form-#{node.id}-idempotency-help")

      assert has_element?(
               view,
               ~s(#node-form-#{node.id}-form input[name="config[idempotency_header]"][aria-describedby="node-form-#{node.id}-idempotency-help"])
             )

      view
      |> form("#node-form-#{node.id}-form", %{
        "config" => %{
          "method" => "post",
          "url" => "https://example.test/hook",
          "headers" => %{"0" => %{"name" => "Accept", "value" => "text/plain"}},
          "idempotency_header" => "Idempotency-Key"
        }
      })
      |> render_submit()

      view |> element("#editor-save") |> render_click()

      assert {:ok, saved} = Workflows.get_workflow(Scope.new(member), workflow.id)
      assert {:ok, definition} = Workflow.draft(saved)
      assert [%Node{config: %{idempotency_header: "Idempotency-Key"}}] = definition.steps
    end
  end

  defp workflow_with(installation_id, nodes) do
    workflow_from(installation_id, definition(nodes))
  end

  defp workflow_from(installation_id, %Definition{} = definition) do
    drafted_workflow(installation_id, %{draft_definition: Definition.encode(definition)})
  end

  defp log_in(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
  end
end
