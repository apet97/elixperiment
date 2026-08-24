defmodule PumbleAutomation.Workflows.DependenciesTest do
  @moduledoc """
  What a workflow needs, and how strongly that need is known.

  The tests that matter most here are the ones about restraint: a permission
  nobody has proven is needed must never stop an author from activating a
  workflow, and an installation that has never recorded what it was granted
  must not be treated as an installation that was granted nothing.
  """

  use ExUnit.Case, async: true

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Workflows.Compiler
  alias PumbleAutomation.Workflows.Dependencies
  alias PumbleAutomation.Workflows.Node

  describe "the scopes a workflow needs" do
    test "sending a message needs permission to write messages" do
      dependencies = calculate([message_node()])

      assert dependencies.required_scopes == ["messages:write"]
    end

    test "reacting needs permission to react" do
      dependencies = calculate([reaction_node(:add_reaction)])

      assert dependencies.required_scopes == ["reaction:write"]
    end

    test "a direct message needs the permissions of every call it makes" do
      # `Pumble.Client.send_direct_message/3` resolves the direct channel
      # before it posts, so a workflow that sends one also creates a channel.
      dependencies = calculate([direct_message_node()])

      assert dependencies.required_scopes == ["channels:write", "messages:write"]

      assert operations(dependencies) ==
               [:create_direct_channel, :get_direct_channel, :send_direct_message]
    end

    test "a step that never reaches Pumble needs nothing from Pumble" do
      assert calculate([delay_node(), stop_node()]).required_scopes == []
    end

    test "an approval needs permission to ask" do
      assert calculate([approval_node(approved: [delay_node()])]).required_scopes ==
               ["messages:write"]
    end

    test "the same permission needed twice is asked for once" do
      assert calculate([message_node(), message_node()]).required_scopes == ["messages:write"]
    end

    test "permissions are answered in one order however the steps are ordered" do
      forward = calculate([message_node(), reaction_node(:add_reaction)])
      backward = calculate([reaction_node(:add_reaction), message_node()])

      assert forward.required_scopes == backward.required_scopes
      assert forward.required_scopes == Enum.sort(forward.required_scopes)
    end

    test "a nested step counts as much as a top level one" do
      dependencies = calculate([condition_node(if_true: [reaction_node(:remove_reaction)])])

      assert dependencies.required_scopes == ["reaction:write"]
    end
  end

  describe "how well each need is known" do
    test "an inferred permission names the probe that would confirm it" do
      [entry] = calculate([message_node()]).scope_evidence

      assert entry.operation == :post_message
      assert entry.evidence == :inferred
      assert entry.scope == "messages:write"
      assert is_binary(entry.probe)
    end

    test "an operation nobody has proven a permission for claims none" do
      entry =
        [direct_message_node()]
        |> calculate()
        |> Map.fetch!(:scope_evidence)
        |> Enum.find(&(&1.operation == :get_direct_channel))

      assert entry.evidence == :unverified
      assert entry.scope == nil
      refute "channels:list" in calculate([direct_message_node()]).required_scopes
    end
  end

  describe "comparing what is needed with what was granted" do
    test "a granted permission raises nothing" do
      issues = check([message_node()], ["messages:write"])

      assert issues == []
    end

    test "a permission the workspace does not have blocks" do
      [issue] = check([message_node()], ["workspace:read"])

      assert issue.severity == :error
      assert issue.code == :scope_missing
    end

    test "an installation that never recorded its permissions is not blocked" do
      # An empty snapshot is silence, not refusal, and refusing to activate on
      # silence would block every installation that predates the snapshot.
      assert check([message_node()], []) == []
    end

    test "an unproven permission only warns, however little was granted" do
      issues = check([direct_message_node()], ["messages:write", "channels:write"])

      assert Enum.map(issues, & &1.severity) == [:warning]
      assert Enum.map(issues, & &1.code) == [:scope_unverified]
    end

    test "a workflow needing two missing permissions is told about both" do
      issues = check([message_node(), reaction_node(:add_reaction)], ["workspace:read"])

      assert Enum.map(issues, & &1.severity) == [:error, :error]
    end

    test "the same missing permission is reported once" do
      issues = check([message_node(), message_node()], ["workspace:read"])

      assert length(issues) == 1
    end

    test "a workflow that was fine before a reinstall dropped a permission is blocked now" do
      # The compiled workflow does not change when a workspace is reinstalled
      # with fewer permissions. The snapshot does, and the answer must follow
      # the snapshot rather than what was true when the workflow was written.
      dependencies = calculate([message_node()])

      assert Dependencies.check(dependencies, ["messages:write", "reaction:write"]) == []

      assert [%{code: :scope_missing}] = Dependencies.check(dependencies, ["reaction:write"])
    end

    test "no message repeats a permission the workspace holds" do
      marker = "sentinel-#{System.unique_integer([:positive])}"

      issues = check([message_node()], [marker])

      refute issues == []
      refute Enum.any?(issues, &String.contains?(&1.message, marker))
    end
  end

  describe "connections and secrets" do
    test "an HTTP step contributes the connection it uses" do
      id = Ecto.UUID.generate()

      assert calculate([connected_node(id)]).connection_ids == [id]
    end

    test "an HTTP step records its connection-owned idempotency header check" do
      id = Ecto.UUID.generate()

      dependencies = calculate([connected_node(id, idempotency_header: "Idempotency-Key")])

      assert dependencies.connection_header_requirements == [{id, "idempotency-key"}]
    end

    test "one connection used twice is listed once" do
      id = Ecto.UUID.generate()

      assert calculate([connected_node(id), connected_node(id)]).connection_ids == [id]
    end

    test "connections are listed in one order" do
      ids = Enum.map(1..3, fn _index -> Ecto.UUID.generate() end)

      dependencies = calculate(Enum.map(ids, &connected_node/1))

      assert dependencies.connection_ids == Enum.sort(ids)
    end

    test "a secret named in a body is collected by name" do
      node = connected_node(Ecto.UUID.generate(), body: "token={{ secret.API_TOKEN }}")

      assert calculate([node]).secret_names == ["API_TOKEN"]
    end

    test "a document that emptied its declarations still has the connection and secret it uses" do
      id = Ecto.UUID.generate()
      node = connected_node(id, body: "token={{ secret.API_TOKEN }}")
      {:ok, compiled} = Compiler.compile(definition([node]))

      emptied = %{
        "operations" => [],
        "scopes" => [],
        "connection_ids" => [],
        "secret_names" => []
      }

      compiled = %{
        compiled
        | nodes:
            Map.new(compiled.nodes, fn {step_id, step} ->
              {step_id, %{step | requires: emptied}}
            end)
      }

      dependencies = Dependencies.calculate(compiled)

      assert dependencies.connection_ids == [id]
      assert dependencies.secret_names == ["API_TOKEN"]
    end

    test "a secret named in a header is collected too" do
      node =
        connected_node(Ecto.UUID.generate(),
          headers: %{"x-api-key" => "{{ secret.OTHER_TOKEN }}"}
        )

      assert calculate([node]).secret_names == ["OTHER_TOKEN"]
    end

    test "no secret value is ever held, because only the name is known here" do
      node = connected_node(Ecto.UUID.generate(), body: "token={{ secret.API_TOKEN }}")

      dependencies = calculate([node])

      assert dependencies.secret_names == ["API_TOKEN"]
      refute Map.has_key?(dependencies, :secret_values)
    end

    test "a workflow that uses neither has neither" do
      dependencies = calculate([message_node()])

      assert dependencies.connection_ids == []
      assert dependencies.secret_names == []
    end
  end

  describe "the trigger" do
    test "the binding the trigger projects to travels with the dependencies" do
      dependencies = calculate([message_node()])

      assert %{"bindings" => [binding]} = dependencies.trigger_binding
      assert binding["kind"] == "pumble_event"
      assert binding["type"] == "NEW_MESSAGE"
      assert binding["channel_id"] == "channel-1"
    end

    test "a binding carries no identifier the compiler could not know" do
      %{"bindings" => [binding]} = calculate([message_node()]).trigger_binding

      refute Map.has_key?(binding, "installation_id")
      refute Map.has_key?(binding, "workflow_version_id")
    end
  end

  describe "purity" do
    test "no I/O occurs" do
      steps = [
        message_node(),
        connected_node(Ecto.UUID.generate(), body: "{{ secret.API_TOKEN }}")
      ]

      {:ok, compiled} = Compiler.compile(definition(steps))

      assert query_count(fn ->
               compiled |> Dependencies.calculate() |> Dependencies.check(["messages:write"])
             end) == 0
    end
  end

  defp calculate(steps) do
    {:ok, compiled} = Compiler.compile(definition(steps))

    Dependencies.calculate(compiled)
  end

  defp check(steps, granted) do
    steps |> calculate() |> Dependencies.check(granted)
  end

  defp operations(dependencies), do: Enum.map(dependencies.scope_evidence, & &1.operation)

  defp reaction_node(action) do
    Node.new(:pumble_action, %{action: action, message_id: "message-1", reaction: "tada"})
  end

  defp direct_message_node do
    Node.new(:pumble_action, %{action: :direct_message, user_id: "user-1", text: "hello"})
  end

  defp connected_node(connection_id, config \\ %{}) do
    Node.new(
      :http_action,
      Map.merge(
        %{method: :post, url: "https://example.test/hook", connection_id: connection_id},
        Map.new(config)
      )
    )
  end

  defp query_count(fun) do
    handler = "dependencies-query-count-#{System.unique_integer([:positive])}"
    counter = :counters.new(1, [])
    mine = self()

    :telemetry.attach(
      handler,
      [:pumble_automation, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == mine, do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    try do
      fun.()
      :counters.get(counter, 1)
    after
      :telemetry.detach(handler)
    end
  end
end
