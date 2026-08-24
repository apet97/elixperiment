defmodule PumbleAutomation.Security.LoopPreventionTest do
  @moduledoc """
  P13-T03: own-bot filtering, include-bot warning, internal lineage, forged
  metadata, and depth/descendant caps. Loop telemetry never carries message
  text.
  """

  use PumbleAutomation.DataCase, async: false
  use Oban.Testing, repo: PumbleAutomation.Repo

  import PumbleAutomation.IngressFixtures
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Lineage
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.Ingress.Service
  alias PumbleAutomation.Ingress.WebhookEndpoint
  alias PumbleAutomation.Ingress.WebhookService
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Pumble.Normalizer
  alias PumbleAutomation.Pumble.Payload
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.ValidationIssue
  alias PumbleAutomation.Workflows.Validator

  @bot_user_id "pumble-bot-1"

  setup do
    previous_limits = Application.get_env(:pumble_automation, :limits)
    WebhookService.reset_rate_table()

    on_exit(fn ->
      Application.put_env(:pumble_automation, :limits, previous_limits)
      WebhookService.reset_rate_table()
    end)

    %{installation: installation, member: member} = InstallationsFixtures.install()

    %{
      scope: Scope.new(member),
      installation: installation,
      installation_id: installation.id,
      workspace_id: installation.pumble_workspace_id
    }
  end

  describe "own-bot and human messages" do
    test "default event triggers ignore the installation bot", context do
      activate!(context, definition([delay_node()]))
      handler = attach_lineage()

      assert :accepted = Service.enqueue_event(bot_payload(context), transport())
      assert executions(context.installation_id) == []
      assert_receive {:lineage, _measurements, metadata}
      assert metadata.reason == "bot_filtered"
      refute Map.has_key?(metadata, :text)
      refute Map.has_key?(metadata, "text")

      :telemetry.detach(handler)
    end

    test "a human message still starts a run", context do
      activate!(context, definition([delay_node()]))

      assert :accepted = Service.enqueue_event(human_payload(context), transport())

      assert [%Execution{lineage_depth: 0, root_execution_id: nil}] =
               executions(context.installation_id)
    end
  end

  describe "include-bot warning and limit" do
    test "turning off ignore-bot warns and does not block validation" do
      issues = Validator.validate(include_bot_definition())
      warning = Enum.find(issues, &(&1.code == :include_bot_loop_risk))
      assert warning
      assert warning.severity == :warning
      assert warning.message == Lineage.include_bot_warning_message()
      refute ValidationIssue.errors?(issues)
    end

    test "include-bot admits one bot-authored run then stops amplification", context do
      activate!(context, include_bot_definition())

      assert :accepted = Service.enqueue_event(bot_payload(context, rid: "bot-1"), transport())
      assert [%Execution{lineage_depth: 0}] = executions(context.installation_id)

      assert :accepted = Service.enqueue_event(bot_payload(context, rid: "bot-2"), transport())
      assert [%Execution{}] = executions(context.installation_id)
    end
  end

  describe "A→B→A lineage" do
    test "a child of a different workflow is admitted and returning to A is a loop", context do
      %{version: version_a} = activate!(context, definition([delay_node()]), name: "Lin A")
      %{version: version_b} = activate!(context, definition([stop_node()]), name: "Lin B")

      {:ok, run_a} =
        Engine.create(context.scope, %{
          workflow_version_id: version_a.id,
          execution_key: "lin-a-#{unique()}"
        })

      {:ok, run_b} =
        Engine.create(context.scope, %{
          workflow_version_id: version_b.id,
          execution_key: "lin-b-#{unique()}",
          parent_execution_id: run_a.id
        })

      assert run_b.lineage_depth == 1
      assert run_b.root_execution_id == run_a.id

      handler = attach_lineage()

      assert {:error, %Error{class: :validation, code: :lineage_loop}} =
               Engine.create(context.scope, %{
                 workflow_version_id: version_a.id,
                 execution_key: "lin-a2-#{unique()}",
                 parent_execution_id: run_b.id
               })

      assert_receive {:lineage, _measurements, metadata}
      assert metadata.reason == "cycle"
      refute Map.has_key?(metadata, :text)
      :telemetry.detach(handler)
    end
  end

  describe "forged metadata" do
    test "payload lineage fields and subtype never decide bot origin", context do
      assert {:ok, event} =
               Normalizer.normalize(
                 %Payload.Event{
                   message_type: "PUMBLE_EVENT",
                   event_type: "NEW_MESSAGE",
                   workspace_id: context.workspace_id,
                   body: %{
                     "aId" => @bot_user_id,
                     "cId" => "channel-1",
                     "tx" => "hello from the bot",
                     "st" => "human",
                     "bot" => false,
                     "lineage_depth" => 1,
                     "root_execution_id" => Ecto.UUID.generate(),
                     "parent_execution_id" => Ecto.UUID.generate(),
                     "rid" => "RID-forged-#{unique()}",
                     "mId" => "M-forged-#{unique()}",
                     "tsm" => 1_767_225_600_000
                   }
                 },
                 %{
                   installation_id: context.installation_id,
                   raw_body: "forged-body",
                   signature: "sig",
                   bot_user_id: @bot_user_id
                 }
               )

      assert event.bot_origin? == true
      refute Map.has_key?(event.data, :lineage_depth)
      refute Map.has_key?(event.data, :root_execution_id)
      refute Map.has_key?(event.data, :parent_execution_id)
      refute Map.has_key?(event.data, :bot_origin)
    end

    test "a Pumble event cannot supply a parent execution", context do
      %{version: version} = activate!(context, definition([delay_node()]))

      {:ok, root} =
        Engine.create(context.scope, %{
          workflow_version_id: version.id,
          execution_key: "forge-root-#{unique()}"
        })

      %{version: other} = activate!(context, definition([stop_node()]), name: "Forge other")

      assert {:ok, child} =
               Engine.create(context.scope, %{
                 workflow_version_id: other.id,
                 execution_key: "forge-child-#{unique()}",
                 parent_execution_id: root.id,
                 lineage_source: :pumble_event,
                 trigger_snapshot: %{"resource_id" => "M-unrelated"}
               })

      assert child.lineage_depth == 0
      assert is_nil(child.root_execution_id)
    end

    test "a foreign parent is indistinguishable from missing", context do
      %{version: version} = activate!(context, definition([delay_node()]))
      other = InstallationsFixtures.install()
      other_scope = Scope.new(other.member)

      %{version: other_version} =
        activate!(
          %{scope: other_scope, installation: other.installation},
          definition([delay_node()])
        )

      {:ok, foreign} =
        Engine.create(other_scope, %{
          workflow_version_id: other_version.id,
          execution_key: "foreign-#{unique()}"
        })

      assert {:error, error} =
               Engine.create(context.scope, %{
                 workflow_version_id: version.id,
                 execution_key: "local-#{unique()}",
                 parent_execution_id: foreign.id
               })

      assert error == Policy.not_found()
    end
  end

  describe "depth and descendant caps" do
    test "depth four is refused before any derived write", context do
      %{version: version} = activate!(context, definition([delay_node()]))

      assert {:error, %Error{code: :lineage_depth_exceeded}} =
               Engine.create(context.scope, %{
                 workflow_version_id: version.id,
                 execution_key: "deep-#{unique()}",
                 root_execution_id: Ecto.UUID.generate(),
                 lineage_depth: 4
               })

      assert executions(context.installation_id) == []
    end

    test "descendants beyond the catalog cap are refused", context do
      put_limits(%{lineage_descendants: 2})
      %{version: root_version} = activate!(context, definition([delay_node()]), name: "Root")
      %{version: child_b} = activate!(context, definition([stop_node()]), name: "Child B")
      %{version: child_c} = activate!(context, definition([stop_node()]), name: "Child C")
      %{version: child_d} = activate!(context, definition([stop_node()]), name: "Child D")

      {:ok, root} =
        Engine.create(context.scope, %{
          workflow_version_id: root_version.id,
          execution_key: "desc-root-#{unique()}"
        })

      assert {:ok, _} =
               Engine.create(context.scope, %{
                 workflow_version_id: child_b.id,
                 execution_key: "desc-b-#{unique()}",
                 parent_execution_id: root.id
               })

      assert {:ok, _} =
               Engine.create(context.scope, %{
                 workflow_version_id: child_c.id,
                 execution_key: "desc-c-#{unique()}",
                 parent_execution_id: root.id
               })

      assert {:error, %Error{code: :lineage_descendants_exceeded}} =
               Engine.create(context.scope, %{
                 workflow_version_id: child_d.id,
                 execution_key: "desc-d-#{unique()}",
                 parent_execution_id: root.id
               })
    end
  end

  describe "duplicate event interaction" do
    test "a second delivery of the same event creates nothing", context do
      activate!(context, definition([delay_node()]))
      payload = human_payload(context, rid: "RID-dup")
      transport = transport(raw_body: "same-bytes")

      assert :accepted = Service.enqueue_event(payload, transport)
      assert :accepted = Service.enqueue_event(payload, transport)

      assert [%Execution{}] = executions(context.installation_id)

      assert [%ReceivedEvent{processing_state: "processed"}] =
               Repo.all(
                 from event in ReceivedEvent,
                   where: event.installation_id == ^context.installation_id
               )
    end
  end

  describe "controllable webhook chaining" do
    test "a verified lineage header propagates parent depth; a forged header does not",
         context do
      %{version: parent_version} = activate!(context, definition([delay_node()]), name: "Parent")
      %{version: hook_version} = activate_webhook!(context.scope, context.installation_id)

      {:ok, parent} =
        Engine.create(context.scope, %{
          workflow_version_id: parent_version.id,
          execution_key: "hook-parent-#{unique()}"
        })

      token = WebhookEndpoint.generate_token()
      endpoint = webhook_endpoint(hook_version, %{token: token})

      assert {:ok, _} =
               WebhookService.accept(
                 endpoint.public_id,
                 webhook_request(token, %{"ok" => true}, %{
                   Lineage.header_name() => Lineage.token(parent)
                 })
               )

      chained =
        Enum.find(executions(context.installation_id), &(not is_nil(&1.root_execution_id)))

      assert chained.lineage_depth == 1
      assert chained.root_execution_id == parent.id
      refute Map.has_key?(chained.trigger_snapshot["headers"] || %{}, Lineage.header_name())

      forged_token = WebhookEndpoint.generate_token()
      forged_endpoint = webhook_endpoint(hook_version, %{token: forged_token})

      assert {:ok, _} =
               WebhookService.accept(
                 forged_endpoint.public_id,
                 webhook_request(
                   forged_token,
                   %{"root_execution_id" => parent.id, "lineage_depth" => 1},
                   %{Lineage.header_name() => "forged.#{parent.id}.nope"}
                 )
               )

      forged =
        Enum.find(
          executions(context.installation_id),
          &(&1.execution_key != chained.execution_key and
              String.starts_with?(&1.execution_key, "hook:"))
        )

      assert forged.lineage_depth == 0
      assert is_nil(forged.root_execution_id)
    end
  end

  defp activate!(context, definition, opts \\ []) do
    name = Keyword.get(opts, :name, "Loop #{unique()}")

    workflow =
      drafted_workflow(context.installation.id, %{
        name: name,
        slug: "loop-#{unique()}",
        draft_definition: Definition.encode(definition)
      })

    {:ok, result} = Workflows.activate_workflow(context.scope, workflow.id, 0)
    result
  end

  defp activate_webhook!(scope, installation_id) do
    workflow =
      drafted_workflow(installation_id, %{
        name: "Hook #{unique()}",
        slug: "hook-#{unique()}",
        draft_definition:
          Definition.encode(Definition.new(Trigger.new(:webhook, %{}), [delay_node()]))
      })

    {:ok, result} = Workflows.activate_workflow(scope, workflow.id, 0)
    result
  end

  defp include_bot_definition do
    Definition.new(
      Trigger.new(:pumble_event, %{
        event: :new_message,
        channel_ids: ["channel-1"],
        ignore_bot_messages: false
      }),
      [delay_node()]
    )
  end

  defp human_payload(context, opts \\ []) do
    event_payload(context, Keyword.put_new(opts, :actor_id, "user-1"))
  end

  defp bot_payload(context, opts \\ []) do
    event_payload(context, Keyword.put_new(opts, :actor_id, @bot_user_id))
  end

  defp event_payload(context, opts) do
    %Payload.Event{
      message_type: "PUMBLE_EVENT",
      event_type: "NEW_MESSAGE",
      workspace_id: context.workspace_id,
      body: %{
        "cId" => "channel-1",
        "aId" => Keyword.get(opts, :actor_id, "user-1"),
        "tx" => Keyword.get(opts, :text, "hello"),
        "rid" => Keyword.get(opts, :rid, "RID-#{unique()}"),
        "mId" => Keyword.get(opts, :m_id, "M-#{unique()}"),
        "tsm" => 1_767_225_600_000
      }
    }
  end

  defp transport(opts \\ []) do
    %{
      raw_body: Keyword.get(opts, :raw_body, "body-#{unique()}"),
      signature: Keyword.get(opts, :signature, "sig")
    }
  end

  defp webhook_request(token, body, headers) do
    %{
      raw_body: Jason.encode!(body),
      content_type: "application/json",
      authorization: "Bearer " <> Base.url_encode64(token, padding: false),
      headers: headers,
      body: body
    }
  end

  defp executions(installation_id) do
    Repo.all(from execution in Execution, where: execution.installation_id == ^installation_id)
  end

  defp put_limits(overrides) do
    current =
      case Application.get_env(:pumble_automation, :limits, %{}) do
        map when is_map(map) -> map
        _other -> %{}
      end

    Application.put_env(:pumble_automation, :limits, Map.merge(current, overrides))
  end

  defp attach_lineage do
    handler = "lineage-#{unique()}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        Lineage.telemetry_event(),
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:lineage, measurements, metadata})
        end,
        nil
      )

    handler
  end

  defp unique, do: System.unique_integer([:positive])
end
