defmodule PumbleAutomation.Executions.Nodes.Stop do
  @moduledoc """
  Ends a compiled run with a bounded, already-safe reason.

  The worker calls this through `PumbleAutomation.Executions.NodeRunner`.
  The reason is the configured text after template rendering: secrets stay
  write-only placeholders, and compared values never appear in the error
  message when rendering fails.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Context
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Workflows.Templates

  @default_reason "done"
  @max_reason 1024

  @doc """
  Returns terminal success along the linear edge.

  A missing or empty reason becomes `#{@default_reason}`. A reason that
  cannot render as text is a permanent validation failure.
  """
  @spec run(map()) :: {:ok, Outcome.t()} | {:error, Error.t()}
  def run(input) when is_map(input) do
    tree =
      Context.tree(%{
        context: Map.get(input, :context) || %{},
        trigger_snapshot: Map.get(input, :trigger_snapshot) || %{}
      })

    case render_reason(config(input)["reason"], tree) do
      {:ok, reason} -> success(reason)
      {:error, %Error{} = error} -> failure(error)
    end
  end

  defp render_reason(reason, _tree) when reason in [nil, ""], do: {:ok, @default_reason}

  defp render_reason(compiled, tree) do
    case Templates.render(compiled, tree) do
      {:ok, %{value: reason}} when is_binary(reason) -> {:ok, clip(reason)}
      {:ok, %{value: _other}} -> {:error, invalid_reason()}
      {:error, %Error{} = error} -> {:error, with_field(error, "reason")}
    end
  end

  defp success(reason) do
    Outcome.new(%{
      kind: :success,
      edge: Outcome.linear(),
      output: %{"reason" => reason}
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

  defp put_detail(output, details, key, name) when is_map(details) do
    case Map.get(details, key) || Map.get(details, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> Map.put(output, name, value)
      _missing -> output
    end
  end

  defp clip(reason) do
    reason
    |> binary_part(0, min(byte_size(reason), @max_reason))
    |> valid_prefix()
  end

  defp valid_prefix(value) do
    case :unicode.characters_to_binary(value, :utf8, :utf8) do
      valid when is_binary(valid) -> valid
      {:incomplete, valid, _rest} -> valid
      {:error, valid, _rest} -> valid
    end
  end

  defp invalid_reason do
    Error.new(:validation, :invalid_stop_reason, message: "The stop reason must render as text.")
  end

  defp with_field(%Error{} = error, field) do
    %{error | details: Map.put(error.details, :field, field)}
  end

  defp config(%{compiled_node: %{config: config}}) when is_map(config), do: config
  defp config(_input), do: %{}
end
