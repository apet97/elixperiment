defmodule PumbleAutomation.Security.TenantIsolationTest do
  @moduledoc """
  Workspace A identifiers under workspace B are indistinguishable from missing,
  jobs cannot retarget another tenant, and parent-child tenant mismatches
  cannot be inserted.
  """

  use PumbleAutomationWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PumbleAutomation.DataCase, only: [errors_on: 1]
  import PumbleAutomation.TenantAssertions
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Audit
  alias PumbleAutomation.Connections
  alias PumbleAutomation.ConnectionsFixtures
  alias PumbleAutomation.Executions.Approval
  alias PumbleAutomation.Executions.ApprovalService
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.History
  alias PumbleAutomation.Executions.StepExecution
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.Executions.Workers.ApprovalDeliveryWorker
  alias PumbleAutomation.Executions.Workers.ApprovalTimeoutWorker
  alias PumbleAutomation.ExecutionsFixtures
  alias PumbleAutomation.Ingress.Endpoints
  alias PumbleAutomation.Ingress.ManualTrigger
  alias PumbleAutomation.Ingress.WebhookEndpoint
  alias PumbleAutomation.IngressFixtures
  alias PumbleAutomation.Installations.Members
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Schedule

  setup do
    a = InstallationsFixtures.install()
    b = InstallationsFixtures.install()
    a_scope = Scope.new(a.member)
    b_scope = Scope.new(b.member)

    a_activated = activate!(a_scope, a.installation.id)
    b_activated = activate!(b_scope, b.installation.id)

    {:ok, a_execution} =
      Engine.create(a_scope, %{
        workflow_version_id: a_activated.version.id,
        execution_key: "tenant-a-#{System.unique_integer([:positive])}"
      })

    {:ok, b_execution} =
      Engine.create(b_scope, %{
        workflow_version_id: b_activated.version.id,
        execution_key: "tenant-b-#{System.unique_integer([:positive])}"
      })

    {:ok, a_draft} =
      Workflows.create_workflow(a_scope, %{name: "A draft #{System.unique_integer([:positive])}"})

    a_secret = ConnectionsFixtures.secret(a_scope, %{name: "A_TOKEN"})
    a_connection = ConnectionsFixtures.connection(a_scope, %{name: "A HTTP"})
    a_endpoint = IngressFixtures.webhook_endpoint(a_activated.version)
    a_step = Repo.get_by!(StepExecution, execution_id: a_execution.id)
    a_approval = ExecutionsFixtures.approval(a_step)

    %{
      a: %{
        token: a.session_token,
        installation: a.installation,
        member: a.member,
        scope: a_scope,
        workflow: a_activated.workflow,
        version: a_activated.version,
        draft: a_draft,
        execution: a_execution,
        secret: a_secret,
        connection: a_connection,
        endpoint: a_endpoint,
        approval: a_approval
      },
      b: %{
        token: b.session_token,
        installation: b.installation,
        member: b.member,
        scope: b_scope,
        workflow: b_activated.workflow,
        version: b_activated.version,
        execution: b_execution
      }
    }
  end

  describe "web-layer Repo ban" do
    test "no web module names PumbleAutomation.Repo" do
      assert_web_modules_omit_repo()
    end
  end

  describe "context matrix" do
    test "a missing id is not_found without mismatch telemetry", %{b: b} do
      {result, events} =
        with_mismatch_events(fn -> Workflows.get_workflow(b.scope, Ecto.UUID.generate()) end)

      assert_not_found(result)
      assert events == []
    end

    test "mismatch telemetry carries only a source name", %{a: a, b: b} do
      {result, events} =
        with_mismatch_events(fn -> Workflows.get_workflow(b.scope, a.workflow.id) end)

      assert_not_found(result)
      assert [{measurements, metadata}] = events
      assert measurements == %{count: 1}
      assert metadata == %{source: "workflows"}
    end

    test "workspace A ids under B are not_found and emit mismatch telemetry", %{a: a, b: b} do
      Enum.each(context_lookups(a, b), fn {source, fun} ->
        {result, events} = with_mismatch_events(fun)
        assert_not_found(result)
        assert_mismatch_source(events, source)

        assert Enum.all?(events, fn {_measurements, metadata} ->
                 metadata == %{source: Atom.to_string(source)}
               end)
      end)
    end

    test "lists never include the other workspace's rows", %{a: a, b: b} do
      assert {:ok, workflows} = Workflows.list_workflows(b.scope)
      refute Enum.any?(workflows, &(&1.id == a.workflow.id))
      refute Enum.any?(workflows, &(&1.id == a.draft.id))

      assert {:ok, %{entries: index}} = Workflows.list_workflow_index(b.scope)
      refute Enum.any?(index, &(&1.id == a.workflow.id))

      assert {:ok, versions} = Workflows.list_versions(b.scope, b.workflow.id)
      refute Enum.any?(versions, &(&1.id == a.version.id))

      assert {:ok, secrets} = Connections.list_secrets(b.scope)
      refute Enum.any?(secrets, &(&1.id == a.secret.id))

      assert {:ok, connections} = Connections.list_connections(b.scope)
      refute Enum.any?(connections, &(&1.id == a.connection.id))

      assert {:ok, members} = Members.list(b.scope)
      refute Enum.any?(members, &(&1.id == a.member.id))

      assert Members.labels(b.scope, [a.member.id]) == %{}

      assert {:ok, %{entries: executions}} = History.list_index(b.scope)
      refute Enum.any?(executions, &(&1.id == a.execution.id))

      assert {:ok, %{entries: filtered}} =
               History.list_index(b.scope, workflow_id: a.workflow.id)

      assert filtered == []

      assert {:ok, endpoints} = Endpoints.list(b.scope)
      refute Enum.any?(endpoints, &(&1.id == a.endpoint.id))

      assert {:ok, %{entries: audit}} = Audit.list(b.scope)
      refute Enum.any?(audit, &(&1.resource_id == a.workflow.id))
      refute Enum.any?(audit, &(&1.resource_id == a.secret.id))
    end

    test "attrs cannot retarget a write onto another installation", %{a: a, b: b} do
      {:ok, workflow} =
        Workflows.create_workflow(b.scope, %{
          name: "Stay on B #{System.unique_integer([:positive])}",
          installation_id: a.installation.id
        })

      assert workflow.installation_id == b.installation.id

      {:ok, secret} =
        Connections.create_secret(b.scope, %{
          name: "B_TOKEN_#{System.unique_integer([:positive])}",
          value: "value-#{System.unique_integer([:positive])}",
          installation_id: a.installation.id
        })

      assert secret.installation_id == b.installation.id
    end
  end

  describe "LiveView matrix" do
    test "foreign resource routes do not leak existence", %{conn: conn, a: a, b: b} do
      logged_in = log_in(conn, b.token)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(logged_in, ~p"/workflows/#{a.workflow.id}")

      assert to == ~p"/workflows"

      assert {:error, {:live_redirect, %{to: to}}} =
               live(logged_in, ~p"/workflows/#{a.workflow.id}/edit")

      assert to == ~p"/workflows"

      assert {:error, {:live_redirect, %{to: to}}} =
               live(logged_in, ~p"/executions/#{a.execution.id}")

      assert to == ~p"/executions"

      assert {:error, {kind, %{to: to, flash: flash}}} =
               live(logged_in, ~p"/connections/#{a.connection.id}/edit")

      assert kind in [:live_redirect, :live_patch]
      assert to == ~p"/connections"
      assert flash["error"] == Policy.not_found().message

      {:ok, workflows_view, _html} = live(logged_in, ~p"/workflows")
      refute has_element?(workflows_view, "#workflow-#{a.workflow.id}")

      {:ok, executions_view, _html} = live(logged_in, ~p"/executions")
      refute has_element?(executions_view, "#execution-#{a.execution.id}")

      {:ok, secrets_view, html} = live(logged_in, ~p"/secrets")
      refute has_element?(secrets_view, "#secret-#{a.secret.id}")
      refute html =~ a.secret.name

      {:ok, connections_view, html} = live(logged_in, ~p"/connections")
      refute has_element?(connections_view, "#connection-#{a.connection.id}")
      refute html =~ a.connection.name

      {:ok, members_view, _html} = live(logged_in, ~p"/members")
      refute has_element?(members_view, "#member-#{a.member.id}")
    end
  end

  describe "malicious job args" do
    test "swapping installation_id cannot claim or decide another tenant's rows", %{a: a, b: b} do
      a_before = snapshot(a)
      b_before = snapshot(b)

      swapped_install = %{
        "installation_id" => b.installation.id,
        "execution_id" => a.execution.id,
        "expected_node_id" => a.execution.current_node_id,
        "generation" => a.execution.lock_version,
        "approval_id" => a.approval.id
      }

      {claim, claim_events} = with_mismatch_events(fn -> Engine.claim(swapped_install) end)
      assert claim == {:ok, :noop}
      assert_mismatch_source(claim_events, :executions)

      assert :ok = AdvanceExecutionWorker.perform(%Oban.Job{args: swapped_install})

      {timeout, timeout_events} =
        with_mismatch_events(fn -> ApprovalService.timeout(swapped_install) end)

      assert timeout == :ok
      assert_mismatch_source(timeout_events, :approvals)

      {deliver, deliver_events} =
        with_mismatch_events(fn -> ApprovalService.deliver(swapped_install) end)

      assert deliver == :ok
      assert_mismatch_source(deliver_events, :approvals)

      assert :ok = ApprovalTimeoutWorker.perform(%Oban.Job{args: swapped_install})
      assert :ok = ApprovalDeliveryWorker.perform(%Oban.Job{args: swapped_install})

      assert snapshot(a) == a_before
      assert snapshot(b) == b_before
    end

    test "swapping execution_id cannot redirect work onto the other tenant", %{a: a, b: b} do
      a_before = snapshot(a)
      b_before = snapshot(b)

      swapped_execution = %{
        "installation_id" => a.installation.id,
        "execution_id" => b.execution.id,
        "expected_node_id" => b.execution.current_node_id,
        "generation" => b.execution.lock_version,
        "approval_id" => a.approval.id
      }

      {claim, claim_events} = with_mismatch_events(fn -> Engine.claim(swapped_execution) end)
      assert claim == {:ok, :noop}
      assert_mismatch_source(claim_events, :executions)

      assert :ok = AdvanceExecutionWorker.perform(%Oban.Job{args: swapped_execution})
      assert :ok = ApprovalService.timeout(swapped_execution)
      assert :ok = ApprovalService.deliver(swapped_execution)

      assert snapshot(a) == a_before
      assert snapshot(b) == b_before
    end
  end

  describe "foreign-key mismatch" do
    test "refuses a webhook whose workflow belongs to another installation", %{a: a, b: b} do
      assert {:error, changeset} =
               %WebhookEndpoint{}
               |> WebhookEndpoint.changeset(%{
                 installation_id: b.installation.id,
                 workflow_id: a.workflow.id,
                 workflow_version_id: a.version.id,
                 public_id: WebhookEndpoint.generate_public_id(),
                 token_digest: WebhookEndpoint.digest(WebhookEndpoint.generate_token())
               })
               |> Repo.insert()

      errors = errors_on(changeset)
      assert Map.has_key?(errors, :workflow_id) or Map.has_key?(errors, :workflow_version_id)
    end

    test "refuses a schedule whose workflow belongs to another installation", %{a: a, b: b} do
      assert {:error, changeset} =
               %Schedule{}
               |> Schedule.changeset(%{
                 installation_id: b.installation.id,
                 workflow_id: a.workflow.id,
                 workflow_version_id: a.version.id,
                 schedule_type: "daily",
                 timezone: "Etc/UTC",
                 next_run_at: DateTime.utc_now()
               })
               |> Repo.insert()

      errors = errors_on(changeset)
      assert Map.has_key?(errors, :workflow_id) or Map.has_key?(errors, :workflow_version_id)
    end

    test "refuses an execution whose version belongs to another installation", %{a: a, b: b} do
      assert {:error, changeset} =
               %Execution{}
               |> Execution.changeset(%{
                 installation_id: b.installation.id,
                 workflow_id: a.workflow.id,
                 workflow_version_id: a.version.id,
                 execution_key: "crossed-#{System.unique_integer([:positive])}",
                 status: "queued"
               })
               |> Repo.insert()

      errors = errors_on(changeset)
      assert Map.has_key?(errors, :workflow_id) or Map.has_key?(errors, :workflow_version_id)
    end
  end

  defp context_lookups(a, b) do
    [
      {:workflows, fn -> Workflows.get_workflow(b.scope, a.workflow.id) end},
      {:workflows, fn -> Workflows.duplicate_workflow(b.scope, a.workflow.id) end},
      {:workflows, fn -> Workflows.list_versions(b.scope, a.workflow.id) end},
      {:workflows, fn -> Workflows.get_version(b.scope, a.workflow.id, 1) end},
      {:workflows, fn -> Workflows.delete_draft_workflow(b.scope, a.draft.id) end},
      {:workflows,
       fn -> Workflows.update_draft(b.scope, a.workflow.id, definition([delay_node()]), 0) end},
      {:workflows, fn -> Workflows.activate_workflow(b.scope, a.workflow.id, 0) end},
      {:workflows, fn -> Workflows.deactivate_workflow(b.scope, a.workflow.id) end},
      {:workflows, fn -> Workflows.archive_workflow(b.scope, a.workflow.id) end},
      {:connections, fn -> Connections.get_secret(b.scope, a.secret.id) end},
      {:connections, fn -> Connections.rotate_secret(b.scope, a.secret.id, "replacement") end},
      {:connections, fn -> Connections.delete_secret(b.scope, a.secret.id) end},
      {:connections, fn -> Connections.get_connection(b.scope, a.connection.id) end},
      {:connections, fn -> Connections.delete_connection(b.scope, a.connection.id) end},
      {:connections, fn -> Connections.test_connection(b.scope, a.connection.id) end},
      {:members, fn -> Members.update_role(b.scope, a.member.id, "viewer") end},
      {:executions, fn -> History.get_detail(b.scope, a.execution.id) end},
      {:executions, fn -> Engine.cancel(b.scope, a.execution.id) end},
      {:executions, fn -> Engine.resolve_uncertain(b.scope, a.execution.id, :failed) end},
      {:engine,
       fn -> Engine.create(b.scope, %{workflow_version_id: a.version.id, execution_key: "x"}) end},
      {:manual_trigger,
       fn ->
         ManualTrigger.run_browser(b.scope, %{
           run_mode: "dry_run",
           workflow_version_id: a.version.id
         })
       end},
      {:webhooks, fn -> Endpoints.rotate(b.scope, a.endpoint.id) end}
    ]
  end

  defp activate!(scope, installation_id) do
    workflow =
      drafted_workflow(installation_id, %{
        name: "Tenant #{System.unique_integer([:positive])}",
        draft_definition: Definition.encode(definition([delay_node()]))
      })

    {:ok, result} = Workflows.activate_workflow(scope, workflow.id, 0)
    result
  end

  defp snapshot(%{execution: execution, approval: approval}) do
    %{
      execution: Repo.get!(Execution, execution.id).status,
      approval: Repo.get!(Approval, approval.id).status
    }
  end

  defp snapshot(%{execution: execution}) do
    %{execution: Repo.get!(Execution, execution.id).status}
  end
end
