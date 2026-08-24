defmodule PumbleAutomation.Executions.DryRunTest do
  @moduledoc """
  Stop nodes return a bounded reason, and a dry-run walks the compiled graph
  without credentials, network, jobs, or persistence.
  """

  use ExUnit.Case, async: true

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.DryRun
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.NodeRunner
  alias PumbleAutomation.Executions.Nodes.Stop
  alias PumbleAutomation.Pumble.Client.Transport
  alias PumbleAutomation.PumbleFake
  alias PumbleAutomation.Workflows.CompiledWorkflow
  alias PumbleAutomation.Workflows.Compiler
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Templates

  describe "stop node" do
    test "terminal success uses the configured reason" do
      stop = stop_node()
      compiled = compile!([stop])

      assert {:ok, result} = DryRun.run(compiled, %{})
      assert result.status == "completed"
      assert [step] = result.trace
      assert step["node_id"] == stop.id
      assert step["type"] == "stop"
      assert step["kind"] == "success"
      assert step["edge"] == "next"
      assert step["output"]["reason"] == "done"
    end

    test "an empty reason becomes done" do
      assert {:ok, outcome} = Stop.run(runner_input(:stop, %{}))
      assert outcome.kind == :success
      assert outcome.output["reason"] == "done"
    end

    test "a templated reason renders against the sample" do
      stop = Node.new(:stop, %{reason: "halt {{ trigger.data.text }}"})
      compiled = compile!([stop])

      assert {:ok, result} =
               DryRun.run(compiled, %{sample: %{"data" => %{"text" => "shipped"}}})

      assert hd(result.trace)["output"]["reason"] == "halt shipped"
      assert "trigger.data.text" in hd(result.trace)["references"]
    end
  end

  describe "network spy" do
    test "a representative workflow is previewed without Pumble or client transport" do
      true_stop = stop_node()
      false_stop = stop_node()
      send = message_node()

      condition =
        condition_node(
          if_true: [send, true_stop],
          if_false: [false_stop]
        )

      compiled = compile!([condition])
      handler = "dry-run-#{System.unique_integer([:positive])}"
      test_pid = self()

      client_events = [
        Transport.telemetry_event() ++ [:start],
        Transport.telemetry_event() ++ [:stop]
      ]

      :telemetry.attach_many(
        handler,
        client_events,
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

      assert {:ok, result} =
               DryRun.run(compiled, %{sample: %{"data" => %{"text" => "please deploy"}}})

      assert result.status == "completed"
      assert Enum.map(result.trace, & &1["node_id"]) == [condition.id, send.id, true_stop.id]
      assert Enum.at(result.trace, 1)["would_send"]["operation"] == "post_message"
      assert Enum.at(result.trace, 1)["would_send"]["channel_id"] == "channel-1"
      assert Enum.at(result.trace, 1)["would_send"]["dry_run"] == true
      refute Map.has_key?(Enum.at(result.trace, 1)["would_send"], "text")
      refute_received {:pumble_api_request, _}
      refute_received {:client, _, _}
    end
  end

  describe "branch and stop trace" do
    test "the false branch is the compiled false edge through to stop" do
      true_stop = stop_node()
      false_stop = Node.new(:stop, %{reason: "skipped"})
      condition = condition_node(if_true: [true_stop], if_false: [false_stop])
      compiled = compile!([condition])

      assert {:ok, result} =
               DryRun.run(compiled, %{sample: %{"data" => %{"text" => "hello"}}})

      assert result.status == "completed"
      assert Enum.map(result.trace, & &1["node_id"]) == [condition.id, false_stop.id]
      assert hd(result.trace)["branch"] == "false"
      assert hd(result.trace)["edge"] == "false"
      assert List.last(result.trace)["output"]["reason"] == "skipped"
      assert compiled.nodes[condition.id].edges["false"] == false_stop.id
    end
  end

  describe "secret placeholder" do
    test "an HTTP body secret stays a placeholder and is never a value" do
      planted = "s3cret-value-must-not-leak"

      node =
        Node.new(:http_action, %{
          method: :post,
          url: "https://example.test/hook",
          headers: %{"accept" => "text/plain"},
          body: "token={{ secret.API_TOKEN }}"
        })

      compiled = compile!([node])

      assert {:ok, result} =
               DryRun.run(compiled, %{sample: %{"access_token" => planted, "data" => %{}}})

      assert result.status == "completed"
      [step] = result.trace
      assert step["would_send"]["adapter"] == "HTTP"
      assert step["would_send"]["method"] == "post"
      assert step["would_send"]["url"] == "https://example.test/hook"

      assert step["would_send"]["body_bytes"] ==
               byte_size("token=" <> Templates.secret_placeholder("API_TOKEN"))

      refute Map.has_key?(step["would_send"], "body")
      assert "secret.API_TOKEN" in step["references"]
      refute inspect(result) =~ planted
      refute inspect(result) =~ "s3cret"
    end
  end

  describe "delay and approval preview" do
    test "waits are summarized and the simulated approval edge continues" do
      halt = stop_node()
      rejected = Node.new(:stop, %{reason: "rejected"})
      delay = delay_node()

      approval =
        approval_node(
          approved: [halt],
          rejected: [rejected]
        )

      compiled = compile!([delay, approval])

      assert {:ok, result} = DryRun.run(compiled, %{approval_edge: "approved"})
      assert result.status == "completed"

      assert Enum.map(result.trace, & &1["type"]) == ["delay", "approval", "stop"]
      assert Enum.at(result.trace, 0)["kind"] == "wait_delay"
      assert Enum.at(result.trace, 0)["would_send"]["wait_seconds"] == 60
      assert Enum.at(result.trace, 1)["kind"] == "wait_approval"
      assert Enum.at(result.trace, 1)["branch"] == "approved"
      assert Enum.at(result.trace, 1)["would_send"]["timeout_seconds"] == 3600
      assert Enum.at(result.trace, 1)["would_send"]["simulated_edge"] == "approved"
      assert List.last(result.trace)["node_id"] == halt.id
    end
  end

  describe "large sample limits" do
    test "a sample larger than live trigger_snapshot is refused" do
      compiled = compile!([stop_node()])
      blob = String.duplicate("a", Execution.max_context_bytes())

      assert {:error, %Error{class: :validation, code: :invalid_sample}} =
               DryRun.run(compiled, %{sample: %{"blob" => blob}})
    end

    test "a missing Pumble target is a preview issue, not a call" do
      send =
        Node.new(:pumble_action, %{
          action: :send_message,
          channel_id: "{{ trigger.data.channel_id }}",
          text: "hello"
        })

      compiled = compile!([send])
      PumbleFake.stub_api_routes(self(), [{"POST", "/v1/channels/x/messages", 200, %{}}])

      assert {:ok, result} = DryRun.run(compiled, %{sample: %{"data" => %{}}})
      assert result.status == "preview_issue"
      assert hd(result.trace)["kind"] == "permanent_error"
      assert hd(result.trace)["issues"] != []
      refute_received {:pumble_api_request, _}
    end
  end

  describe "compiled and live parity" do
    test "the preview path is the compiled true edge, matching NodeRunner" do
      true_stop = stop_node()
      false_stop = stop_node()
      condition = condition_node(if_true: [true_stop], if_false: [false_stop])
      compiled = compile!([condition])
      sample = %{"data" => %{"text" => "please deploy"}}

      assert {:ok, result} = DryRun.run(compiled, %{sample: sample})
      assert Enum.map(result.trace, & &1["node_id"]) == [condition.id, true_stop.id]
      assert compiled.nodes[condition.id].edges["true"] == true_stop.id
      assert compiled.compiler_version == CompiledWorkflow.compiler_version()
      assert result.compiler_version == CompiledWorkflow.compiler_version()

      assert {:ok, live} =
               NodeRunner.run(%{
                 compiled_node: compiled.nodes[condition.id],
                 context: %{},
                 trigger_snapshot: sample,
                 installation_id: Ecto.UUID.generate(),
                 run_mode: "live",
                 effect_key: "parity/condition",
                 attempt: %{id: Ecto.UUID.generate(), number: 1},
                 resolver: PumbleAutomation.Connections.Resolver,
                 adapters: %{}
               })

      assert live.kind == :success
      assert live.edge == hd(result.trace)["edge"]
      assert live.output["matched"] == true
    end

    test "an encoded document from another compiler is refused" do
      document =
        [stop_node()]
        |> compile!()
        |> CompiledWorkflow.encode()
        |> Map.put("compiler_version", "0")

      assert {:error, %Error{code: :unsupported_compiler_version}} = DryRun.run(document, %{})
    end
  end

  defp compile!(nodes) do
    assert {:ok, compiled} = Compiler.compile(definition(nodes))
    compiled
  end

  defp runner_input(type, config) do
    %{
      compiled_node: %{
        type: type,
        config: config,
        edges: %{"next" => CompiledWorkflow.end_target()},
        requires: %{
          "operations" => [],
          "scopes" => [],
          "connection_ids" => [],
          "secret_names" => []
        }
      },
      context: %{},
      trigger_snapshot: %{},
      installation_id: Ecto.UUID.generate(),
      run_mode: "dry_run",
      effect_key: "dry-run/stop",
      attempt: %{id: Ecto.UUID.generate(), number: 1},
      resolver: PumbleAutomation.Connections.Resolver,
      adapters: %{}
    }
  end
end
