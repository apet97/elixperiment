defmodule PumbleAutomation.Executions.Nodes.Delay do
  @moduledoc """
  Resolves a bounded wait and names the instant the run may continue.

  The worker calls this through `PumbleAutomation.Executions.NodeRunner` when
  the delay step is first claimed. Duration is a whole number of seconds,
  either the compiled integer or a template that renders to one. The bounds
  are 1 second through 365 days. Nothing here sleeps, starts a timer, or
  writes a row: `resume_at` is what the engine stores and schedules.

  A later wake job must not call `run/1` again. That would wait twice.
  `resume/1` continues along the linear edge using the output already
  stored on the waiting step.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Context
  alias PumbleAutomation.Executions.Outcome
  alias PumbleAutomation.Workflows.Node.DelayConfig
  alias PumbleAutomation.Workflows.Templates

  @min_seconds 1

  @doc """
  Returns a wait until `now + duration`, or a permanent validation failure.

  `duration_seconds` may be a compiled integer or a compiler-produced
  template. A missing, non-numeric, fractional, or out-of-range value is
  permanent. Secrets are not read: a secret placeholder cannot be a duration.
  """
  @spec run(map()) :: {:ok, Outcome.t()} | {:error, Error.t()}
  def run(input) when is_map(input) do
    tree =
      Context.tree(%{
        context: Map.get(input, :context) || %{},
        trigger_snapshot: Map.get(input, :trigger_snapshot) || %{}
      })

    case resolve_duration(config(input)["duration_seconds"], tree) do
      {:ok, seconds} -> wait(seconds)
      {:error, %Error{} = error} -> failure(error)
    end
  end

  @doc """
  Continues a delay whose scheduled wait has already elapsed.

  The duration is not resolved again. Output is the summary already merged
  into context when the step began waiting, so a second wait cannot appear.
  """
  @spec resume(map()) :: {:ok, Outcome.t()} | {:error, Error.t()}
  def resume(snapshot) when is_map(snapshot) do
    Outcome.new(%{
      kind: :success,
      edge: Outcome.linear(),
      output: stored_output(snapshot)
    })
  end

  defp wait(seconds) do
    resume_at = DateTime.add(DateTime.utc_now(), seconds, :second)

    Outcome.new(%{
      kind: :wait_delay,
      edge: Outcome.linear(),
      resume_at: resume_at,
      output: %{
        "wait_seconds" => seconds,
        "resume_at" => DateTime.to_iso8601(resume_at)
      }
    })
  end

  defp resolve_duration(seconds, _tree) when is_integer(seconds), do: validate_seconds(seconds)

  defp resolve_duration(seconds, _tree) when is_float(seconds) do
    truncated = trunc(seconds)

    if seconds == truncated do
      validate_seconds(truncated)
    else
      {:error, invalid_duration()}
    end
  end

  defp resolve_duration(%{"template" => _segments} = compiled, tree) do
    case Templates.render(compiled, tree, insert: :json) do
      {:ok, %{value: value}} -> decode_rendered(value)
      {:error, %Error{} = error} -> {:error, with_field(error, "duration_seconds")}
    end
  end

  defp resolve_duration(text, _tree) when is_binary(text), do: parse_seconds_text(text)
  defp resolve_duration(nil, _tree), do: {:error, missing_duration()}
  defp resolve_duration(_other, _tree), do: {:error, invalid_duration()}

  defp decode_rendered(value) when is_integer(value), do: validate_seconds(value)

  defp decode_rendered(value) when is_float(value) do
    resolve_duration(value, %{})
  end

  defp decode_rendered(value) when is_binary(value), do: parse_seconds_text(value)
  defp decode_rendered(_other), do: {:error, invalid_duration()}

  defp parse_seconds_text(text) do
    case Integer.parse(String.trim(text)) do
      {seconds, ""} -> validate_seconds(seconds)
      _other -> {:error, invalid_duration()}
    end
  end

  defp validate_seconds(seconds) when is_integer(seconds) and seconds >= @min_seconds do
    if seconds <= DelayConfig.max_seconds() do
      {:ok, seconds}
    else
      {:error, overflow_duration()}
    end
  end

  defp validate_seconds(seconds) when is_integer(seconds) do
    {:error, overflow_duration()}
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

  defp stored_output(snapshot) do
    node_id = Map.get(snapshot, :node_id)
    context = Map.get(snapshot, :context) || %{}

    case get_in(context, ["steps", node_id, "output"]) do
      output when is_map(output) -> output
      _missing -> %{}
    end
  end

  defp missing_duration do
    Error.new(:validation, :invalid_delay_duration,
      message: "The delay step does not name a duration."
    )
  end

  defp invalid_duration do
    Error.new(:validation, :invalid_delay_duration,
      message: "The delay duration is not a whole number of seconds.",
      details: %{field: "duration_seconds"}
    )
  end

  defp overflow_duration do
    Error.new(:validation, :delay_duration_overflow,
      message: "The delay duration must be between 1 second and 365 days.",
      details: %{field: "duration_seconds"}
    )
  end

  defp with_field(%Error{} = error, field) do
    %{error | details: Map.put(error.details, :field, field)}
  end

  defp config(%{compiled_node: %{config: config}}) when is_map(config), do: config
  defp config(_input), do: %{}
end
