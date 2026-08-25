defmodule PumbleAutomation.Workflows.PureDomainMatrixTest do
  @moduledoc """
  Catalogue completeness for the pure-domain contracts in Sections 15–31.

  Behavior of each type lives in the owner suite. This file only proves that
  every contracted name still exists, so a dropped atom cannot hide behind a
  passing happy-path test that never mentioned it.
  """

  use ExUnit.Case, async: true

  alias PumbleAutomation.Connections.IpPolicy
  alias PumbleAutomation.Executions.Approval
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.RetryPolicy
  alias PumbleAutomation.Executions.StateMachine
  alias PumbleAutomation.Executions.StepAttempt
  alias PumbleAutomation.Workflows.Definition.ScheduleConfig
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Node.ConditionConfig
  alias PumbleAutomation.Workflows.Node.Predicate
  alias PumbleAutomation.Workflows.Schedule

  test "compiler node types are the six supported kinds" do
    assert Map.keys(Node.types()) |> Enum.sort() ==
             ~w(approval condition delay http_action pumble_action stop)
  end

  test "predicate comparators and condition combinators are the closed sets" do
    assert Predicate.comparators() |> Map.keys() |> Enum.sort() ==
             ~w(contains ends_with eq gt gte in is_empty is_not_empty is_present lt lte neq not_contains starts_with)

    assert ConditionConfig.combinators() == %{"all" => :all, "any" => :any, "none" => :none}
  end

  test "schedule types match between the AST and the stored projection" do
    assert Map.keys(ScheduleConfig.schedule_types()) |> Enum.sort() ==
             ~w(daily every_hours every_minutes once weekly)

    assert Schedule.schedule_types() == ~w(once every_minutes every_hours daily weekly)
  end

  test "trigger types are the five supported kinds" do
    assert Map.keys(Trigger.types()) |> Enum.sort() ==
             ~w(manual manual_test pumble_event schedule webhook)
  end

  test "execution statuses match the state machine and stay lowercase" do
    statuses =
      ~w(queued running waiting_delay waiting_approval paused_uncertain completed failed cancelled)

    assert Execution.statuses() == statuses
    assert StateMachine.states(:execution) == statuses
    assert StateMachine.states(:step) == statuses
    assert Enum.all?(statuses, &(&1 == String.downcase(&1)))

    assert StateMachine.states(:attempt) == StepAttempt.statuses()
    assert StepAttempt.statuses() == ~w(started succeeded failed uncertain cancelled)

    assert StateMachine.states(:approval) == Approval.statuses()
    assert Approval.statuses() == ~w(pending approved rejected timed_out cancelled)
  end

  test "retry backoff uses the documented schedule of five attempts" do
    assert RetryPolicy.schedule() == [1, 5, 30, 120, 600]
    assert RetryPolicy.max_attempts() == 5
  end

  test "the same retry jitter seed yields the same delay sequence" do
    sequence = fn seed ->
      :rand.seed(:exsss, seed)
      for attempt <- 1..5, do: RetryPolicy.backoff_seconds(attempt)
    end

    assert sequence.({2026, 8, 22}) == sequence.({2026, 8, 22})
    refute sequence.({2026, 8, 22}) == sequence.({2026, 8, 23})
  end

  test "every blocked IP reason named by the policy has a representative address" do
    representatives = [
      {{127, 0, 0, 1}, :loopback},
      {{0, 0, 0, 0}, :unspecified},
      {{10, 0, 0, 1}, :private},
      {{100, 64, 0, 1}, :cgnat},
      {{169, 254, 0, 1}, :link_local},
      {{169, 254, 169, 254}, :metadata},
      {{224, 0, 0, 1}, :multicast},
      {{192, 0, 2, 1}, :documentation},
      {{198, 18, 0, 1}, :benchmark},
      {{192, 0, 0, 1}, :reserved},
      {{0xFC00, 0, 0, 0, 0, 0, 0, 1}, :unique_local},
      {{0, 0, 0, 0, 0, 0xFFFF, 8, 8}, :mapped}
    ]

    observed =
      MapSet.new(
        for {ip, reason} <- representatives do
          assert IpPolicy.classify(ip) == {:blocked, reason}
          reason
        end
      )

    expected =
      MapSet.new([
        :loopback,
        :unspecified,
        :private,
        :cgnat,
        :link_local,
        :unique_local,
        :mapped,
        :multicast,
        :documentation,
        :benchmark,
        :reserved,
        :metadata
      ])

    assert observed == expected
  end
end
