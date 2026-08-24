defmodule PumbleAutomation.Executions.Nodes.Condition do
  @moduledoc """
  Evaluates a compiled condition and selects the true or false edge.

  The worker calls this through `PumbleAutomation.Executions.NodeRunner`.
  Predicates are already compiler-produced maps: this module never scans
  template text, never talks to the network, and never writes a row.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Context
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Workflows.Expressions

  @doc """
  Runs the compiled condition in `input` and returns one success edge.

  Evaluation errors become a permanent validation failure that names the
  field and path, not the compared values.
  """
  @spec run(map()) :: {:ok, Outcome.t()} | {:error, Error.t()}
  def run(input) when is_map(input) do
    tree =
      Context.tree(%{
        context: Map.get(input, :context) || %{},
        trigger_snapshot: Map.get(input, :trigger_snapshot) || %{}
      })

    case Expressions.evaluate(config(input), tree) do
      {:ok, result} -> success(result)
      {:error, %Error{} = error} -> failure(error)
    end
  end

  defp config(%{compiled_node: %{config: config}}) when is_map(config), do: config
  defp config(_input), do: %{}

  defp success(result) do
    matched = result.matched
    edge = if matched, do: "true", else: "false"

    Outcome.new(%{
      kind: :success,
      edge: edge,
      output: %{
        "matched" => matched,
        "combinator" => result.combinator,
        "reason" => result.decided
      }
    })
  end

  defp failure(%Error{} = error) do
    Outcome.new(%{
      kind: :permanent_error,
      error_class: "validation",
      message: error.message,
      output: failure_output(error)
    })
  end

  defp failure_output(%Error{details: details}) do
    %{}
    |> put_detail(details, :field, "field")
    |> put_detail(details, :path, "path")
  end

  defp put_detail(output, details, key, name) do
    case Map.get(details, key) || Map.get(details, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> Map.put(output, name, value)
      _missing -> output
    end
  end
end
