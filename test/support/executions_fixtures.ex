defmodule PumbleAutomation.ExecutionsFixtures do
  @moduledoc """
  Execution, step, attempt, and approval rows for tests that need one.

  Every row goes through its schema changeset (or `StepAttempt.create/2` /
  `Approval.decide/2`), so a test cannot hold a shape the schema would refuse.
  """

  alias PumbleAutomation.Executions.Approval
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.StepAttempt
  alias PumbleAutomation.Executions.StepExecution
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Workflows.WorkflowVersion
  alias PumbleAutomation.WorkflowsFixtures

  @doc "Inserts an execution bound to `version`."
  @spec execution(WorkflowVersion.t(), map()) :: Execution.t()
  def execution(%WorkflowVersion{} = version, attrs \\ %{}) do
    %Execution{}
    |> Execution.changeset(
      Map.merge(
        %{
          installation_id: version.installation_id,
          workflow_id: version.workflow_id,
          workflow_version_id: version.id,
          execution_key: "exec-#{System.unique_integer([:positive])}",
          status: "queued",
          current_node_id: Ecto.UUID.generate()
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  @doc "Inserts a step for `execution` at `node_id`."
  @spec step_execution(Execution.t(), map()) :: StepExecution.t()
  def step_execution(%Execution{} = execution, attrs \\ %{}) do
    %StepExecution{}
    |> StepExecution.changeset(
      Map.merge(
        %{
          installation_id: execution.installation_id,
          execution_id: execution.id,
          node_id: execution.current_node_id || Ecto.UUID.generate(),
          node_type: "pumble_action",
          status: "queued"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  @doc "Creates the next attempt of `step`."
  @spec step_attempt(StepExecution.t(), map()) :: StepAttempt.t()
  def step_attempt(%StepExecution{} = step, attrs \\ %{}) do
    {:ok, attempt} = StepAttempt.create(step, attrs)
    attempt
  end

  @doc """
  Inserts a pending approval for `step`.

  Pass `:token` to choose the plaintext; only its digest is stored.
  """
  @spec approval(StepExecution.t(), map()) :: Approval.t()
  def approval(%StepExecution{} = step, attrs \\ %{}) do
    {token, attrs} =
      Map.pop(attrs, :token, "approval-token-#{System.unique_integer([:positive])}")

    %Approval{}
    |> Approval.changeset(
      Map.merge(
        %{
          installation_id: step.installation_id,
          execution_id: step.execution_id,
          step_execution_id: step.id,
          public_action_id: Ecto.UUID.generate(),
          token_digest: Approval.digest(token),
          nonce: :crypto.strong_rand_bytes(Approval.nonce_bytes()),
          allowed_approvers: %{"member_ids" => []},
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  @doc "A drafted workflow version ready to bind an execution to."
  @spec version(String.t(), map()) :: WorkflowVersion.t()
  def version(installation_id, attrs \\ %{}) do
    installation_id
    |> WorkflowsFixtures.drafted_workflow()
    |> WorkflowsFixtures.version(attrs)
  end
end
