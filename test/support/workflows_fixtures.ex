defmodule PumbleAutomation.WorkflowsFixtures do
  @moduledoc """
  Definitions, nodes, and workflow rows for tests that need one.

  Every node is built through `PumbleAutomation.Workflows.Node.new/3`, so a
  fixture cannot hold a shape the constructor would refuse, and a change to
  what a node is cannot leave these tests passing against a shape that no
  longer exists.
  """

  alias PumbleAutomation.Repo
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Schedule
  alias PumbleAutomation.Workflows.TriggerBinding
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomation.Workflows.WorkflowVersion

  @doc "A Pumble event trigger."
  @spec trigger(keyword()) :: Trigger.t()
  def trigger(opts \\ []) do
    Trigger.new(:pumble_event, %{event: :new_message, channel_ids: ["channel-1"]}, opts)
  end

  @doc "A definition with the given steps."
  @spec definition([Node.t()]) :: Definition.t()
  def definition(steps \\ []), do: Definition.new(trigger(), steps)

  @doc "A Pumble action node that sends a message."
  @spec message_node(keyword()) :: Node.t()
  def message_node(opts \\ []) do
    Node.new(
      :pumble_action,
      %{action: :send_message, channel_id: "channel-1", text: "hello"},
      opts
    )
  end

  @doc "A delay node."
  @spec delay_node(keyword()) :: Node.t()
  def delay_node(opts \\ []), do: Node.new(:delay, %{duration_seconds: 60}, opts)

  @doc "A stop node."
  @spec stop_node(keyword()) :: Node.t()
  def stop_node(opts \\ []), do: Node.new(:stop, %{reason: "done"}, opts)

  @doc "An HTTP action node."
  @spec http_node(keyword()) :: Node.t()
  def http_node(opts \\ []) do
    Node.new(
      :http_action,
      %{method: :post, url: "https://example.test/hook", headers: %{"accept" => "text/plain"}},
      opts
    )
  end

  @doc "A condition node, with optional branch contents."
  @spec condition_node(keyword()) :: Node.t()
  def condition_node(opts \\ []) do
    {branches, opts} = Keyword.split(opts, [:if_true, :if_false])

    :condition
    |> Node.new(
      %{
        combinator: :all,
        predicates: [
          %PumbleAutomation.Workflows.Node.Predicate{
            left: "{{ trigger.data.text }}",
            comparator: :contains,
            right: "deploy"
          }
        ]
      },
      opts
    )
    |> Node.put_branch(:if_true, Keyword.get(branches, :if_true, []))
    |> Node.put_branch(:if_false, Keyword.get(branches, :if_false, []))
  end

  @doc "An approval node, with optional branch contents."
  @spec approval_node(keyword()) :: Node.t()
  def approval_node(opts \\ []) do
    {branches, opts} = Keyword.split(opts, [:approved, :rejected, :timed_out])

    :approval
    |> Node.new(
      %{prompt: "Ship it?", approver_member_ids: ["member-1"], timeout_seconds: 3600},
      opts
    )
    |> Node.put_branch(:approved, Keyword.get(branches, :approved, []))
    |> Node.put_branch(:rejected, Keyword.get(branches, :rejected, []))
    |> Node.put_branch(:timed_out, Keyword.get(branches, :timed_out, []))
  end

  @doc "Inserts a workflow row for `installation_id`."
  @spec workflow(String.t(), map()) :: Workflow.t()
  def workflow(installation_id, attrs \\ %{}) do
    %Workflow{}
    |> Workflow.changeset(
      Map.merge(
        %{
          installation_id: installation_id,
          name: "Deploy announcements",
          slug: "deploy-#{System.unique_integer([:positive])}",
          status: "draft"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  @doc """
  Inserts a workflow row for `installation_id` that already has a draft.

  Most tests about versions, bindings, or schedules need a workflow they can
  version, and a workflow with no draft cannot be versioned.
  """
  @spec drafted_workflow(String.t(), map()) :: Workflow.t()
  def drafted_workflow(installation_id, attrs \\ %{}) do
    workflow(
      installation_id,
      Map.put_new(attrs, :draft_definition, Definition.encode(definition()))
    )
  end

  @doc "Creates the next immutable version of `workflow`."
  @spec version(Workflow.t(), map()) :: WorkflowVersion.t()
  def version(%Workflow{} = workflow, attrs \\ %{}) do
    {:ok, version} = WorkflowVersion.create(workflow, attrs)
    version
  end

  @doc "Inserts one trigger binding against `version`."
  @spec trigger_binding(WorkflowVersion.t(), map()) :: TriggerBinding.t()
  def trigger_binding(%WorkflowVersion{} = version, attrs \\ %{}) do
    %TriggerBinding{}
    |> TriggerBinding.changeset(
      Map.merge(
        %{
          installation_id: version.installation_id,
          workflow_version_id: version.id,
          kind: "pumble_event",
          type: "NEW_MESSAGE"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  @doc "Inserts one schedule against `version`."
  @spec schedule(WorkflowVersion.t(), map()) :: Schedule.t()
  def schedule(%WorkflowVersion{} = version, attrs \\ %{}) do
    %Schedule{}
    |> Schedule.changeset(
      Map.merge(
        %{
          installation_id: version.installation_id,
          workflow_id: version.workflow_id,
          workflow_version_id: version.id,
          schedule_type: "daily",
          timezone: "Etc/UTC",
          next_run_at: DateTime.utc_now()
        },
        attrs
      )
    )
    |> Repo.insert!()
  end
end
