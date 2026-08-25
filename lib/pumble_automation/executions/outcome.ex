defmodule PumbleAutomation.Executions.Outcome do
  @moduledoc """
  Named edges a step can take, and the next-node expectation each edge has.

  The compiler writes a flat graph whose outcomes are `"next"`, `"true"`,
  `"false"`, `"approved"`, `"rejected"`, and `"timed_out"`. A worker that
  finishes a step looks up one of those names and either continues at the
  node it names or stops at the `"end"` sentinel
  `PumbleAutomation.Workflows.CompiledWorkflow.end_target/0`. This module is
  that lookup, as data: it does not walk a stored graph and it does not
  write a row.

  Execution runners attach results to the same names. The kinds listed here
  are the finite set runners may return; they are not an extension
  point.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.StateMachine
  alias PumbleAutomation.Workflows.CompiledWorkflow
  alias PumbleAutomation.Workflows.Node

  @linear "next"
  @end_target CompiledWorkflow.end_target()

  @labels %{
    condition: ["false", "true"],
    approval: ["approved", "rejected", "timed_out"],
    delay: [@linear],
    pumble_action: [@linear],
    http_action: [@linear],
    stop: [@linear]
  }

  @kinds [
    :success,
    :wait_delay,
    :wait_approval,
    :retryable_error,
    :permanent_error,
    :uncertain,
    :cancelled
  ]

  @type kind ::
          :success
          | :wait_delay
          | :wait_approval
          | :retryable_error
          | :permanent_error
          | :uncertain
          | :cancelled

  @type t :: %__MODULE__{
          kind: kind(),
          edge: String.t() | nil,
          output: map(),
          resume_at: DateTime.t() | nil,
          error_class: String.t() | nil,
          message: String.t() | nil,
          remote_reference: String.t() | nil
        }

  @enforce_keys [:kind]
  defstruct [:kind, :edge, :resume_at, :error_class, :message, :remote_reference, output: %{}]

  @max_error_class 64
  @max_message 500
  @max_remote_reference 256

  @state_commands %{
    success: :complete,
    wait_delay: :wait_delay,
    wait_approval: :wait_approval,
    retryable_error: :retry,
    permanent_error: :fail,
    uncertain: :pause_uncertain,
    cancelled: :cancel
  }

  @attempt_commands %{
    success: :succeed,
    wait_delay: :succeed,
    wait_approval: :succeed,
    retryable_error: :fail,
    permanent_error: :fail,
    uncertain: :pause_uncertain,
    cancelled: :cancel
  }

  @doc "The outcome names a compiled node of `type` must write."
  @spec labels(Node.type() | String.t()) :: [String.t()]
  def labels(type) when is_atom(type), do: Map.get(@labels, type, [])

  def labels(type) when is_binary(type) do
    case Map.fetch(Node.types(), type) do
      {:ok, atom} -> labels(atom)
      :error -> []
    end
  end

  @doc "Whether `label` is an outcome of `type`."
  @spec label?(Node.type() | String.t(), term()) :: boolean()
  def label?(type, label) when is_binary(label), do: label in labels(type)
  def label?(_type, _label), do: false

  @doc "The linear outcome name (`next`)."
  @spec linear() :: String.t()
  def linear, do: @linear

  @doc "The edge target that means the run finishes."
  @spec terminal_target() :: String.t()
  def terminal_target, do: @end_target

  @doc "Whether `target` names a further node rather than the end of the run."
  @spec next_node_expected?(term()) :: boolean()
  def next_node_expected?(target) when is_binary(target) and target != "",
    do: target != terminal_target()

  def next_node_expected?(_target), do: false

  @doc "The runner-result kinds execution nodes may return."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The state-machine command an execution or step applies for `kind`."
  @spec state_command(kind()) :: StateMachine.command()
  def state_command(kind) when kind in @kinds, do: Map.fetch!(@state_commands, kind)

  @doc "The state-machine command an attempt applies for `kind`."
  @spec attempt_command(kind()) :: StateMachine.command()
  def attempt_command(kind) when kind in @kinds, do: Map.fetch!(@attempt_commands, kind)

  @doc """
  Follows `label` through a compiled node's `edges` map.

  Returns `{:ok, :end}` when the edge names the terminal sentinel, or
  `{:ok, {:continue, node_id}}` when it names a step. An unknown label is an
  internal defect: the compiler already required every outcome to be present.
  """
  @spec follow(%{String.t() => String.t()}, String.t()) ::
          {:ok, :end} | {:ok, {:continue, String.t()}} | {:error, Error.t()}
  def follow(edges, label) when is_map(edges) and is_binary(label) do
    case Map.fetch(edges, label) do
      {:ok, target} -> classify(target)
      :error -> {:error, unknown_label(label)}
    end
  end

  def follow(_edges, _label) do
    {:error, unknown_label(nil)}
  end

  @doc """
  Builds a runner outcome of a known kind.

  A `:success` result must name an `edge`. Other kinds may omit it. The
  struct is not persisted; the execution engine decides how it becomes a transition.
  """
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) do
    kind = attr(attrs, :kind)
    edge = attr(attrs, :edge)

    with :ok <- known_kind(kind),
         :ok <- success_edge(kind, edge) do
      {:ok,
       %__MODULE__{
         kind: kind,
         edge: edge,
         output: attr(attrs, :output) || %{},
         resume_at: attr(attrs, :resume_at),
         error_class: attr(attrs, :error_class),
         message: attr(attrs, :message),
         remote_reference: attr(attrs, :remote_reference)
       }}
    end
  end

  @doc """
  Bounds and scrubs a runner outcome so it is safe to persist.

  Secret-looking keys are dropped. Remaining values are redacted. An output
  larger than `max_bytes` is a resource-limit error, not a truncated document.
  A `:wait_delay` result must name `resume_at`.
  """
  @spec bound(t(), pos_integer()) :: {:ok, t()} | {:error, Error.t()}
  def bound(%__MODULE__{} = outcome, max_bytes)
      when is_integer(max_bytes) and max_bytes > 0 do
    with {:ok, output} <- bound_output(outcome.output, max_bytes),
         :ok <- wait_timestamp(outcome) do
      {:ok,
       %{
         outcome
         | output: output,
           error_class: clip(outcome.error_class, @max_error_class),
           message: clip(outcome.message, @max_message),
           remote_reference: clip(outcome.remote_reference, @max_remote_reference)
       }}
    end
  end

  defp known_kind(kind) when kind in @kinds, do: :ok

  defp known_kind(_kind) do
    {:error, invalid_outcome("The runner outcome is not one of the known kinds.")}
  end

  defp success_edge(:success, edge) when is_binary(edge), do: :ok

  defp success_edge(:success, _edge) do
    {:error, invalid_outcome("A successful outcome must name the edge it took.")}
  end

  defp success_edge(_kind, _edge), do: :ok

  defp bound_output(output, max_bytes) when is_map(output) and not is_struct(output) do
    scrubbed = scrub(output)

    if Execution.json_within?(scrubbed, max_bytes) do
      {:ok, scrubbed}
    else
      {:error,
       Error.new(:validation, :output_too_large, message: "The step output is too large.")}
    end
  end

  defp bound_output(_output, _max_bytes) do
    {:error, invalid_outcome("The runner output must be an object.")}
  end

  defp wait_timestamp(%__MODULE__{kind: :wait_delay, resume_at: %DateTime{}}), do: :ok

  defp wait_timestamp(%__MODULE__{kind: :wait_delay}) do
    {:error, invalid_outcome("A delay outcome must name the time to resume.")}
  end

  defp wait_timestamp(%__MODULE__{}), do: :ok

  defp scrub(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.reject(fn {key, _inner} -> secret_key?(key) end)
    |> Map.new(fn {key, inner} -> {key, scrub(inner)} end)
    |> Error.sanitize()
  end

  defp scrub(value) when is_list(value), do: Enum.map(value, &scrub/1)
  defp scrub(value), do: value

  defp secret_key?(key) when is_atom(key), do: key |> Atom.to_string() |> secret_key?()
  defp secret_key?(key) when is_binary(key), do: Regex.match?(Error.secret_key_pattern(), key)
  defp secret_key?(_key), do: false

  defp clip(nil, _max), do: nil

  defp clip(value, max) when is_binary(value) do
    value
    |> binary_part(0, min(byte_size(value), max))
    |> valid_prefix()
  end

  defp clip(_value, _max), do: nil

  defp valid_prefix(value) do
    case :unicode.characters_to_binary(value, :utf8, :utf8) do
      valid when is_binary(valid) -> valid
      {:incomplete, valid, _rest} -> valid
      {:error, valid, _rest} -> valid
    end
  end

  defp attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp classify(@end_target), do: {:ok, :end}

  defp classify(target) when is_binary(target) and target != "" do
    {:ok, {:continue, target}}
  end

  defp classify(_target) do
    {:error, invalid_outcome("The outcome edge does not name a step.")}
  end

  defp unknown_label(label) do
    Error.new(:internal, :unknown_outcome_label,
      message: "The compiled step does not name that outcome.",
      details: %{label: label}
    )
  end

  defp invalid_outcome(message) do
    Error.new(:validation, :invalid_outcome, message: message)
  end
end
