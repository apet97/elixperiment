defmodule PumbleAutomation.Ingress.ManualTriggerTest do
  @moduledoc """
  Manual Pumble and browser ingestion: tenant-scoped alias resolution,
  interaction dedup, message-source snapshots, and editor-only live/dry-run.
  """

  use PumbleAutomation.DataCase, async: true
  use Oban.Testing, repo: PumbleAutomation.Repo

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.Ingress.ManualTrigger
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.Ingress.Service
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Pumble.Payload
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger

  setup do
    %{installation: installation, member: member} = InstallationsFixtures.install()

    %{
      scope: Scope.new(member),
      installation: installation,
      installation_id: installation.id,
      workspace_id: installation.pumble_workspace_id
    }
  end

  describe "alias resolution" do
    test "a slash command with an active alias creates one execution and job", context do
      %{version: version} = activate_manual!(context, "deploy")

      assert {:ok, :started} =
               Service.record_interaction(
                 slash(context.workspace_id, "deploy"),
                 context(raw_body: "slash-deploy")
               )

      assert [%ReceivedEvent{class: "interaction", processing_state: "processed"} = receipt] =
               receipts(context.installation_id)

      assert [%Execution{} = execution] = executions(context.installation_id)
      assert execution.workflow_version_id == version.id
      assert execution.received_event_id == receipt.id
      assert execution.trigger_snapshot["alias"] == "deploy"
      assert execution.context["execution"]["run_mode"] == "live"
      assert_enqueued(worker: AdvanceExecutionWorker, args: %{execution_id: execution.id})
    end

    test "the same alias in another tenant does not start this tenant's workflow", context do
      activate_manual!(context, "deploy")
      %{installation: other, member: other_member} = InstallationsFixtures.install()
      other_scope = Scope.new(other_member)

      other_workflow =
        drafted_workflow(other.id, %{
          slug: "deploy",
          draft_definition: Definition.encode(manual_definition("deploy"))
        })

      {:ok, _} = Workflows.activate_workflow(other_scope, other_workflow.id, 0)

      assert {:ok, :started} =
               Service.record_interaction(
                 slash(other.pumble_workspace_id, "deploy"),
                 context(raw_body: "other-deploy")
               )

      assert executions(context.installation_id) == []
      assert length(executions(other.id)) == 1
    end

    test "an unknown alias is not found and creates no execution", context do
      activate_manual!(context, "deploy")

      assert {:ok, :not_found} =
               Service.record_interaction(
                 slash(context.workspace_id, "missing"),
                 context(raw_body: "slash-missing")
               )

      assert_no_execution(context.installation_id)
    end

    test "a disabled workflow is not found", context do
      %{workflow: workflow} = activate_manual!(context, "deploy")
      {:ok, _} = Workflows.deactivate_workflow(context.scope, workflow.id)

      assert {:ok, :not_found} =
               Service.record_interaction(
                 slash(context.workspace_id, "deploy"),
                 context(raw_body: "slash-disabled")
               )

      assert_no_execution(context.installation_id)
    end
  end

  describe "duplicates" do
    test "the same Pumble interaction creates at most one execution", context do
      activate_manual!(context, "deploy")
      payload = slash(context.workspace_id, "deploy", trigger_id: "TRIG-dup")
      ctx = context(raw_body: "same-interaction")

      assert {:ok, :started} = Service.record_interaction(payload, ctx)
      assert {:ok, :duplicate} = Service.record_interaction(payload, ctx)

      assert length(executions(context.installation_id)) == 1
      assert length(receipts(context.installation_id)) == 1
      assert Repo.aggregate(Oban.Job, :count) == 1
    end
  end

  describe "message source" do
    test "a message shortcut stores a bounded source-message snapshot", context do
      activate_manual!(context, "deploy",
        slash_command: false,
        global_shortcut: false,
        message_shortcut: true
      )

      payload = message_shortcut(context.workspace_id, message_id: "M-source")

      assert {:ok, :started} =
               Service.record_interaction(payload, context(raw_body: "shortcut-source"))

      assert [%Execution{} = execution] = executions(context.installation_id)

      assert execution.trigger_snapshot["source_message"] == %{
               "channel_id" => "channel-1",
               "message_id" => "M-source"
             }
    end
  end

  describe "picker" do
    test "a shortcut with several aliases returns a modal picker and starts nothing", context do
      activate_manual!(context, "alpha", global_shortcut: true, slash_command: false)
      activate_manual!(context, "beta", global_shortcut: true, slash_command: false)

      assert {:ok, {:picker, envelope}} =
               Service.record_interaction(
                 global_shortcut(context.workspace_id),
                 context(raw_body: "picker")
               )

      assert envelope["view"]["type"] == "modal"

      values =
        Enum.map(envelope["view"]["blocks"] |> hd() |> Map.fetch!("elements"), & &1["value"])

      assert Enum.sort(values) == ["alpha", "beta"]
      assert_no_execution(context.installation_id)
    end

    test "picker adapters stay isolated from each other", _context do
      modal = ManualTrigger.picker_modal_response(["deploy"])
      ack = ManualTrigger.picker_ack_message(["deploy"])

      assert is_map(modal)
      assert is_binary(ack)
      refute ack =~ "view"
      assert modal["view"]
    end

    test "the dynamic picker returns only matching picker-visible aliases", context do
      activate_manual!(context, "nightly", global_shortcut: true, slash_command: false)
      activate_manual!(context, "daytime", message_shortcut: true, slash_command: false)
      activate_manual!(context, "night_hidden", slash_command: true)

      assert {:ok, {:dynamic_menu, envelope}} =
               Service.record_interaction(
                 dynamic_menu(context.workspace_id, query: "NIGHT", value: "nightly"),
                 context(raw_body: "dynamic-night")
               )

      assert envelope == %{
               "onAction" => "pick_workflow",
               "options" => [
                 %{
                   "text" => %{"type" => "plain_text", "text" => "nightly"},
                   "value" => "nightly"
                 }
               ],
               "triggerId" => "TRIG-menu",
               "value" => "nightly"
             }

      assert_no_execution(context.installation_id)
      assert receipts(context.installation_id) == []
    end

    test "the dynamic picker is tenant scoped", context do
      activate_manual!(context, "local", global_shortcut: true, slash_command: false)

      %{installation: other, member: other_member} =
        InstallationsFixtures.install(workspace: "other-menu-workspace")

      other_context = %{
        scope: Scope.new(other_member),
        installation_id: other.id,
        workspace_id: other.pumble_workspace_id
      }

      activate_manual!(other_context, "foreign", global_shortcut: true, slash_command: false)

      assert {:ok, {:dynamic_menu, envelope}} =
               Service.record_interaction(
                 dynamic_menu(context.workspace_id),
                 context(raw_body: "dynamic-local")
               )

      assert Enum.map(envelope["options"], & &1["value"]) == ["local"]
      refute inspect(envelope) =~ "foreign"
      assert_no_execution(context.installation_id)
      assert executions(other.id) == []
    end

    test "unknown actions, unknown tenants, and oversized queries return no options", context do
      activate_manual!(context, "visible", global_shortcut: true, slash_command: false)

      assert {:ok, :not_found} =
               Service.record_interaction(
                 dynamic_menu(context.workspace_id, on_action: "unknown_menu"),
                 context(raw_body: "unknown-action")
               )

      assert {:ok, :not_found} =
               Service.record_interaction(
                 dynamic_menu("unknown-workspace"),
                 context(raw_body: "unknown-tenant")
               )

      assert {:ok, :not_found} =
               Service.record_interaction(
                 dynamic_menu(context.workspace_id, query: String.duplicate("q", 257)),
                 context(raw_body: "oversized-query")
               )

      assert_no_execution(context.installation_id)
      assert receipts(context.installation_id) == []
    end

    test "the options query itself requires the installation to remain active", context do
      activate_manual!(context, "visible", global_shortcut: true, slash_command: false)

      queries =
        capture_queries(fn ->
          assert {:ok, {:dynamic_menu, _envelope}} =
                   Service.record_interaction(
                     dynamic_menu(context.workspace_id),
                     context(raw_body: "active-query-proof")
                   )
        end)

      assert Enum.any?(queries, fn %{source: source, query: query} ->
               source == "trigger_bindings" and
                 String.contains?(query, ~s("status" = 'active'))
             end)

      context.installation
      |> Installation.changeset(%{status: "revoked"})
      |> Repo.update!()

      assert {:ok, :not_found} =
               Service.record_interaction(
                 dynamic_menu(context.workspace_id),
                 context(raw_body: "revoked-query-proof")
               )

      assert_no_execution(context.installation_id)
    end
  end

  describe "browser runs" do
    test "an editor dry-run creates an execution in dry_run mode", context do
      %{version: version} = activate_manual!(context, "deploy")
      editor = %Scope{context.scope | role: "editor"}

      assert {:ok, %Execution{} = execution} =
               ManualTrigger.run_browser(editor, %{alias: "deploy", run_mode: "dry_run"})

      assert execution.context["execution"]["run_mode"] == "dry_run"
      assert execution.workflow_version_id == version.id
      assert execution.execution_key =~ "man:"
    end

    test "an explicit live run is stored as live", context do
      activate_manual!(context, "deploy")

      assert {:ok, %Execution{} = execution} =
               ManualTrigger.run_browser(context.scope, %{alias: "deploy", run_mode: "live"})

      assert execution.context["execution"]["run_mode"] == "live"
    end

    test "a viewer cannot live-run", context do
      activate_manual!(context, "deploy")
      viewer = %Scope{context.scope | role: "viewer"}

      assert {:error, %Error{class: :permission}} =
               ManualTrigger.run_browser(viewer, %{alias: "deploy", run_mode: "live"})

      assert_no_execution(context.installation_id)
    end

    test "a missing run mode is refused", context do
      activate_manual!(context, "deploy")

      assert {:error, %Error{code: :invalid_run_mode}} =
               ManualTrigger.run_browser(context.scope, %{alias: "deploy"})
    end

    test "another tenant's version id is indistinguishable from missing", context do
      activate_manual!(context, "deploy")
      %{installation: other, member: other_member} = InstallationsFixtures.install()
      other_scope = Scope.new(other_member)

      other_workflow =
        drafted_workflow(other.id, %{
          slug: "other",
          draft_definition: Definition.encode(manual_definition("other"))
        })

      {:ok, %{version: other_version}} =
        Workflows.activate_workflow(other_scope, other_workflow.id, 0)

      missing = Ecto.UUID.generate()

      assert {:error, foreign} =
               ManualTrigger.run_browser(context.scope, %{
                 workflow_version_id: other_version.id,
                 run_mode: "dry_run"
               })

      assert {:error, absent} =
               ManualTrigger.run_browser(context.scope, %{
                 workflow_version_id: missing,
                 run_mode: "dry_run"
               })

      assert foreign == absent
      assert foreign == Policy.not_found()
    end

    test "an idempotency key collapses a second browser run", context do
      activate_manual!(context, "deploy")

      attrs = %{alias: "deploy", run_mode: "dry_run", idempotency_key: "browser-once"}

      assert {:ok, first} = ManualTrigger.run_browser(context.scope, attrs)
      assert {:ok, second} = ManualTrigger.run_browser(context.scope, attrs)
      assert first.id == second.id
      assert length(executions(context.installation_id)) == 1
    end
  end

  describe "transport" do
    test "a callback without retained bytes is not acknowledged as started", context do
      activate_manual!(context, "deploy")

      assert {:error, %Error{class: :validation, code: :missing_body}} =
               Service.record_interaction(slash(context.workspace_id, "deploy"), %{})

      assert_no_execution(context.installation_id)
    end

    test "an unknown workspace is not found and creates no tenant row", _context do
      assert {:ok, :not_found} =
               Service.record_interaction(
                 slash("workspace-never-installed", "deploy"),
                 context(raw_body: "ghost")
               )

      refute Repo.exists?(ReceivedEvent)
      refute Repo.exists?(Execution)
    end
  end

  defp activate_manual!(context, alias_name, entry \\ []) do
    workflow =
      drafted_workflow(context.installation_id, %{
        name: "Manual #{alias_name}",
        slug: alias_name <> "-#{System.unique_integer([:positive])}",
        draft_definition: Definition.encode(manual_definition(alias_name, entry))
      })

    {:ok, result} = Workflows.activate_workflow(context.scope, workflow.id, 0)
    result
  end

  defp manual_definition(alias_name, entry \\ []) do
    config =
      Map.merge(
        %{
          manual_alias: alias_name,
          slash_command: true,
          global_shortcut: false,
          message_shortcut: false
        },
        Map.new(entry)
      )

    Definition.new(Trigger.new(:manual, config), [delay_node()])
  end

  defp slash(workspace_id, text, opts \\ []) do
    %Payload.SlashCommand{
      slash_command: "/workflow",
      text: text,
      user_id: "user-1",
      channel_id: "channel-1",
      workspace_id: workspace_id,
      trigger_id: Keyword.get(opts, :trigger_id, "TRIG-#{System.unique_integer([:positive])}")
    }
  end

  defp global_shortcut(workspace_id) do
    %Payload.GlobalShortcut{
      shortcut: "run_workflow",
      user_id: "user-1",
      channel_id: "channel-1",
      workspace_id: workspace_id,
      trigger_id: "TRIG-#{System.unique_integer([:positive])}"
    }
  end

  defp message_shortcut(workspace_id, opts) do
    %Payload.MessageShortcut{
      shortcut: "run_workflow_on_message",
      message_id: Keyword.get(opts, :message_id, "M-1"),
      user_id: "user-1",
      channel_id: "channel-1",
      workspace_id: workspace_id,
      trigger_id: "TRIG-#{System.unique_integer([:positive])}"
    }
  end

  defp dynamic_menu(workspace_id, opts \\ []) do
    %Payload.DynamicMenu{
      on_action: Keyword.get(opts, :on_action, "pick_workflow"),
      query: Keyword.get(opts, :query),
      value: Keyword.get(opts, :value),
      workspace_id: workspace_id,
      user_id: "user-1",
      trigger_id: "TRIG-menu"
    }
  end

  defp capture_queries(fun) do
    handler = "manual-trigger-query-proof-#{System.unique_integer([:positive])}"
    test = self()

    :ok =
      :telemetry.attach(
        handler,
        [:pumble_automation, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test, do: send(test, {:manual_trigger_query, metadata})
        end,
        nil
      )

    try do
      fun.()
      drain_queries([])
    after
      :telemetry.detach(handler)
    end
  end

  defp drain_queries(queries) do
    receive do
      {:manual_trigger_query, metadata} -> drain_queries([metadata | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp context(opts) do
    opts
    |> Enum.into(%{})
    |> Map.put_new(:raw_body, "body-#{System.unique_integer([:positive])}")
    |> Map.put_new(:signature, "sig")
  end

  defp receipts(installation_id) do
    Repo.all(from event in ReceivedEvent, where: event.installation_id == ^installation_id)
  end

  defp executions(installation_id) do
    Repo.all(from execution in Execution, where: execution.installation_id == ^installation_id)
  end

  defp assert_no_execution(installation_id) do
    refute Repo.exists?(from e in Execution, where: e.installation_id == ^installation_id)
    assert Repo.aggregate(Oban.Job, :count) == 0
  end
end
