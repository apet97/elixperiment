defmodule PumbleAutomation.Workflows.ValidatorSemanticTest do
  @moduledoc """
  Expressions, templates, and per-step semantics.

  Like the structural suite, this module checks out no database sandbox, so
  any repository call under `Validator.validate/1` would raise rather than
  pass quietly.

  ## What is not here

  The template contract lets a *field* choose what happens when a reference resolves to
  nothing: fail, empty string, or null, defaulting to fail. No configuration
  in the schema carries that choice yet, so there is nothing for this validator to
  validate and nothing here to test. What is tested under "missing values" is
  the behaviour that does exist: which fields must be filled in, and which
  comparators need a second operand.
  """

  use ExUnit.Case, async: true

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Connections.Connection
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Limits
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Node.ConditionConfig
  alias PumbleAutomation.Workflows.Node.Predicate
  alias PumbleAutomation.Workflows.ValidationIssue
  alias PumbleAutomation.Workflows.Validator

  describe "path grammar in a template field" do
    test "the five data roots resolve" do
      for path <- ["trigger.channel_id", "execution.id", "workspace.name", "actor.id"] do
        assert Validator.validate(definition([text_node("{{ #{path} }}")])) == []
      end
    end

    test "a root that is not a root is refused" do
      assert codes(definition([text_node("{{ message.text }}")])) == [:unknown_root]
    end

    test "a name that could reach into a struct is refused" do
      assert codes(definition([text_node("{{ trigger.__struct__ }}")])) == [:invalid_segment]
    end

    test "the issue names the field the reference sits in" do
      assert [issue] = Validator.validate(definition([text_node("{{ nope.thing }}")]))
      assert issue.path == "/steps/0/config/text"
      assert issue.severity == :error
    end

    # An author who closes the second reference should not then be told the
    # first one names a step that does not exist. Both are true now.
    test "a reference that never closes does not hide a reference that is wrong" do
      text = "{{ steps.#{id()}.output.value }} and {{ never closed"

      assert codes(definition([text_node(text)])) == [
               :unknown_step_reference,
               :unterminated_reference
             ]
    end
  end

  describe "trigger data" do
    test "anything under data resolves, because its keys vary by event" do
      assert Validator.validate(definition([text_node("{{ trigger.data.whatever }}")])) == []
    end

    test "a field the normalized event does not carry is refused" do
      assert codes(definition([text_node("{{ trigger.nickname }}")])) == [:unknown_trigger_field]
    end

    test "the plumbing of an event is not reachable" do
      for field <- ~w(provider installation_id kind delivery_key) do
        assert codes(definition([text_node("{{ trigger.#{field} }}")])) ==
                 [:unknown_trigger_field]
      end
    end
  end

  describe "branch reachability" do
    test "an earlier step in the same sequence is available" do
      first = text_node("hello")

      assert Validator.validate(definition([first, text_node(output_of(first))])) == []
    end

    test "a later step is not available" do
      later = text_node("hello")
      steps = [text_node(output_of(later)), later]

      assert codes(definition(steps)) == [:step_not_reachable]
    end

    test "a step cannot read its own output" do
      id = Ecto.UUID.generate()
      node = text_node("{{ steps.#{id}.output.value }}", id: id)

      assert codes(definition([node])) == [:step_not_reachable]
    end

    test "a step inside a branch cannot read a step in the sibling branch" do
      inside_false = text_node("hello")

      node =
        condition_node(
          if_true: [text_node(output_of(inside_false))],
          if_false: [inside_false]
        )

      assert codes(definition([node])) == [:step_not_reachable]
    end

    test "a step inside a branch can read an earlier step outside it" do
      before = text_node("hello")
      node = condition_node(if_true: [text_node(output_of(before))])

      assert Validator.validate(definition([before, node])) == []
    end

    test "a step inside a branch can read the branching step it is nested in" do
      approval = approval_node()
      approval = Node.put_branch(approval, :approved, [text_node(output_of(approval))])

      assert Validator.validate(definition([approval])) == []
    end

    test "a step after a branch cannot read a step from inside it" do
      inside = text_node("hello")
      node = condition_node(if_true: [inside])

      assert codes(definition([node, text_node(output_of(inside))])) == [:step_not_reachable]
    end

    test "a step that does not exist is refused" do
      path = "{{ steps.#{Ecto.UUID.generate()}.output.value }}"

      assert codes(definition([text_node(path)])) == [:unknown_step_reference]
    end
  end

  describe "the output schema" do
    test "an action, a request, and an approval publish output" do
      for node <- [message_node(), http_node(), approval_node(approved: [stop_node()])] do
        assert Validator.validate(definition([node, text_node(output_of(node))])) == []
      end
    end

    test "a condition, a delay, and a stop publish nothing" do
      for node <- [condition_node(if_true: [stop_node()]), delay_node(), stop_node()] do
        assert :step_produces_no_output in codes(definition([node, text_node(output_of(node))]))
      end
    end
  end

  describe "typed comparisons" do
    test "a comparison between two numbers is fine, whichever way it points" do
      for comparator <- [:gt, :gte, :lt, :lte] do
        assert Validator.validate(definition([compare("10", comparator, "2.5")])) == []
      end
    end

    test "a comparison between two literals that are not numbers is refused now" do
      for comparator <- [:gt, :gte, :lt, :lte] do
        assert codes(definition([compare("high", comparator, "2")])) ==
                 [:comparator_type_mismatch]
      end
    end

    test "a comparison whose operand comes from the run is left to the run" do
      assert Validator.validate(definition([compare("{{ trigger.data.count }}", :gt, "2")])) == []
      assert Validator.validate(definition([compare("2", :lt, "{{ actor.id }}")])) == []
    end

    test "a text comparator accepts text on both sides" do
      for comparator <- [:eq, :neq, :contains, :not_contains, :starts_with, :ends_with] do
        assert Validator.validate(definition([compare("deploy", comparator, "dep")])) == []
      end
    end

    test "all, any, and none accept the same valid predicates" do
      for combinator <- ConditionConfig.combinators() |> Map.values() |> Enum.sort() do
        node =
          :condition
          |> Node.new(%{
            combinator: combinator,
            predicates: [%Predicate{left: "a", comparator: :eq, right: "a"}]
          })
          |> Node.put_branch(:if_true, [stop_node()])

        assert Validator.validate(definition([node])) == []
      end
    end
  end

  describe "missing values" do
    test "a comparator that needs a second operand and has none is refused" do
      assert codes(definition([compare("left", :eq, nil)])) == [:comparator_operand_missing]
    end

    test "a comparator that takes no second operand does not need one" do
      for comparator <- [:is_empty, :is_not_empty, :is_present] do
        assert Validator.validate(definition([compare("left", comparator, nil)])) == []
      end
    end

    test "is_present ignores a supplied right operand with a warning" do
      assert [issue] = Validator.validate(definition([compare("left", :is_present, "x")]))
      assert issue.code == :comparator_operand_unused
      assert issue.severity == :warning
    end

    test "a second operand a comparator ignores is a warning, not a refusal" do
      assert [issue] = Validator.validate(definition([compare("left", :is_empty, "x")]))
      assert issue.code == :comparator_operand_unused
      assert issue.severity == :warning
      refute ValidationIssue.errors?([issue])
    end

    test "an optional field left empty is not an issue" do
      node = Node.new(:http_action, %{method: :post, url: "https://example.test"})

      assert Validator.validate(definition([node])) == []
    end

    test "an explicit remote idempotency header is accepted" do
      node =
        Node.new(:http_action, %{
          method: :post,
          url: "https://example.test",
          idempotency_header: "Idempotency-Key"
        })

      assert Validator.validate(definition([node])) == []
    end

    test "an idempotency header is literal, non-reserved, and unique" do
      assert :template_not_allowed in codes(
               definition([request(idempotency_header: "{{ trigger.data.header }}")])
             )

      for header <- ["Authorization", "Content-Type", "Accept-Encoding", "Host"] do
        assert :http_idempotency_header_reserved in codes(
                 definition([request(idempotency_header: header)])
               )
      end

      assert :http_idempotency_header_conflict in codes(
               definition([
                 request(
                   headers: %{"IDEMPOTENCY-KEY" => "caller-value"},
                   idempotency_header: "Idempotency-Key"
                 )
               ])
             )
    end
  end

  describe "template bounds" do
    test "a template at the reference limit is accepted" do
      text = String.duplicate("{{ trigger.data.text }}", Limits.max_template_references())

      assert Validator.validate(definition([text_node(text)])) == []
    end

    test "a template over the reference limit is refused" do
      text = String.duplicate("{{ trigger.data.text }}", Limits.max_template_references() + 1)

      assert codes(definition([text_node(text)])) == [:too_many_references]
    end

    test "a reference that is opened and never closed is refused" do
      assert codes(definition([text_node("hello {{ trigger.data.text")])) ==
               [:unterminated_reference]
    end

    test "an empty reference is refused" do
      assert codes(definition([text_node("hello {{ }}")])) == [:empty_reference]
    end
  end

  describe "where a template may appear" do
    test "a field that takes plain text refuses a reference" do
      node = Node.new(:http_action, %{method: :post, url: "https://x.test", connection_id: id()})
      node = %{node | config: %{node.config | connection_id: "{{ trigger.data.text }}"}}

      assert :template_not_allowed in codes(definition([node]))
    end

    test "a trigger configuration takes plain text" do
      trigger = Trigger.new(:pumble_event, %{event: :new_message, keyword: "{{ actor.id }}"})

      assert codes(with_trigger(trigger)) == [:template_not_allowed]
    end

    test "a list of plain text refuses a reference" do
      node =
        :approval
        |> Node.new(%{approver_member_ids: ["{{ actor.id }}"], timeout_seconds: 60})
        |> Node.put_branch(:approved, [stop_node()])

      assert [issue] = Validator.validate(definition([node]))
      assert issue.code == :template_not_allowed
      assert issue.path == "/steps/0/config/approver_member_ids/0"
    end
  end

  describe "secrets" do
    test "a secret may fill an outbound body" do
      assert Validator.validate(definition([request(body: "token={{ secret.API_TOKEN }}")])) == []
    end

    test "a secret may fill an outbound header" do
      node = request(headers: %{"authorization" => "Bearer {{ secret.API_TOKEN }}"})

      assert Validator.validate(definition([node])) == []
    end

    test "a secret may not reach a URL, a message, or a comparison" do
      reference = "{{ secret.API_TOKEN }}"

      assert :secret_not_allowed in codes(
               definition([request(url: "https://x.test/#{reference}")])
             )

      assert codes(definition([text_node(reference)])) == [:secret_not_allowed]
      assert codes(definition([compare(reference, :eq, "x")])) == [:secret_not_allowed]
    end

    test "a name that is not a secret name is refused" do
      assert codes(definition([request(body: "{{ secret.api_token }}")])) ==
               [:invalid_secret_name]
    end
  end

  describe "Pumble action fields" do
    test "each action requires the fields its operation needs" do
      assert codes(action(%{action: :send_message})) == [
               :action_field_missing,
               :action_field_missing
             ]

      assert codes(action(%{action: :reply_message, channel_id: "c", text: "t"})) ==
               [:action_field_missing]

      assert codes(action(%{action: :direct_message, text: "t"})) == [:action_field_missing]
      assert codes(action(%{action: :add_reaction, message_id: "m"})) == [:action_field_missing]
      assert codes(action(%{action: :remove_reaction, reaction: "+1"})) == [:action_field_missing]
    end

    test "a complete action reports nothing" do
      assert Validator.validate(action(%{action: :add_reaction, message_id: "m", reaction: "+1"})) ==
               []
    end

    test "a field the action ignores is a warning" do
      assert [issue] =
               Validator.validate(
                 action(%{action: :send_message, channel_id: "c", text: "t", reaction: "+1"})
               )

      assert issue.code == :action_field_unused
      assert issue.severity == :warning
      assert issue.path == "/steps/0/config/reaction"
    end
  end

  describe "HTTP requests" do
    test "a method that carries no body refuses one" do
      for method <- [:get, :delete] do
        assert codes(definition([request(method: method, body: "x")])) ==
                 [:http_body_not_allowed]
      end
    end

    test "a method that carries a body accepts one" do
      for method <- [:post, :put, :patch] do
        assert Validator.validate(definition([request(method: method, body: "x")])) == []
      end
    end

    test "a URL must name its scheme literally" do
      assert codes(definition([request(url: "example.test/hook")])) == [:http_url_not_absolute]

      assert codes(definition([request(url: "{{ trigger.data.url }}")])) ==
               [:http_url_not_absolute]
    end

    test "an HTTP URL is refused because the transport requires HTTPS" do
      assert codes(definition([request(url: "http://example.test/hook")])) == [:http_not_allowed]
    end

    test "a webhook may require the implemented raw-body signature" do
      assert Validator.validate(with_trigger(Trigger.new(:webhook, %{require_signature: true}))) ==
               []
    end

    test "a header the transport owns may not be set" do
      for name <- ["host", "content-length", "Proxy-Authorization"] do
        assert codes(definition([request(headers: %{name => "x"})])) == [:http_header_blocked]
      end
    end

    test "an authorization header must carry a secret" do
      node = request(headers: %{"Authorization" => "Bearer literal-token"})

      assert [issue] = Validator.validate(definition([node]))
      assert issue.code == :http_header_needs_secret
      assert issue.path == "/steps/0/config/headers/Authorization"
    end

    # One header rule, owned by `Connection`. These are the cases a workflow
    # would otherwise have to restate, and restating them is how the two
    # definitions of a valid header drift apart.
    test "a header name must be a header name" do
      for name <- ["bad\r\nname", "no spaces", "semi;colon"] do
        assert codes(definition([request(headers: %{name => "x"})])) == [:http_header_invalid]
      end
    end

    test "a header value may not smuggle a control character" do
      assert codes(definition([request(headers: %{"x-note" => "a\r\nb"})])) ==
               [:http_header_invalid]
    end

    test "a header value over the connection limit is refused" do
      value = String.duplicate("x", Connection.max_header_value() + 1)

      assert codes(definition([request(headers: %{"x-note" => value})])) == [:value_too_long]
    end

    test "a connection identifier must be one" do
      assert codes(definition([request(connection_id: "my-connection")])) ==
               [:invalid_connection_id]

      assert Validator.validate(definition([request(connection_id: id())])) == []
    end
  end

  describe "schedules" do
    test "each schedule type requires the fields it runs on" do
      assert codes(schedule_trigger(%{schedule_type: :once})) == [:schedule_field_missing]

      assert codes(schedule_trigger(%{schedule_type: :every_minutes})) == [
               :schedule_field_missing
             ]

      assert codes(schedule_trigger(%{schedule_type: :every_hours})) == [:schedule_field_missing]
      assert codes(schedule_trigger(%{schedule_type: :daily})) == [:schedule_field_missing]

      assert codes(schedule_trigger(%{schedule_type: :weekly, time_of_day: "09:00"})) ==
               [:schedule_field_missing]
    end

    test "a complete schedule reports nothing" do
      assert Validator.validate(
               schedule_trigger(%{schedule_type: :once, run_at: "2026-09-01T09:00:00Z"})
             ) ==
               []

      assert Validator.validate(
               schedule_trigger(%{
                 schedule_type: :once,
                 run_at: "2026-09-01T09:00:00",
                 timezone: "Europe/Belgrade"
               })
             ) == []

      assert Validator.validate(
               schedule_trigger(%{
                 schedule_type: :daily,
                 time_of_day: "09:00",
                 timezone: "Europe/Belgrade"
               })
             ) == []

      assert Validator.validate(
               schedule_trigger(%{
                 schedule_type: :every_minutes,
                 interval: 5,
                 timezone: "Etc/UTC"
               })
             ) == []

      assert Validator.validate(
               schedule_trigger(%{
                 schedule_type: :every_hours,
                 interval: 2,
                 timezone: "Etc/UTC"
               })
             ) == []

      assert Validator.validate(
               schedule_trigger(%{
                 schedule_type: :weekly,
                 time_of_day: "09:00",
                 weekdays: ["monday"],
                 timezone: "Etc/UTC"
               })
             ) == []
    end

    test "a run time that is not a date and time is refused" do
      assert codes(schedule_trigger(%{schedule_type: :once, run_at: "next tuesday"})) == [
               :invalid_run_at
             ]
    end

    test "a time of day that is not one is refused" do
      for value <- ["9am", "24:00", "09:60"] do
        assert codes(schedule_trigger(%{schedule_type: :daily, time_of_day: value})) ==
                 [:invalid_time_of_day]
      end
    end

    test "a time zone that does not have the shape of one is refused" do
      config = %{schedule_type: :daily, time_of_day: "09:00", timezone: "not a zone"}

      assert codes(schedule_trigger(config)) == [:invalid_timezone]
    end
  end

  defp codes(definition) do
    definition |> Validator.validate() |> Enum.map(& &1.code)
  end

  defp id, do: Ecto.UUID.generate()

  defp output_of(node), do: "{{ steps.#{node.id}.output.value }}"

  defp text_node(text, opts \\ []) do
    Node.new(:pumble_action, %{action: :send_message, channel_id: "c", text: text}, opts)
  end

  defp action(config), do: definition([Node.new(:pumble_action, config)])

  defp compare(left, comparator, right) do
    :condition
    |> Node.new(%{
      combinator: :all,
      predicates: [%Predicate{left: left, comparator: comparator, right: right}]
    })
    |> Node.put_branch(:if_true, [stop_node()])
  end

  defp request(overrides) do
    config = Enum.into(overrides, %{method: :post, url: "https://example.test/hook"})

    Node.new(:http_action, config)
  end

  defp schedule_trigger(config), do: with_trigger(Trigger.new(:schedule, config))

  defp with_trigger(trigger), do: %{definition([message_node()]) | trigger: trigger}
end
