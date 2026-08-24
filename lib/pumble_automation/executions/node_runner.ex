defmodule PumbleAutomation.Executions.NodeRunner do
  @moduledoc """
  The one boundary between a claimed step and a typed runner outcome.

  A runner reads an immutable snapshot, talks only to injected adapters, and
  returns an `Outcome`. It never writes an execution row and it never enqueues
  a job. Unknown types are a compiler/runtime mismatch. Raised exceptions are
  caught here, classified `internal`, and returned as a retryable outcome so
  the worker can record them under engine policy.
  """

  alias PumbleAutomation.Connections.Resolver
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.NodeRegistry
  alias PumbleAutomation.Executions.Nodes.Approval
  alias PumbleAutomation.Executions.Nodes.Condition
  alias PumbleAutomation.Executions.Nodes.Delay
  alias PumbleAutomation.Executions.Nodes.HttpRequest
  alias PumbleAutomation.Executions.Nodes.Pumble
  alias PumbleAutomation.Executions.Nodes.Stop
  alias PumbleAutomation.Executions.Outcome

  @type adapter :: (input() -> {:ok, Outcome.t()} | {:error, Error.t()})

  @type input :: %{
          compiled_node: map(),
          context: map(),
          trigger_snapshot: map(),
          installation_id: Ecto.UUID.t(),
          run_mode: String.t(),
          effect_key: String.t(),
          attempt: %{id: Ecto.UUID.t(), number: pos_integer()},
          resolver: module(),
          adapters: %{optional(atom()) => adapter()}
        }

  @doc """
  Builds the runner input from an engine claim snapshot.

  Adapters default to the substitution points in this module. A test replaces
  `:pumble`, `:http`, or `:condition` without touching execution tables.
  """
  @spec input(map()) :: input()
  def input(snapshot) when is_map(snapshot) do
    %{
      compiled_node: snapshot.compiled_node,
      context: snapshot.context,
      trigger_snapshot: snapshot.trigger_snapshot,
      installation_id: snapshot.installation_id,
      run_mode: snapshot.run_mode,
      effect_key: snapshot.effect_key,
      attempt: %{id: snapshot.attempt_id, number: snapshot.attempt_number},
      resolver: Map.get(snapshot, :resolver) || Resolver,
      adapters: Map.merge(default_adapters(), Map.get(snapshot, :adapters) || %{})
    }
  end

  @doc "Evaluates `input` and returns a bounded, typed outcome."
  @spec run(input()) :: {:ok, Outcome.t()} | {:error, Error.t()}
  def run(input) when is_map(input) do
    node = input.compiled_node

    with {:ok, spec} <- NodeRegistry.spec(node.type),
         {:ok, outcome} <- evaluate(node.type, input) do
      bound(outcome, spec)
    end
  rescue
    exception -> {:ok, wrapped_exception(exception)}
  catch
    kind, reason -> {:ok, wrapped_throw(kind, reason)}
  end

  @doc "Sends compiled Pumble message, reply, DM, and reaction actions through the client."
  @spec default_pumble(input()) :: {:ok, Outcome.t()} | {:error, Error.t()}
  def default_pumble(input), do: Pumble.run(input)

  @doc "Sends compiled HTTP actions through the pinned SafeHttp transport."
  @spec default_http(input()) :: {:ok, Outcome.t()} | {:error, Error.t()}
  def default_http(input), do: HttpRequest.run(input)

  @doc "Evaluates typed predicates and returns the true or false edge."
  @spec default_condition(input()) :: {:ok, Outcome.t()} | {:error, Error.t()}
  def default_condition(input), do: Condition.run(input)

  defp default_adapters do
    %{
      pumble: &default_pumble/1,
      http: &default_http/1,
      condition: &default_condition/1
    }
  end

  defp evaluate(:delay, input), do: Delay.run(input)
  defp evaluate(:stop, input), do: Stop.run(input)
  defp evaluate(:approval, input), do: Approval.run(input)
  defp evaluate(:condition, input), do: adapter(input, :condition).(input)
  defp evaluate(:pumble_action, input), do: adapter(input, :pumble).(input)
  defp evaluate(:http_action, input), do: adapter(input, :http).(input)

  defp evaluate(type, _input) when is_atom(type) do
    {:error,
     Error.new(:internal, :unknown_node_type,
       message: "The compiled step names a type the runtime does not run.",
       details: %{type: inspect(type)}
     )}
  end

  defp bound(%Outcome{} = outcome, spec) do
    case Outcome.bound(outcome, spec.max_output_bytes) do
      {:ok, bounded} ->
        {:ok, bounded}

      {:error, %Error{code: :output_too_large}} ->
        resource_limit()

      {:error, _reason} = error ->
        error
    end
  end

  defp resource_limit do
    Outcome.new(%{
      kind: :permanent_error,
      error_class: "resource_limit",
      message: "The step output is too large."
    })
  end

  defp wrapped_exception(exception) do
    wrap_internal(%{"exception" => inspect(exception.__struct__)})
  end

  defp wrapped_throw(kind, _reason) do
    wrap_internal(%{"kind" => inspect(kind)})
  end

  defp wrap_internal(output) do
    {:ok, outcome} =
      Outcome.new(%{
        kind: :retryable_error,
        error_class: "internal",
        message: "The step failed internally.",
        output: output
      })

    case Outcome.bound(outcome, 16 * 1024) do
      {:ok, bounded} -> bounded
      {:error, _reason} -> outcome
    end
  end

  defp adapter(input, name) do
    Map.get(input.adapters || %{}, name) || Map.fetch!(default_adapters(), name)
  end
end
