defmodule PumbleAutomation.Executions.NodeRegistry do
  @moduledoc """
  The finite runtime catalog of compiled node types.

  The compiler's node types and this map are the same set. A worker looks up
  a type that is already an atom from `CompiledWorkflow.decode/1`. Nothing
  here turns a string from user data into an atom, and nothing here loads a
  module named by a workflow document.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.StepExecution
  alias PumbleAutomation.Pumble.Client
  alias PumbleAutomation.Workflows.Node

  @payload_bytes StepExecution.max_payload_bytes()
  @pure_bytes 16 * 1024

  @catalog %{
    condition: %{
      type: :condition,
      effect_class: :pure,
      retry_safety: :read_only,
      output_schema: %{type: :map},
      max_output_bytes: @pure_bytes
    },
    delay: %{
      type: :delay,
      effect_class: :wait,
      retry_safety: :read_only,
      output_schema: %{type: :map},
      max_output_bytes: @pure_bytes
    },
    approval: %{
      type: :approval,
      effect_class: :wait,
      retry_safety: :read_only,
      output_schema: %{type: :map},
      max_output_bytes: @pure_bytes
    },
    pumble_action: %{
      type: :pumble_action,
      effect_class: :pumble,
      retry_safety: :not_idempotent,
      output_schema: %{type: :map},
      max_output_bytes: @payload_bytes
    },
    http_action: %{
      type: :http_action,
      effect_class: :http,
      retry_safety: :not_idempotent,
      output_schema: %{type: :map},
      max_output_bytes: @payload_bytes
    },
    stop: %{
      type: :stop,
      effect_class: :pure,
      retry_safety: :read_only,
      output_schema: %{type: :map},
      max_output_bytes: @pure_bytes
    }
  }

  @type spec :: %{
          type: Node.type(),
          effect_class: :pure | :pumble | :http | :wait,
          retry_safety: Client.retry_safety(),
          output_schema: map(),
          max_output_bytes: pos_integer()
        }

  @doc "The compiled node types this registry knows, as atoms."
  @spec types() :: [Node.type()]
  def types, do: @catalog |> Map.keys() |> Enum.sort()

  @doc "The compiler's node types as atoms, in the same order as `types/0`."
  @spec compiler_types() :: [Node.type()]
  def compiler_types, do: Node.types() |> Map.values() |> Enum.sort()

  @doc "Looks up the contract for a compiled node type."
  @spec spec(Node.type() | String.t()) :: {:ok, spec()} | {:error, Error.t()}
  def spec(type) when is_atom(type) do
    case Map.fetch(@catalog, type) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, unknown_type(type)}
    end
  end

  def spec(type) when is_binary(type) do
    case Map.fetch(Node.types(), type) do
      {:ok, atom} -> spec(atom)
      :error -> {:error, unknown_type(type)}
    end
  end

  def spec(type), do: {:error, unknown_type(type)}

  defp unknown_type(type) do
    Error.new(:internal, :unknown_node_type,
      message: "The compiled step names a type the runtime does not run.",
      details: %{type: inspect(type)}
    )
  end
end
