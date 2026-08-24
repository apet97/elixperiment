defmodule PumbleAutomation.Executions.Uncertainty do
  @moduledoc """
  Operator resolution of a paused uncertain effect.

  An ambiguous non-idempotent write does not repeat on its own. This module
  is the audited, owner-only path that marks the effect succeeded, marks it
  failed, or retries it with an explicit duplicate-risk acknowledgement.
  It does not write rows: the engine applies the plan inside the transaction
  that already locked the execution.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Executions.StateMachine
  alias PumbleAutomation.Executions.StepExecution
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows.CompiledWorkflow

  @choices %{
    "succeeded" => :succeeded,
    "failed" => :failed,
    "retry" => :retry
  }

  @type choice :: :succeeded | :failed | :retry

  @type request :: %{
          choice: choice(),
          evidence: map(),
          acknowledge_duplicate_risk?: boolean()
        }

  @type plan :: %{
          idempotent?: boolean(),
          dispatch?: boolean(),
          execution_command: StateMachine.command(),
          step_command: StateMachine.command(),
          execution_to: String.t(),
          step_to: String.t(),
          current_node_id: String.t(),
          insert_next?: boolean(),
          merge_output?: boolean(),
          selected_edge: String.t() | nil,
          output: map(),
          job: map() | nil
        }

  @doc "The owner commands that resolve an uncertain pause."
  @spec choices() :: [choice()]
  def choices, do: [:failed, :retry, :succeeded]

  @doc """
  Parses a resolution choice and optional sanitized evidence.

  `:retry` requires `acknowledge_duplicate_risk: true`. Evidence is scrubbed
  of secret-looking keys and refused when it is too large. Nothing here asks
  for a secret or a raw private payload.
  """
  @spec parse(term(), map()) :: {:ok, request()} | {:error, Error.t()}
  def parse(choice, attrs \\ %{}) when is_map(attrs) do
    with {:ok, choice} <- known_choice(choice),
         :ok <- duplicate_risk(choice, attrs),
         {:ok, evidence} <- sanitize_evidence(attrs) do
      {:ok,
       %{
         choice: choice,
         evidence: evidence,
         acknowledge_duplicate_risk?: acknowledged?(attrs)
       }}
    end
  end

  @doc "`:ok` when the scope may resolve uncertainty."
  @spec authorize(Scope.t()) :: :ok | {:error, Error.t()}
  def authorize(%Scope{} = scope), do: Policy.authorize(scope, :resolve_uncertainty)

  @doc """
  Plans how `request` moves a paused execution.

  An already-applied identical choice is an idempotent stay. A different
  choice against a resolved row is a conflict. Succeeded follows the compiled
  `next` edge when one exists.
  """
  @spec plan(map(), map(), CompiledWorkflow.t(), request()) ::
          {:ok, plan()} | {:error, Error.t()}
  def plan(execution, step, %CompiledWorkflow{} = compiled, request)
      when is_map(execution) and is_map(step) do
    with {:ok, intended} <- intended(execution, step, compiled, request),
         {:ok, exec_plan} <-
           StateMachine.transition(
             :execution,
             status(execution),
             {:resolve_uncertain, intended.execution_to}
           ),
         {:ok, step_plan} <-
           StateMachine.transition(:step, status(step), {:resolve_uncertain, intended.step_to}) do
      if exec_plan.idempotent? and step_plan.idempotent? do
        {:ok,
         intended
         |> Map.put(:idempotent?, true)
         |> Map.put(:job, nil)
         |> Map.put(:insert_next?, false)
         |> Map.put(:dispatch?, false)}
      else
        {:ok, Map.put(intended, :idempotent?, false)}
      end
    end
  end

  @doc "Audit attributes for a committed resolution."
  @spec audit_attrs(Scope.t(), map(), request(), plan()) :: map()
  def audit_attrs(%Scope{} = scope, execution, request, plan) do
    %{
      installation_id: scope.installation_id,
      actor_type: "user",
      actor_id: scope.member_id,
      action: "execution.resolved_uncertainty",
      resource_type: "execution",
      resource_id: Map.get(execution, :id) || Map.get(execution, "id"),
      metadata:
        %{
          "actor_role" => scope.role,
          "outcome" => Atom.to_string(request.choice),
          "previous_state" => "paused_uncertain",
          "next_state" => plan.execution_to,
          "reason" => if(request.choice == :retry, do: "duplicate_risk_acknowledged")
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    }
  end

  defp known_choice(choice) when is_atom(choice), do: known_choice(Atom.to_string(choice))

  defp known_choice(choice) when is_binary(choice) do
    case Map.fetch(@choices, choice) do
      {:ok, known} ->
        {:ok, known}

      :error ->
        {:error,
         Error.new(:validation, :invalid_resolution,
           message: "Uncertainty resolution must be succeeded, failed, or retry."
         )}
    end
  end

  defp known_choice(_choice) do
    {:error,
     Error.new(:validation, :invalid_resolution,
       message: "Uncertainty resolution must be succeeded, failed, or retry."
     )}
  end

  defp duplicate_risk(:retry, attrs) do
    if acknowledged?(attrs) do
      :ok
    else
      {:error,
       Error.new(:validation, :duplicate_risk_unacknowledged,
         message: "Retrying an uncertain write requires acknowledging the duplicate risk."
       )}
    end
  end

  defp duplicate_risk(_choice, _attrs), do: :ok

  defp acknowledged?(attrs) do
    attr(attrs, :acknowledge_duplicate_risk) in [true, "true"]
  end

  defp sanitize_evidence(attrs) do
    case attr(attrs, :evidence) do
      nil ->
        {:ok, %{}}

      map when is_map(map) and not is_struct(map) ->
        bound_evidence(map)

      _other ->
        {:error,
         Error.new(:validation, :invalid_resolution, message: "Evidence must be an object.")}
    end
  end

  defp bound_evidence(map) do
    {:ok, outcome} = Outcome.new(%{kind: :cancelled, output: map})

    case Outcome.bound(outcome, StepExecution.max_payload_bytes()) do
      {:ok, bounded} ->
        {:ok, bounded.output}

      {:error, %Error{code: :output_too_large}} ->
        {:error,
         Error.new(:validation, :invalid_resolution, message: "The evidence is too large.")}

      {:error, _reason} = error ->
        error
    end
  end

  defp intended(execution, _step, _compiled, %{choice: :failed} = request) do
    {:ok, halt_plan(execution, request, "failed", dispatch?: false, merge_output?: false)}
  end

  defp intended(execution, _step, _compiled, %{choice: :retry} = request) do
    generation = lock_version(execution) + 1

    {:ok,
     %{
       dispatch?: true,
       execution_command: {:resolve_uncertain, "running"},
       step_command: {:resolve_uncertain, "running"},
       execution_to: "running",
       step_to: "running",
       current_node_id: current_node_id(execution),
       insert_next?: false,
       merge_output?: false,
       selected_edge: nil,
       output: request.evidence,
       job: %{
         args: job_args(execution, current_node_id(execution), generation),
         opts: []
       }
     }}
  end

  defp intended(execution, _step, compiled, %{choice: :succeeded} = request) do
    node = Map.fetch!(compiled.nodes, current_node_id(execution))

    case Outcome.follow(node.edges, Outcome.linear()) do
      {:ok, :end} ->
        {:ok, halt_plan(execution, request, "completed", dispatch?: false, merge_output?: true)}

      {:ok, {:continue, next_id}} ->
        generation = lock_version(execution) + 1

        {:ok,
         %{
           dispatch?: true,
           execution_command: {:resolve_uncertain, "running"},
           step_command: {:resolve_uncertain, "completed"},
           execution_to: "running",
           step_to: "completed",
           current_node_id: next_id,
           insert_next?: true,
           merge_output?: true,
           selected_edge: Outcome.linear(),
           output: request.evidence,
           job: %{
             args: job_args(execution, next_id, generation),
             opts: []
           }
         }}

      {:error, _reason} ->
        {:ok, halt_plan(execution, request, "failed", dispatch?: false, merge_output?: false)}
    end
  end

  defp halt_plan(execution, request, to, opts) do
    %{
      dispatch?: Keyword.fetch!(opts, :dispatch?),
      execution_command: {:resolve_uncertain, to},
      step_command: {:resolve_uncertain, to},
      execution_to: to,
      step_to: to,
      current_node_id: current_node_id(execution),
      insert_next?: false,
      merge_output?: Keyword.fetch!(opts, :merge_output?),
      selected_edge: if(to == "completed", do: Outcome.linear()),
      output: request.evidence,
      job: nil
    }
  end

  defp job_args(execution, node_id, generation) do
    %{
      installation_id: installation_id(execution),
      execution_id: Map.get(execution, :id) || Map.get(execution, "id"),
      expected_node_id: node_id,
      generation: generation
    }
  end

  defp status(%{status: status}), do: status
  defp current_node_id(%{current_node_id: node_id}), do: node_id
  defp lock_version(%{lock_version: version}), do: version
  defp installation_id(%{installation_id: id}), do: id

  defp attr(attrs, field) do
    Map.get(attrs, field) || Map.get(attrs, Atom.to_string(field))
  end
end
