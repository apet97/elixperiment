defmodule PumbleAutomation.Executions.Nodes.PumbleReactionNodesTest do
  @moduledoc """
  Add and remove reaction nodes render a bounded target and code, call only
  the Pumble client adapters, and map every failure window onto the
  documented outcome kinds. Already-present and already-absent statuses
  follow the provider (PR-09 is still open).
  """

  use PumbleAutomation.DataCase, async: true

  import PumbleAutomation.InstallationsFixtures
  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Executions.NodeRunner
  alias PumbleAutomation.Executions.Nodes.Pumble
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Pumble.Client.Transport
  alias PumbleAutomation.PumbleFake
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows.CompiledWorkflow
  alias PumbleAutomation.Workflows.Compiler
  alias PumbleAutomation.Workflows.Node

  setup do
    %{installation: installation, member: member} =
      install(tokens: %{bot_user_id: "bot1"})

    %{
      installation: installation,
      installation_id: installation.id,
      scope: Scope.new(member)
    }
  end

  describe "add reaction" do
    test "a live add returns the target and code and uses the bot credential", context do
      stub_add(200)

      assert {:ok, outcome} = run_action(context, add_config(), %{})
      assert outcome.kind == :success
      assert outcome.edge == Outcome.linear()
      assert outcome.output["message_id"] == "message1"
      assert outcome.output["reaction"] == ":tada:"
      assert outcome.output["as"] == "bot"
      assert outcome.output["effect_key"] == "inst/exec/node"
      assert outcome.output["operation"] == "add_reaction"
      assert outcome.remote_reference == "message1"
      refute Map.has_key?(outcome.output, "text")
      refute inspect(outcome) =~ "bot-access-token"

      assert_receive {:pumble_api_request, request}
      assert request.method == "POST"
      assert request.path == "/v1/messages/message1/reactions"
      assert Jason.decode!(request.body) == %{"code" => ":tada:"}
      assert Map.new(request.headers)["token"] == "bot-access-token"
    end

    test "an optional skin tone is sent on add and recorded in output", context do
      stub_add(200)

      assert {:ok, outcome} = run_action(context, add_config(%{"skin_tone" => 3}), %{})
      assert outcome.kind == :success
      assert outcome.output["skin_tone"] == 3
      assert_receive {:pumble_api_request, request}
      assert Jason.decode!(request.body) == %{"code" => ":tada:", "skinTone" => 3}
    end

    test "NodeRunner uses the add-reaction node without a stub adapter", context do
      stub_add(204)

      assert {:ok, outcome} = NodeRunner.run(runner_input(context, add_config(), %{}))
      assert outcome.output["message_id"] == "message1"
      assert outcome.output["reaction"] == ":tada:"
    end

    test "a compiler-produced template is rendered against the trigger", context do
      stub_add(200, "message9")

      node =
        Node.new(:pumble_action, %{
          action: :add_reaction,
          message_id: "{{ trigger.resource_id }}",
          reaction: ":{{ trigger.data.reaction }}:"
        })

      assert {:ok, compiled} = Compiler.compile(definition([node]))
      config = compiled.nodes[node.id].config

      assert {:ok, outcome} =
               run_action(context, config, %{"reaction" => "tada"}, %{
                 "resource_id" => "message9"
               })

      assert outcome.kind == :success
      assert outcome.output["message_id"] == "message9"
      assert_receive {:pumble_api_request, request}
      assert request.path == "/v1/messages/message9/reactions"
      assert Jason.decode!(request.body) == %{"code" => ":tada:"}
    end

    test "a missing compiled message id uses the triggering resource", context do
      stub_add(200, "from-trigger")
      config = add_config() |> Map.delete("message_id")

      assert {:ok, outcome} =
               run_action(context, config, %{}, %{"resource_id" => "from-trigger"})

      assert outcome.output["message_id"] == "from-trigger"
      assert_receive {:pumble_api_request, request}
      assert request.path == "/v1/messages/from-trigger/reactions"
    end

    test "a step output message id is the target", context do
      stub_add(200, "from-step")

      send = message_node()

      reaction =
        Node.new(:pumble_action, %{
          action: :add_reaction,
          message_id: "{{ steps.#{send.id}.output.message_id }}",
          reaction: ":tada:"
        })

      assert {:ok, compiled} = Compiler.compile(definition([send, reaction]))
      config = compiled.nodes[reaction.id].config

      input =
        context
        |> runner_input(config, %{})
        |> Map.put(:context, %{
          "steps" => %{send.id => %{"output" => %{"message_id" => "from-step"}}}
        })

      assert {:ok, outcome} = NodeRunner.run(input)
      assert outcome.output["message_id"] == "from-step"
      assert_receive {:pumble_api_request, request}
      assert request.path == "/v1/messages/from-step/reactions"
    end
  end

  describe "remove reaction" do
    test "a live remove sends a JSON body on DELETE", context do
      stub_remove(200)

      assert {:ok, outcome} = run_action(context, remove_config(), %{})
      assert outcome.kind == :success
      assert outcome.output["message_id"] == "message1"
      assert outcome.output["reaction"] == ":tada:"
      assert outcome.output["operation"] == "remove_reaction"
      refute Map.has_key?(outcome.output, "skin_tone")

      assert_receive {:pumble_api_request, request}
      assert request.method == "DELETE"
      assert request.path == "/v1/messages/message1/reactions"
      assert Jason.decode!(request.body) == %{"code" => ":tada:"}
      assert request.query == ""
    end
  end

  describe "invalid reaction" do
    test "an invalid code is permanent and never reaches the network", context do
      for code <- ["tada", "::", ":#{String.duplicate("x", 200)}:"] do
        assert {:ok, outcome} = run_action(context, add_config(%{"reaction" => code}), %{})
        assert outcome.kind == :permanent_error
        assert outcome.error_class == "validation"
        assert outcome.output["field"] == "reaction"
      end

      refute_received {:pumble_api_request, _}
    end

    test "a non-integer skin tone is permanent and never reaches the network", context do
      assert {:ok, outcome} = run_action(context, add_config(%{"skin_tone" => "warm"}), %{})
      assert outcome.kind == :permanent_error
      assert outcome.error_class == "validation"
      assert outcome.output["field"] == "skin_tone"
      refute_received {:pumble_api_request, _}
    end

    test "a missing message source is a permanent validation failure", context do
      config = add_config() |> Map.delete("message_id")
      assert {:ok, outcome} = run_action(context, config, %{})
      assert outcome.kind == :permanent_error
      assert outcome.error_class == "validation"
      assert outcome.output["field"] == "message_id"
      refute_received {:pumble_api_request, _}
    end

    test "an invalid message id is refused before the network", context do
      config = add_config(%{"message_id" => "msg/id"})
      assert {:ok, outcome} = run_action(context, config, %{})
      assert outcome.kind == :permanent_error
      assert outcome.error_class == "validation"
      assert outcome.output["field"] == "message_id"
      refute_received {:pumble_api_request, _}
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
      assert {:ok, outcome} = run_action(context, add_config(), %{})
      assert outcome.kind == :uncertain
      assert outcome.error_class == "ambiguous_transport"
      assert outcome.output["effect_key"] == "inst/exec/node"
    end
  end

  describe "already-present and already-absent (PR-09 unproven)" do
    test "a second add that the provider accepts stays a success", context do
      stub_add(200)
      assert {:ok, first} = run_action(context, add_config(), %{})
      assert first.kind == :success

      stub_add(200)
      assert {:ok, second} = run_action(context, add_config(), %{})
      assert second.kind == :success
      assert second.output["reaction"] == ":tada:"
    end

    test "a second add that the provider conflicts is a conflict, not success", context do
      stub_add(409)
      assert {:ok, outcome} = run_action(context, add_config(), %{})
      assert outcome.kind == :permanent_error
      assert outcome.error_class == "conflict"
    end

    test "removing an absent reaction keeps the provider status", context do
      stub_remove(200)
      assert {:ok, accepted} = run_action(context, remove_config(), %{})
      assert accepted.kind == :success

      stub_remove(404)
      assert {:ok, missing} = run_action(context, remove_config(), %{})
      assert missing.kind == :permanent_error
      assert missing.error_class == "not_found"
    end
  end

  describe "cross-context target" do
    test "a trigger workspace that is not this execution's is refused", context do
      input =
        context
        |> runner_input(add_config(), %{})
        |> Map.put(:context, %{"workspace" => %{"id" => "workspace-current"}})
        |> Map.put(:trigger_snapshot, %{
          "resource_id" => "message1",
          "workspace_id" => "workspace-other"
        })

      assert {:ok, outcome} = NodeRunner.run(input)
      assert outcome.kind == :permanent_error
      assert outcome.error_class == "validation"
      assert outcome.output["field"] == "message_id"
      refute_received {:pumble_api_request, _}
    end
  end

  describe "dry-run" do
    test "returns a request summary without credentials or network", context do
      input =
        context
        |> runner_input(add_config(), %{})
        |> Map.put(:run_mode, "dry_run")
        |> Map.put(:installation_id, Ecto.UUID.generate())

      assert {:ok, outcome} = NodeRunner.run(input)
      assert outcome.kind == :success
      assert outcome.output["dry_run"] == true
      assert outcome.output["operation"] == "add_reaction"
      assert outcome.output["message_id"] == "message1"
      assert outcome.output["reaction"] == ":tada:"
      assert outcome.output["as"] == "bot"
      refute Map.has_key?(outcome.output, "text")
      refute Map.has_key?(outcome.output, "text_bytes")
      refute Map.has_key?(outcome.output, "blocks_count")
      refute_received {:pumble_api_request, _}
    end

    test "still validates reaction code and does not request a user token", context do
      input =
        context
        |> runner_input(add_config(%{"reaction" => "tada"}), %{})
        |> Map.put(:run_mode, "dry_run")

      assert {:ok, outcome} = NodeRunner.run(input)
      assert outcome.kind == :permanent_error

      as_user = add_config(%{"as" => "user"})
      assert {:ok, refused} = run_action(context, as_user, %{})
      assert refused.kind == :permanent_error
      assert refused.error_class == "validation"
      refute_received {:pumble_api_request, _}
    end
  end

  describe "telemetry and effect key" do
    test "the stable effect key is emitted and passed as the client correlation", context do
      effect_key = "inst/#{Ecto.UUID.generate()}/react"
      handler = "pumble-reaction-#{System.unique_integer([:positive])}"
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

      stub_add(200)
      input = %{runner_input(context, add_config(), %{}) | effect_key: effect_key}
      assert {:ok, outcome} = NodeRunner.run(input)
      assert outcome.output["effect_key"] == effect_key

      assert_receive {:telemetry, ^action_event, %{effect_key: ^effect_key} = metadata}
      assert metadata.operation == :add_reaction
      refute metadata.dry_run?

      assert_receive {:telemetry, ^client_event, %{correlation_id: ^effect_key} = client_metadata}
      refute Map.has_key?(client_metadata, :token)
    end
  end

  defp assert_class(context, status, kind, error_class) do
    stub_add(status)
    assert {:ok, outcome} = run_action(context, add_config(), %{})
    assert outcome.kind == kind
    assert outcome.error_class == error_class
  end

  defp stub_add(status, message_id \\ "message1") do
    PumbleFake.stub_api_routes(self(), [
      {"POST", "/v1/messages/#{message_id}/reactions", status, {:raw, ""}}
    ])
  end

  defp stub_remove(status) do
    PumbleFake.stub_api_routes(self(), [
      {"DELETE", "/v1/messages/message1/reactions", status, {:raw, ""}}
    ])
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
          "operations" => [config["action"]],
          "scopes" => ["reaction:write"],
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

  defp add_config(overrides \\ %{}) do
    Map.merge(
      %{"action" => "add_reaction", "message_id" => "message1", "reaction" => ":tada:"},
      overrides
    )
  end

  defp remove_config do
    %{"action" => "remove_reaction", "message_id" => "message1", "reaction" => ":tada:"}
  end
end
