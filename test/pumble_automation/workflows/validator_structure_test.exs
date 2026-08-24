defmodule PumbleAutomation.Workflows.ValidatorStructureTest do
  @moduledoc """
  Structural validation: P6-T01.

  This module never checks out a database sandbox. A repository call from
  anywhere under `Validator.validate/1` would raise an ownership error rather
  than pass quietly, so the suite running at all is part of the proof that
  validation performs no I/O. `no I/O occurs` below asserts it directly as
  well.
  """

  # Not async: the bounded-time property test measures elapsed time, and
  # sharing the scheduler with fifteen other test processes would make the
  # measurement a statement about the machine rather than about the validator.
  use ExUnit.Case, async: false

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.ManualTestConfig
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Limits
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Node.Predicate
  alias PumbleAutomation.Workflows.Node.StopConfig
  alias PumbleAutomation.Workflows.ValidationIssue
  alias PumbleAutomation.Workflows.Validator

  describe "a definition that is ready" do
    test "one of every node type reports nothing" do
      assert Validator.validate(full_definition()) == []
    end

    test "the fixture definition reports nothing" do
      assert Validator.validate(definition([message_node()])) == []
    end
  end

  describe "the definition itself" do
    test "a workflow with no steps cannot run" do
      assert [issue] = Validator.validate(definition([]))
      assert issue.code == :no_steps
      assert issue.severity == :error
      assert issue.path == "/steps"
      assert issue.node_id == nil
    end

    test "an unsupported schema version is refused" do
      definition = %{definition([message_node()]) | schema_version: 2}

      assert codes(definition) == [:unsupported_schema_version]
    end

    test "duplicate identifiers are refused" do
      node = message_node()

      assert :duplicate_node_ids in codes(definition([node, node]))
    end

    test "a step type nothing recognizes is an issue, not an exception" do
      node = %{message_node() | type: :teleport}

      assert [issue] = Validator.validate(definition([node]))
      assert issue.code == :unknown_node_type
      assert issue.path == "/steps/0/type"
    end
  end

  # A definition built in memory by the editor never went through the decoder,
  # so nothing has already refused these shapes. Each one used to raise or pass
  # silently; the contract is that every one of them is a reported issue.
  describe "a definition whose contents are not what they claim" do
    test "an enum value outside its mapping is reported, not raised" do
      node =
        :condition
        |> Node.new(%{
          combinator: :all,
          predicates: [%Predicate{left: "x", comparator: :bogus, right: "y"}]
        })
        |> Node.put_branch(:if_true, [stop_node()])

      assert [issue] = Validator.validate(definition([node]))
      assert issue.code == :unknown_value
      assert issue.path == "/steps/0/config/predicates/0/comparator"
    end

    test "a value of the wrong type is refused" do
      assert [issue] =
               Validator.validate(definition([Node.new(:delay, %{duration_seconds: "60"})]))

      assert issue.code == :invalid_type
      assert issue.path == "/steps/0/config/duration_seconds"
    end

    test "a list holding something that is not the declared element is refused" do
      node = Node.new(:approval, %{approver_member_ids: [42], timeout_seconds: 60})
      node = Node.put_branch(node, :approved, [stop_node()])

      assert :invalid_type in codes(definition([node]))
    end

    test "a configuration belonging to another step type is refused" do
      node = %{delay_node() | config: %StopConfig{reason: "done"}}

      assert [issue] = Validator.validate(definition([node]))
      assert issue.code == :invalid_config
      assert issue.path == "/steps/0/config"
    end

    test "a header map that is not text to text is reported against the map" do
      node =
        Node.new(:http_action, %{method: :get, url: "https://x.test", headers: %{{:x} => "v"}})

      assert [issue] = Validator.validate(definition([node]))
      assert issue.code == :invalid_type
      assert issue.path == "/steps/0/config/headers"
    end

    test "an identifier that is not one is refused, for a step and for the trigger" do
      assert [issue] = Validator.validate(definition([%{stop_node() | id: "not-a-uuid"}]))
      assert issue.code == :invalid_id
      assert issue.path == "/steps/0/id"

      trigger = %{Trigger.new(:manual_test, %{}) | id: "also-not-a-uuid"}

      assert [trigger_issue] = Validator.validate(with_trigger(trigger))
      assert trigger_issue.path == "/trigger/id"
    end
  end

  describe "limit boundaries" do
    test "a definition at the node limit passes, and one over it does not" do
      at_limit = definition(Enum.map(1..Limits.max_nodes(), fn _index -> delay_node() end))
      over_limit = definition(Enum.map(1..(Limits.max_nodes() + 1), fn _i -> delay_node() end))

      assert Validator.validate(at_limit) == []
      assert codes(over_limit) == [:too_many_nodes]
    end

    test "a definition at the depth limit passes, and one over it does not" do
      assert Validator.validate(definition(nest(Limits.max_depth()))) == []
      assert :branch_too_deep in codes(definition(nest(Limits.max_depth() + 1)))
    end

    test "more issues than the cap are cut down to the cap, after sorting" do
      issues = Validator.validate(definition(Enum.map(1..4, fn _index -> noisy_condition() end)))

      assert length(issues) == Validator.max_issues()
      assert issues == ValidationIssue.sort(issues)
    end

    # The bound has to be applied before the work, not after it: reporting the
    # over-long list and then walking every item anyway is the amplification
    # the bound exists to prevent.
    test "a collection over its limit is reported without walking into it" do
      over = Limits.max_list_length() * 100

      predicates =
        Enum.map(1..over, fn index ->
          %Predicate{left: "{{ nope#{index}.field }}", comparator: :eq, right: "x"}
        end)

      node =
        :condition
        |> Node.new(%{combinator: :all, predicates: predicates})
        |> Node.put_branch(:if_true, [stop_node()])

      issues = Validator.validate(definition([node]))

      assert :too_many_items in Enum.map(issues, & &1.code)
      refute :unknown_root in Enum.map(issues, & &1.code)
    end
  end

  describe "the trigger" do
    test "a supported trigger reports nothing" do
      assert Validator.validate(definition([message_node()])) == []
    end

    test "an unsupported trigger type is refused" do
      trigger = %Trigger{id: Ecto.UUID.generate(), type: :nope, config: %ManualTestConfig{}}
      definition = %{definition([message_node()]) | trigger: trigger}

      assert [issue] = Validator.validate(definition)
      assert issue.code == :unknown_trigger_type
      assert issue.path == "/trigger/type"
      assert issue.node_id == trigger.id
    end

    test "a required trigger field that is missing is refused" do
      definition = with_trigger(Trigger.new(:pumble_event, %{}))

      assert [issue] = Validator.validate(definition)
      assert issue.code == :missing_required_field
      assert issue.path == "/trigger/config/event"
    end
  end

  describe "condition" do
    test "a condition with a comparison and a branch reports nothing" do
      assert Validator.validate(definition([condition_node(if_true: [stop_node()])])) == []
    end

    test "a condition with no comparison is refused" do
      node = Node.new(:condition, %{combinator: :all, predicates: []})
      node = Node.put_branch(node, :if_true, [stop_node()])

      assert codes(definition([node])) == [:no_predicates]
    end

    test "a condition that branches nowhere is refused" do
      assert codes(definition([condition_node()])) == [:empty_branches]
    end
  end

  describe "delay" do
    test "a delay with a duration reports nothing" do
      assert Validator.validate(definition([delay_node()])) == []
    end

    test "a delay with no duration is refused" do
      assert [issue] = Validator.validate(definition([Node.new(:delay, %{})]))
      assert issue.code == :missing_required_field
      assert issue.path == "/steps/0/config/duration_seconds"
    end

    test "a duration outside the allowed range is refused" do
      node = Node.new(:delay, %{duration_seconds: 0})

      assert codes(definition([node])) == [:value_out_of_range]
    end
  end

  describe "approval" do
    test "an approval with an approver, a timeout, and a branch reports nothing" do
      assert Validator.validate(definition([approval_node(approved: [message_node()])])) == []
    end

    test "an approval with no approver is refused" do
      node =
        :approval
        |> Node.new(%{prompt: "Ship it?", approver_member_ids: [], timeout_seconds: 60})
        |> Node.put_branch(:approved, [stop_node()])

      assert codes(definition([node])) == [:no_approvers]
    end

    test "an approval with no timeout is refused" do
      node =
        :approval
        |> Node.new(%{approver_member_ids: ["member-1"]})
        |> Node.put_branch(:approved, [stop_node()])

      assert codes(definition([node])) == [:missing_required_field]
    end

    test "an approval that branches nowhere is refused" do
      assert codes(definition([approval_node()])) == [:empty_branches]
    end
  end

  describe "pumble action" do
    test "a message action reports nothing" do
      assert Validator.validate(definition([message_node()])) == []
    end

    test "an action with no action selected is refused" do
      assert codes(definition([Node.new(:pumble_action, %{})])) == [:missing_required_field]
    end
  end

  describe "http action" do
    test "a request with a method and a URL reports nothing" do
      assert Validator.validate(definition([http_node()])) == []
    end

    test "a request with no method and no URL is refused" do
      assert [method, url] = Validator.validate(definition([Node.new(:http_action, %{})]))
      assert method.code == :missing_required_field
      assert method.path == "/steps/0/config/method"
      assert url.code == :missing_required_field
      assert url.path == "/steps/0/config/url"
    end
  end

  describe "stop" do
    test "a stop with a reason reports nothing" do
      assert Validator.validate(definition([stop_node()])) == []
    end

    test "a reason longer than the field allows is refused" do
      node = Node.new(:stop, %{reason: String.duplicate("x", 1025)})

      assert codes(definition([node])) == [:value_too_long]
    end
  end

  describe "unreachable structure" do
    test "a step after a stop warns, and does not block" do
      assert [issue] = Validator.validate(definition([stop_node(), message_node()]))
      assert issue.code == :unreachable_after_stop
      assert issue.severity == :warning
      assert issue.path == "/steps/1"
      refute ValidationIssue.errors?([issue])
    end

    test "one warning names the first dead step, however many follow it" do
      steps = [stop_node(), message_node(), delay_node(), message_node()]

      assert [issue] = Validator.validate(definition(steps))
      assert issue.path == "/steps/1"
    end

    test "a stop at the end of a sequence is not a warning" do
      assert Validator.validate(definition([message_node(), stop_node()])) == []
    end

    test "the warning is scoped to the branch the stop is in" do
      node = condition_node(if_true: [stop_node(), message_node()], if_false: [message_node()])

      assert [issue] = Validator.validate(definition([node]))
      assert issue.path == "/steps/0/if_true/1"
    end
  end

  describe "aggregation and ordering" do
    test "every problem is reported, not just the first" do
      steps = [Node.new(:delay, %{}), condition_node(), Node.new(:pumble_action, %{})]

      assert paths_and_codes(definition(steps)) == [
               {"/steps/0/config/duration_seconds", :missing_required_field},
               {"/steps/1", :empty_branches},
               {"/steps/2/config/action", :missing_required_field}
             ]
    end

    test "the same definition always produces the same list" do
      definition = definition([Node.new(:delay, %{}), stop_node(), condition_node()])

      assert Validator.validate(definition) == Validator.validate(definition)
    end

    test "errors come before warnings" do
      steps = [stop_node(), Node.new(:delay, %{})]

      assert [error, warning] = Validator.validate(definition(steps))
      assert error.severity == :error
      assert warning.severity == :warning
    end

    test "an issue names the step it belongs to" do
      node = Node.new(:delay, %{})

      assert [issue] = Validator.validate(definition([node]))
      assert issue.node_id == node.id
    end
  end

  describe "purity" do
    test "validation does not change the definition it was given" do
      definition = full_definition()
      encoded = Definition.encode(definition)

      Validator.validate(definition)

      assert Definition.encode(definition) == encoded
    end

    test "no I/O occurs" do
      assert query_count(fn -> Validator.validate(full_definition()) end) == 0
    end

    test "no message repeats anything the author typed" do
      marker = "sentinel-#{System.unique_integer([:positive])}"

      issues =
        marker
        |> marked_definition()
        |> Validator.validate()

      refute issues == []
      refute Enum.any?(issues, &String.contains?(&1.message, marker))
    end
  end

  describe "bounded work" do
    test "one hundred random definitions all validate within a bounded time" do
      # A seeded generator rather than a property-testing dependency: the seed
      # is fixed, so a failure names an exact set of documents to replay. The
      # bound is two orders of magnitude above what this takes, because the
      # claim under test is termination, not speed.
      :rand.seed(:exsss, {2026, 8, 15})

      definitions = Enum.map(1..100, fn _run -> random_definition() end)

      {elapsed, results} = :timer.tc(fn -> Enum.map(definitions, &Validator.validate/1) end)

      assert Enum.all?(results, fn issues ->
               is_list(issues) and Enum.all?(issues, &match?(%ValidationIssue{}, &1))
             end)

      assert div(elapsed, 1000) < 5_000
    end

    # The invariant the hand-written cases above each cover one instance of:
    # whatever a step's type, identifier, or configuration holds, validation
    # answers with issues. Corruption is applied to a valid document so that
    # every run reaches real traversal rather than stopping at the first thing
    # that is obviously wrong.
    #
    # What is corrupted is what a person can reach. `Node.new/2` writes
    # attributes into a configuration struct without checking their types, so
    # any value a form can send arrives here, and the trigger and node type,
    # identifier, and configuration are all writable. The shape of the tree
    # itself is not: `Node.put_branch/3` takes only a list, and a branch is
    # built by the editor rather than typed by an author. A branch holding
    # something that is not a step is the programmer-invariant violation the
    # task's failure behaviour allows to raise, so it is not generated here.
    test "no corruption of a valid definition can make validation raise" do
      :rand.seed(:exsss, {2026, 8, 16})

      for _run <- 1..200 do
        definition = corrupt(random_definition())
        issues = Validator.validate(definition)

        assert Enum.all?(issues, &match?(%ValidationIssue{}, &1))
      end
    end
  end

  defp corrupt(definition) do
    %{
      definition
      | steps: Enum.map(definition.steps, &corrupt_node/1),
        trigger: corrupt_trigger(definition.trigger)
    }
  end

  defp corrupt_trigger(trigger) do
    case :rand.uniform(4) do
      1 -> %{trigger | type: :telepathy}
      2 -> %{trigger | id: "not-a-uuid"}
      3 -> %{trigger | config: %StopConfig{reason: "elsewhere"}}
      _ -> trigger
    end
  end

  defp corrupt_node(node) do
    case :rand.uniform(8) do
      1 -> %{node | type: :teleport}
      2 -> %{node | id: "not-a-uuid"}
      3 -> %{node | config: %StopConfig{reason: "elsewhere"}}
      4 -> put_config(node, :bogus_atom)
      5 -> put_config(node, 42)
      6 -> put_config(node, %{{:tuple} => "value"})
      7 -> put_config(node, ["a", 1, nil])
      _ -> put_config(node, "{{ unclosed and {{ trigger.Nope }}")
    end
  end

  # Overwrites one declared field of the node's own configuration, so the
  # corrupted value lands where that configuration says a real field lives.
  defp put_config(node, value) do
    case node.config.__struct__.fields() do
      [] ->
        node

      fields ->
        {name, _kind, _opts} = Enum.random(fields)
        %{node | config: Map.put(node.config, name, value)}
    end
  end

  defp codes(definition) do
    definition |> Validator.validate() |> Enum.map(& &1.code)
  end

  defp paths_and_codes(definition) do
    definition |> Validator.validate() |> Enum.map(&{&1.path, &1.code})
  end

  defp with_trigger(trigger) do
    %{definition([message_node()]) | trigger: trigger}
  end

  defp full_definition do
    definition([
      message_node(),
      delay_node(),
      http_node(),
      condition_node(if_true: [message_node()], if_false: [stop_node()]),
      approval_node(
        approved: [message_node()],
        rejected: [stop_node()],
        timed_out: [delay_node()]
      )
    ])
  end

  defp marked_definition(marker) do
    definition([
      Node.new(:pumble_action, %{action: :send_message, text: "{{ #{marker}.field }}"}),
      Node.new(:http_action, %{method: :get, url: marker, body: marker}),
      Node.new(:stop, %{reason: "{{ #{marker} }}"})
    ])
  end

  defp nest(1), do: [stop_node()]
  defp nest(level), do: [condition_node(if_true: nest(level - 1))]

  # A condition whose every comparison names a root that does not exist, which
  # is the cheapest way to produce more issues than the cap allows.
  defp noisy_condition do
    predicates =
      Enum.map(1..Limits.max_list_length(), fn index ->
        %Predicate{left: "{{ nope#{index}.field }}", comparator: :eq, right: "x"}
      end)

    :condition
    |> Node.new(%{combinator: :all, predicates: predicates})
    |> Node.put_branch(:if_true, [stop_node()])
  end

  defp random_definition do
    definition(Enum.map(1..8, fn _index -> random_node(2) end))
  end

  defp random_node(0), do: Enum.random([message_node(), delay_node(), stop_node(), http_node()])

  defp random_node(depth) do
    case :rand.uniform(6) do
      1 -> condition_node(if_true: [random_node(depth - 1)], if_false: [random_node(depth - 1)])
      2 -> approval_node(approved: [random_node(depth - 1)])
      3 -> message_node()
      4 -> delay_node()
      5 -> http_node()
      _ -> stop_node()
    end
  end

  # Counts the repository queries one call makes, using the repository's own
  # telemetry event. Zero is the assertion; there is no sandbox to make one in.
  defp query_count(fun) do
    handler = "validator-query-count-#{System.unique_integer([:positive])}"
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
