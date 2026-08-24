defmodule PumbleAutomation.Executions.Nodes.PumbleMessageNodesTest do
  @moduledoc """
  Send, reply, and DM nodes render bounded payloads, call the Pumble client,
  and map every failure window onto the documented outcome kinds.
  """

  use PumbleAutomation.DataCase, async: true
  use Oban.Testing, repo: PumbleAutomation.Repo

  import PumbleAutomation.InstallationsFixtures
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.NodeRunner
  alias PumbleAutomation.Executions.Nodes.Pumble
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Executions.StepAttempt
  alias PumbleAutomation.Executions.Workers.AdvanceExecutionWorker
  alias PumbleAutomation.Pumble.Blocks
  alias PumbleAutomation.Pumble.Client.Transport
  alias PumbleAutomation.PumbleFake
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.CompiledWorkflow
  alias PumbleAutomation.Workflows.Compiler
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Node

  @message %{"id" => "message1", "channelId" => "channel-1", "text" => "hello"}
  @direct_channel %{"channel" => %{"id" => "direct1"}}
  @direct_message %{"id" => "dm1", "channelId" => "direct1"}

  setup do
    %{installation: installation, member: member} =
      install(tokens: %{bot_user_id: "bot1"})

    %{
      installation: installation,
      installation_id: installation.id,
      scope: Scope.new(member)
    }
  end

  describe "send message" do
    test "a live send returns provider ids and uses the bot credential", context do
      PumbleFake.stub_api_routes(self(), [
        {"POST", "/v1/channels/channel-1/messages", 200, @message}
      ])

      assert {:ok, outcome} = run_action(context, send_config(), %{"text" => "hello"})
      assert outcome.kind == :success
      assert outcome.edge == Outcome.linear()
      assert outcome.output["message_id"] == "message1"
      assert outcome.output["channel_id"] == "channel-1"
      assert outcome.output["as"] == "bot"
      assert outcome.output["effect_key"] == "inst/exec/node"
      assert outcome.remote_reference == "message1"
      refute Map.has_key?(outcome.output, "text")
      refute inspect(outcome) =~ "bot-access-token"

      assert_receive {:pumble_api_request, request}
      assert request.method == "POST"
      assert Jason.decode!(request.body) == %{"text" => "hello"}
      assert Map.new(request.headers)["token"] == "bot-access-token"
    end

    test "NodeRunner uses the send-message node without a stub adapter", context do
      PumbleFake.stub_api_routes(self(), [
        {"POST", "/v1/channels/channel-1/messages", 200, @message}
      ])

      assert {:ok, outcome} =
               NodeRunner.run(runner_input(context, send_config(), %{}))

      assert outcome.output["message_id"] == "message1"
    end

    test "a compiler-produced template is rendered against the trigger", context do
      PumbleFake.stub_api_routes(self(), [
        {"POST", "/v1/channels/channel-9/messages", 200, @message}
      ])

      node =
        Node.new(:pumble_action, %{
          action: :send_message,
          channel_id: "{{ trigger.channel_id }}",
          text: "hi {{ trigger.data.text }}"
        })

      assert {:ok, compiled} = Compiler.compile(definition([node]))
      config = compiled.nodes[node.id].config

      assert {:ok, outcome} =
               run_action(context, config, %{"text" => "there"}, %{"channel_id" => "channel-9"})

      assert outcome.kind == :success
      assert_receive {:pumble_api_request, request}
      assert Jason.decode!(request.body) == %{"text" => "hi there"}
    end

    test "supported rich_text blocks are sent and auth or endpoint fields are refused", context do
      {:ok, body} = Blocks.workflow_message("hello", [Blocks.rich_text("hello")])
      assert body["blocks"]

      assert {:error, %{class: :validation}} =
               Blocks.workflow_message("hello", [
                 %{"type" => "rich_text", "url" => "https://example.test/hook"}
               ])

      assert {:error, %{class: :validation}} =
               Blocks.workflow_message("hello", [
                 %{"type" => "actions", "elements" => []}
               ])

      PumbleFake.stub_api_routes(self(), [
        {"POST", "/v1/channels/channel-1/messages", 200, @message}
      ])

      config = Map.put(send_config(), "blocks", [Blocks.rich_text("hello")])
      assert {:ok, outcome} = run_action(context, config, %{})
      assert outcome.kind == :success
      assert_receive {:pumble_api_request, request}
      assert Jason.decode!(request.body)["blocks"]
    end
  end

  describe "status and timeout windows" do
    test "401 and 403 are permanent; 429 retries; 5xx and timeout pause", context do
      assert_class(context, 401, :permanent_error, "authentication")
      assert_class(context, 403, :permanent_error, "missing_scope")
      assert_class(context, 404, :permanent_error, "not_found")
      assert_class(context, 429, :retryable_error, "rate_limited")
      assert_class(context, 500, :uncertain, "side_effect_uncertain")

      PumbleFake.stub_api(fn conn -> Req.Test.transport_error(conn, :timeout) end)
      assert {:ok, outcome} = run_action(context, send_config(), %{})
      assert outcome.kind == :uncertain
      assert outcome.error_class == "ambiguous_transport"
      assert outcome.output["effect_key"] == "inst/exec/node"
    end

    test "an invalid target is refused before the network", context do
      config = send_config(%{"channel_id" => "chan/nel"})
      assert {:ok, outcome} = run_action(context, config, %{})
      assert outcome.kind == :permanent_error
      assert outcome.error_class == "validation"
      assert outcome.output["field"] == "channel_id"
      refute_received {:pumble_api_request, _}
    end
  end

  describe "reply target validation" do
    test "a configured message id is the thread root", context do
      PumbleFake.stub_api_routes(self(), [
        {"POST", "/v1/channels/channel-1/messages/root-1", 200, @message}
      ])

      assert {:ok, outcome} = run_action(context, reply_config(), %{})
      assert outcome.output["thread_root_id"] == "root-1"
      assert_receive {:pumble_api_request, request}
      assert request.path == "/v1/channels/channel-1/messages/root-1"
    end

    test "a missing compiled message id uses the triggering thread", context do
      PumbleFake.stub_api_routes(self(), [
        {"POST", "/v1/channels/channel-1/messages/thread-9", 200, @message}
      ])

      config = reply_config() |> Map.delete("message_id")

      assert {:ok, outcome} =
               run_action(context, config, %{}, %{
                 "channel_id" => "channel-1",
                 "thread_root_id" => "thread-9",
                 "resource_id" => "msg-1"
               })

      assert outcome.output["thread_root_id"] == "thread-9"
    end

    test "a reply without a message source is a permanent validation failure", context do
      config = reply_config() |> Map.delete("message_id")
      assert {:ok, outcome} = run_action(context, config, %{})
      assert outcome.kind == :permanent_error
      assert outcome.error_class == "validation"
      assert outcome.output["field"] == "message_id"
      refute_received {:pumble_api_request, _}
    end
  end

  describe "direct message" do
    test "an existing direct channel is used without creating one", context do
      PumbleFake.stub_api_routes(self(), [
        {"GET", "/v1/channels/direct", 200, @direct_channel},
        {"POST", "/v1/channels/direct1/messages", 200, @direct_message}
      ])

      assert {:ok, outcome} = run_action(context, dm_config(), %{})
      assert outcome.output["message_id"] == "dm1"
      assert outcome.output["user_id"] == "user1"
      assert outcome.output["channel_id"] == "direct1"

      assert_receive {:pumble_api_request, lookup}
      assert_receive {:pumble_api_request, post}
      assert lookup.path == "/v1/channels/direct"
      assert URI.decode_query(lookup.query) == %{"participantIds" => "bot1,user1"}
      assert post.path == "/v1/channels/direct1/messages"
      refute_received {:pumble_api_request, %{method: "POST", path: "/v1/channels/direct"}}
    end

    test "a missing direct channel is created, then used", context do
      PumbleFake.stub_api_routes(self(), [
        {"GET", "/v1/channels/direct", 404, %{"message" => "not found"}},
        {"POST", "/v1/channels/direct", 200, @direct_channel},
        {"POST", "/v1/channels/direct1/messages", 200, @direct_message}
      ])

      assert {:ok, outcome} = run_action(context, dm_config(), %{})
      assert outcome.kind == :success
      assert_receive {:pumble_api_request, _lookup}
      assert_receive {:pumble_api_request, create}
      assert_receive {:pumble_api_request, post}
      assert create.path == "/v1/channels/direct"
      assert Jason.decode!(create.body) == %{"participantIds" => ["user1"]}
      assert post.path == "/v1/channels/direct1/messages"
    end
  end

  describe "dry-run" do
    test "returns a request summary without credentials or network", context do
      input =
        context
        |> runner_input(send_config(), %{})
        |> Map.put(:run_mode, "dry_run")
        |> Map.put(:installation_id, Ecto.UUID.generate())

      assert {:ok, outcome} = NodeRunner.run(input)
      assert outcome.kind == :success
      assert outcome.output["dry_run"] == true
      assert outcome.output["operation"] == "post_message"
      assert outcome.output["channel_id"] == "channel-1"
      assert outcome.output["text_bytes"] == byte_size("hello")
      assert outcome.output["blocks_count"] == 0
      assert outcome.output["as"] == "bot"
      refute Map.has_key?(outcome.output, "text")
      refute_received {:pumble_api_request, _}
    end

    test "an unsupported stored action fails closed in live and dry-run modes", context do
      for run_mode <- ["live", "dry_run"] do
        input =
          context
          |> runner_input(%{"action" => "future_action"}, %{})
          |> Map.put(:run_mode, run_mode)

        assert {:ok, outcome} = NodeRunner.run(input)
        assert outcome.kind == :permanent_error
        assert outcome.error_class == "internal_invariant"
        refute Map.has_key?(outcome.output, "dry_run")
      end

      refute_received {:pumble_api_request, _}
    end

    test "still validates targets and does not request a user token", context do
      input =
        context
        |> runner_input(send_config(%{"channel_id" => "bad/id"}), %{})
        |> Map.put(:run_mode, "dry_run")

      assert {:ok, outcome} = NodeRunner.run(input)
      assert outcome.kind == :permanent_error

      as_user = send_config(%{"as" => "user"})
      assert {:ok, refused} = run_action(context, as_user, %{})
      assert refused.kind == :permanent_error
      assert refused.error_class == "validation"
      refute_received {:pumble_api_request, _}
    end
  end

  describe "telemetry and effect key" do
    test "the stable effect key is emitted and passed as the client correlation", context do
      effect_key = "inst/#{Ecto.UUID.generate()}/send"
      handler = "pumble-action-#{System.unique_integer([:positive])}"
      test_pid = self()
      action_event = Pumble.telemetry_event()
      client_event = Transport.telemetry_event() ++ [:stop]

      :telemetry.attach_many(
        handler,
        [action_event, client_event],
        fn event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      PumbleFake.stub_api_routes(self(), [
        {"POST", "/v1/channels/channel-1/messages", 200, @message}
      ])

      input = %{runner_input(context, send_config(), %{}) | effect_key: effect_key}
      assert {:ok, outcome} = NodeRunner.run(input)
      assert outcome.output["effect_key"] == effect_key

      assert_receive {:telemetry, ^action_event, %{effect_key: ^effect_key} = metadata}
      assert metadata.operation == :post_message
      refute metadata.dry_run?

      assert_receive {:telemetry, ^client_event, %{correlation_id: ^effect_key} = client_metadata}
      refute Map.has_key?(client_metadata, :token)
    end
  end

  describe "duplicate worker and finalization" do
    test "a second worker and finalize of a completed send are no-ops", context do
      PumbleFake.stub_api_routes(self(), [
        {"POST", "/v1/channels/channel-1/messages", 200, @message}
      ])

      %{execution: execution, snapshot: snapshot} = claimed!(context, [message_node()])
      args = job_args(execution)

      assert {:ok, outcome} = NodeRunner.run(NodeRunner.input(snapshot))
      assert {:ok, first} = Engine.finalize(snapshot, outcome)
      assert first.status == "completed"
      assert first.context["steps"][snapshot.node_id]["output"]["message_id"] == "message1"
      assert {:ok, :noop} = Engine.finalize(snapshot, outcome)

      assert :ok = perform_job(AdvanceExecutionWorker, args)
      assert Repo.get!(Execution, execution.id).status == "completed"
      assert Repo.aggregate(StepAttempt, :count) == 1
    end
  end

  defp assert_class(context, status, kind, error_class) do
    PumbleFake.stub_api_routes(self(), [
      {"POST", "/v1/channels/channel-1/messages", status, %{"message" => "no"}}
    ])

    assert {:ok, outcome} = run_action(context, send_config(), %{})
    assert outcome.kind == kind
    assert outcome.error_class == error_class
  end

  defp run_action(context, config, data, trigger \\ %{}) do
    NodeRunner.run(runner_input(context, config, data, trigger))
  end

  defp runner_input(context, config, data, trigger \\ %{}) do
    %{
      compiled_node: %{
        type: :pumble_action,
        config: config,
        edges: %{"next" => CompiledWorkflow.end_target()},
        requires: %{
          "operations" => ["post_message"],
          "scopes" => ["messages:write"],
          "connection_ids" => [],
          "secret_names" => []
        }
      },
      context: %{},
      trigger_snapshot: Map.merge(%{"data" => data}, trigger),
      installation_id: context.installation_id,
      run_mode: "live",
      effect_key: "inst/exec/node",
      attempt: %{id: Ecto.UUID.generate(), number: 1},
      resolver: PumbleAutomation.Connections.Resolver,
      adapters: %{}
    }
  end

  defp send_config(overrides \\ %{}) do
    Map.merge(
      %{"action" => "send_message", "channel_id" => "channel-1", "text" => "hello"},
      overrides
    )
  end

  defp reply_config do
    %{
      "action" => "reply_message",
      "channel_id" => "channel-1",
      "message_id" => "root-1",
      "text" => "in thread"
    }
  end

  defp dm_config do
    %{"action" => "direct_message", "user_id" => "user1", "text" => "hello"}
  end

  defp claimed!(context, nodes) do
    %{version: version} = activate!(context.scope, context.installation_id, definition(nodes))

    {:ok, execution} =
      Engine.create(context.scope, %{
        workflow_version_id: version.id,
        execution_key: "pumble-#{System.unique_integer([:positive])}"
      })

    execution = Repo.get!(Execution, execution.id)
    {:ok, snapshot} = Engine.claim(job_args(execution))
    %{execution: execution, snapshot: snapshot, version: version}
  end

  defp activate!(scope, installation_id, definition) do
    workflow =
      drafted_workflow(installation_id, %{draft_definition: Definition.encode(definition)})

    {:ok, result} = Workflows.activate_workflow(scope, workflow.id, 0)
    %{version: result.version, workflow: result.workflow}
  end

  defp job_args(%Execution{} = execution) do
    %{
      "installation_id" => execution.installation_id,
      "execution_id" => execution.id,
      "expected_node_id" => execution.current_node_id,
      "generation" => execution.lock_version
    }
  end
end
