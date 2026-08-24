defmodule PumbleAutomation.Ingress.LifecycleIngestionTest do
  @moduledoc """
  APP_UNINSTALLED and APP_UNAUTHORIZED go through signed ingress into the
  installation lifecycle, never into user workflow execution.
  """

  use PumbleAutomation.DataCase, async: true
  use Oban.Testing, repo: PumbleAutomation.Repo

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.StepExecution
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.Ingress.Service
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Service, as: InstallationsService
  alias PumbleAutomation.Installations.UserAuthorization
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Pumble.Payload
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition

  setup do
    %{installation: installation, member: member, authorization: authorization} =
      InstallationsFixtures.install()

    %{
      scope: Scope.new(member),
      installation: installation,
      authorization: authorization,
      installation_id: installation.id,
      workspace_id: installation.pumble_workspace_id
    }
  end

  describe "lifecycle transitions" do
    test "APP_UNINSTALLED blocks the tenant, purges credentials, and creates no execution",
         context do
      activate!(context)

      payload = lifecycle_payload(context.workspace_id, "APP_UNINSTALLED")

      assert :accepted = Service.enqueue_event(payload, context(raw_body: "uninstalled"))

      stored = Repo.get!(Installation, context.installation_id)
      assert stored.status == "uninstalled"
      assert stored_bot_token(context.installation_id) == nil
      assert stored_access_token(context.authorization.id) == nil

      assert [
               %ReceivedEvent{
                 class: "lifecycle",
                 type: "APP_UNINSTALLED",
                 processing_state: "processed"
               }
             ] =
               receipts(context.installation_id)

      assert_no_execution(context.installation_id)
      assert length(retention_jobs(context.installation_id)) == 1
    end

    test "APP_UNAUTHORIZED revokes the bot credential and creates no execution", context do
      activate!(context)

      payload = lifecycle_payload(context.workspace_id, "APP_UNAUTHORIZED")

      assert :accepted = Service.enqueue_event(payload, context(raw_body: "unauthorized"))

      stored = Repo.get!(Installation, context.installation_id)
      assert stored.status == "revoked"
      assert stored_bot_token(context.installation_id) == nil
      refute stored_access_token(context.authorization.id) == nil
      assert Repo.get!(UserAuthorization, context.authorization.id).status == "active"

      assert [
               %ReceivedEvent{
                 class: "lifecycle",
                 type: "APP_UNAUTHORIZED",
                 processing_state: "processed"
               }
             ] =
               receipts(context.installation_id)

      assert_no_execution(context.installation_id)
      assert retention_jobs(context.installation_id) == []
    end
  end

  describe "duplicates" do
    test "a second uninstall converges on one receipt, one audit, and one retention job",
         context do
      payload = lifecycle_payload(context.workspace_id, "APP_UNINSTALLED", id: "EVT-dup-un")
      ctx = context(raw_body: "same-uninstall")

      assert :accepted = Service.enqueue_event(payload, ctx)
      assert :accepted = Service.enqueue_event(payload, ctx)

      assert [%ReceivedEvent{processing_state: "processed"}] = receipts(context.installation_id)
      assert audit_count(context.installation_id, "installation.uninstalled") == 1
      assert length(retention_jobs(context.installation_id)) == 1
      assert Repo.get!(Installation, context.installation_id).status == "uninstalled"
    end

    test "a second unauthorized converges on one receipt and one audit row", context do
      payload = lifecycle_payload(context.workspace_id, "APP_UNAUTHORIZED", id: "EVT-dup-ua")
      ctx = context(raw_body: "same-unauthorized")

      assert :accepted = Service.enqueue_event(payload, ctx)
      assert :accepted = Service.enqueue_event(payload, ctx)

      assert [%ReceivedEvent{processing_state: "processed"}] = receipts(context.installation_id)
      assert audit_count(context.installation_id, "installation.unauthorized") == 1
      assert Repo.get!(Installation, context.installation_id).status == "revoked"
    end
  end

  describe "out-of-order unauthorized and uninstall" do
    test "uninstall then unauthorized stays uninstalled", context do
      uninstall = lifecycle_payload(context.workspace_id, "APP_UNINSTALLED", id: "EVT-oo-un")
      unauthorized = lifecycle_payload(context.workspace_id, "APP_UNAUTHORIZED", id: "EVT-oo-ua")

      assert :accepted = Service.enqueue_event(uninstall, context(raw_body: "first-un"))
      assert :accepted = Service.enqueue_event(unauthorized, context(raw_body: "second-ua"))

      stored = Repo.get!(Installation, context.installation_id)
      assert stored.status == "uninstalled"
      refute stored.status == "revoked"
      assert stored_bot_token(context.installation_id) == nil

      types = receipts(context.installation_id) |> Enum.map(& &1.type) |> Enum.sort()
      assert types == ["APP_UNAUTHORIZED", "APP_UNINSTALLED"]
      assert Enum.all?(receipts(context.installation_id), &(&1.processing_state == "processed"))
      assert_no_execution(context.installation_id)
    end

    test "unauthorized then uninstall becomes uninstalled", context do
      unauthorized = lifecycle_payload(context.workspace_id, "APP_UNAUTHORIZED", id: "EVT-ou-ua")
      uninstall = lifecycle_payload(context.workspace_id, "APP_UNINSTALLED", id: "EVT-ou-un")

      assert :accepted = Service.enqueue_event(unauthorized, context(raw_body: "first-ua"))
      assert :accepted = Service.enqueue_event(uninstall, context(raw_body: "second-un"))

      stored = Repo.get!(Installation, context.installation_id)
      assert stored.status == "uninstalled"
      assert stored_bot_token(context.installation_id) == nil
      assert stored_access_token(context.authorization.id) == nil
      assert_no_execution(context.installation_id)
    end
  end

  describe "unknown workspace" do
    test "is acknowledged as an anomaly and creates no tenant data" do
      attach_telemetry()
      workspace_id = "workspace-never-installed-#{System.unique_integer([:positive])}"
      payload = lifecycle_payload(workspace_id, "APP_UNINSTALLED")

      assert :accepted = Service.enqueue_event(payload, context(raw_body: "unknown"))

      assert_receive {:telemetry, [:pumble_automation, :ingress, :enqueue, :unknown_workspace],
                      %{count: 1}, metadata}

      assert metadata.class == "lifecycle"
      assert metadata.type == "APP_UNINSTALLED"
      refute Map.has_key?(metadata, :workspace_id)

      refute Repo.exists?(from i in Installation, where: i.pumble_workspace_id == ^workspace_id)
      refute Repo.exists?(ReceivedEvent)
      refute Repo.exists?(Execution)
    end
  end

  describe "source restrictions" do
    test "webhook, browser, and missing sources cannot apply a lifecycle transition", context do
      before = stored_bot_token(context.installation_id)

      for opts <- [[source: "webhook"], [source: "browser"], []] do
        assert {:error, %Error{class: :permission, code: :lifecycle_source_refused}} =
                 InstallationsService.apply_lifecycle(
                   context.installation_id,
                   "APP_UNINSTALLED",
                   opts
                 )

        assert Repo.get!(Installation, context.installation_id).status == "active"
        assert stored_bot_token(context.installation_id) == before
      end
    end
  end

  defp activate!(context) do
    workflow =
      drafted_workflow(context.installation_id, %{
        name: "Lifecycle #{System.unique_integer([:positive])}",
        slug: "lifecycle-#{System.unique_integer([:positive])}",
        draft_definition: Definition.encode(definition([delay_node()]))
      })

    {:ok, result} = Workflows.activate_workflow(context.scope, workflow.id, 0)
    result
  end

  defp lifecycle_payload(workspace_id, type, opts \\ []) do
    id = Keyword.get(opts, :id, "EVT-#{System.unique_integer([:positive])}")

    %Payload.Event{
      message_type: "APP_EVENT",
      event_type: type,
      workspace_id: workspace_id,
      body: lifecycle_body(type, workspace_id, id)
    }
  end

  defp lifecycle_body("APP_UNINSTALLED", workspace_id, id) do
    %{
      "id" => id,
      "app" => "APP_TEST",
      "workspace" => workspace_id,
      "installedBy" => "pumble-user-1",
      "botUser" => "bot-user",
      "uninstalledAt" => 1_767_225_600_000
    }
  end

  defp lifecycle_body("APP_UNAUTHORIZED", workspace_id, id) do
    %{
      "id" => id,
      "app" => "APP_TEST",
      "appInstallation" => "INST_TEST",
      "workspaceUser" => "pumble-user-1",
      "workspace" => workspace_id,
      "grantedScopes" => ["messages:read"],
      "accessGranted" => false
    }
  end

  defp context(opts) do
    opts
    |> Enum.into(%{})
    |> Map.put_new(:raw_body, "body-#{System.unique_integer([:positive])}")
    |> Map.put_new(:signature, "sig")
  end

  defp receipts(installation_id) do
    Repo.all(
      from event in ReceivedEvent,
        where: event.installation_id == ^installation_id,
        order_by: event.inserted_at
    )
  end

  defp assert_no_execution(installation_id) do
    refute Repo.exists?(from e in Execution, where: e.installation_id == ^installation_id)
    refute Repo.exists?(from s in StepExecution, where: s.installation_id == ^installation_id)

    refute Repo.exists?(
             from job in Oban.Job,
               where: job.worker == "PumbleAutomation.Executions.Workers.AdvanceExecutionWorker",
               where: fragment("? ->> 'installation_id' = ?", job.args, ^installation_id)
           )
  end

  defp retention_jobs(installation_id) do
    Repo.all(
      from job in Oban.Job,
        where: job.worker == "PumbleAutomation.Executions.Workers.RetentionWorker",
        where: fragment("? ->> 'installation_id' = ?", job.args, ^installation_id)
    )
  end

  defp audit_count(installation_id, action) do
    Repo.aggregate(
      from(event in AuditEvent,
        where: event.installation_id == ^installation_id and event.action == ^action
      ),
      :count
    )
  end

  defp stored_bot_token(id) do
    scalar("SELECT encrypted_bot_token FROM installations WHERE id = $1", id)
  end

  defp stored_access_token(id) do
    scalar("SELECT encrypted_access_token FROM user_authorizations WHERE id = $1", id)
  end

  defp scalar(sql, id) do
    %{rows: [[value]]} = Repo.query!(sql, [Ecto.UUID.dump!(id)])
    value
  end

  defp attach_telemetry do
    handler = "lifecycle-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        Service.telemetry_event() ++ [:unknown_workspace],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end
end

defmodule PumbleAutomation.Ingress.LifecycleIngestionRaceTest do
  @moduledoc """
  Duplicate lifecycle callbacks and an uninstall racing a worker claim, against
  a real database rather than the sandbox.
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import Ecto.Query, only: [from: 2]
  import PumbleAutomation.WorkflowsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.Ingress.Service
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Pumble.Payload
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "concurrent duplicate uninstalls produce one receipt and one terminal state" do
    %{installation: installation} = InstallationsFixtures.install()
    on_exit(fn -> cleanup!(installation.id) end)

    payload =
      lifecycle_payload(installation.pumble_workspace_id, "APP_UNINSTALLED", id: "EVT-race-un")

    ctx = %{raw_body: "race-uninstall", signature: "sig"}

    results =
      1..2
      |> Task.async_stream(
        fn _index -> Service.enqueue_event(payload, ctx) end,
        max_concurrency: 2,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &(&1 == :accepted))

    assert Repo.aggregate(
             from(event in ReceivedEvent, where: event.installation_id == ^installation.id),
             :count
           ) == 1

    assert Repo.get!(Installation, installation.id).status == "uninstalled"
    assert stored_bot_token(installation.id) == nil

    refute Repo.exists?(from e in Execution, where: e.installation_id == ^installation.id)

    assert Repo.aggregate(
             from(job in Oban.Job,
               where: job.worker == "PumbleAutomation.Executions.Workers.RetentionWorker",
               where: fragment("? ->> 'installation_id' = ?", job.args, ^installation.id)
             ),
             :count
           ) == 1
  end

  test "uninstall racing a worker claim still blocks credentials and creates no workflow run" do
    %{installation: installation, member: member} = InstallationsFixtures.install()
    on_exit(fn -> cleanup!(installation.id) end)

    scope = Scope.new(member)

    workflow =
      drafted_workflow(installation.id, %{
        draft_definition: Definition.encode(definition([delay_node()]))
      })

    {:ok, activated} = Workflows.activate_workflow(scope, workflow.id, 0)

    {:ok, execution} =
      Engine.create(scope, %{
        workflow_version_id: activated.version.id,
        execution_key: "life-race-#{System.unique_integer([:positive])}"
      })

    args = %{
      "installation_id" => execution.installation_id,
      "execution_id" => execution.id,
      "expected_node_id" => execution.current_node_id,
      "generation" => 0
    }

    payload =
      lifecycle_payload(installation.pumble_workspace_id, "APP_UNINSTALLED", id: "EVT-vs-worker")

    ctx = %{raw_body: "vs-worker", signature: "sig"}
    parent = self()

    claim_task =
      Task.async(fn ->
        send(parent, {:ready, self()})

        receive do
          :go -> Engine.claim(args)
        end
      end)

    uninstall_task =
      Task.async(fn ->
        send(parent, {:ready, self()})

        receive do
          :go -> Service.enqueue_event(payload, ctx)
        end
      end)

    pids =
      Enum.map(1..2, fn _index ->
        receive do
          {:ready, pid} -> pid
        after
          5_000 -> flunk("racer did not reach the barrier")
        end
      end)

    Enum.each(pids, &send(&1, :go))

    claim_result = Task.await(claim_task, 30_000)
    uninstall_result = Task.await(uninstall_task, 30_000)

    assert uninstall_result == :accepted
    assert match?({:ok, _}, claim_result)

    stored = Repo.get!(Installation, installation.id)
    assert stored.status == "uninstalled"
    assert stored_bot_token(installation.id) == nil

    assert Repo.aggregate(
             from(event in ReceivedEvent, where: event.installation_id == ^installation.id),
             :count
           ) == 1

    assert Repo.aggregate(
             from(e in Execution, where: e.installation_id == ^installation.id),
             :count
           ) == 1
  end

  defp lifecycle_payload(workspace_id, type, opts) do
    id = Keyword.fetch!(opts, :id)

    %Payload.Event{
      message_type: "APP_EVENT",
      event_type: type,
      workspace_id: workspace_id,
      body: %{
        "id" => id,
        "app" => "APP_TEST",
        "workspace" => workspace_id,
        "installedBy" => "pumble-user-1",
        "botUser" => "bot-user",
        "uninstalledAt" => 1_767_225_600_000
      }
    }
  end

  defp stored_bot_token(id) do
    %{rows: [[value]]} =
      Repo.query!("SELECT encrypted_bot_token FROM installations WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    value
  end

  defp cleanup!(installation_id) do
    Repo.delete_all(
      from job in Oban.Job,
        where: fragment("? ->> 'installation_id' = ?", job.args, ^installation_id)
    )

    InstallationsFixtures.erase!(installation_id)
  end
end
