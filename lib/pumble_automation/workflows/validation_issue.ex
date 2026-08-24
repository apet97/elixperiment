defmodule PumbleAutomation.Workflows.ValidationIssue do
  @moduledoc """
  One finding from `PumbleAutomation.Workflows.Validator`.

  An issue names what is wrong (`:code`), how much it matters (`:severity`),
  which step it belongs to (`:node_id`), where in the document it sits
  (`:path`), and what to tell the author (`:message`). Those five fields are
  the whole shape, and they are what a form needs to put a message next to a
  field.

  ## Severity decides activation

  `:error` blocks activation. `:warning` never does: a warning is for a
  workflow that will run and may still not be what its author meant, such as a
  step placed after a stop. Anything that would make a run impossible, or make
  it read data that is not there, is an error.

  ## Messages carry no user content

  Every message is a fixed sentence chosen by the code. None of them
  interpolates a value from the definition, so an issue can be logged, shown,
  and stored without carrying a channel name, a token, or anything else the
  author typed. The `:path` says where to look; the message says what is
  wrong.

  ## Ordering is part of the contract

  `sort/1` puts errors before warnings, then orders by document path and code.
  The key is total and uses no term whose order can change between runs, so
  the same definition produces the same list in the same order every time —
  which is what lets a test compare issue lists and a screen avoid reshuffling
  under the reader.
  """

  @type severity :: :error | :warning

  @type t :: %__MODULE__{
          code: atom(),
          severity: severity(),
          node_id: String.t() | nil,
          path: String.t(),
          message: String.t()
        }

  @enforce_keys [:code, :severity, :path, :message]
  defstruct [:code, :severity, :node_id, :path, :message]

  @severity_rank %{error: 0, warning: 1}

  @doc "Builds a blocking issue."
  @spec error(atom(), String.t(), String.t(), String.t() | nil) :: t()
  def error(code, path, message, node_id \\ nil) do
    %__MODULE__{code: code, severity: :error, node_id: node_id, path: path, message: message}
  end

  @doc "Builds a non-blocking issue."
  @spec warning(atom(), String.t(), String.t(), String.t() | nil) :: t()
  def warning(code, path, message, node_id \\ nil) do
    %__MODULE__{code: code, severity: :warning, node_id: node_id, path: path, message: message}
  end

  @doc "Orders issues into the one sequence every caller sees."
  @spec sort([t()]) :: [t()]
  def sort(issues) when is_list(issues), do: Enum.sort_by(issues, &sort_key/1)

  @doc "The issues that block activation."
  @spec errors([t()]) :: [t()]
  def errors(issues) when is_list(issues), do: Enum.filter(issues, &(&1.severity == :error))

  @doc "Whether any issue blocks activation."
  @spec errors?([t()]) :: boolean()
  def errors?(issues) when is_list(issues), do: Enum.any?(issues, &(&1.severity == :error))

  # Atoms are compared by identity rather than by text, so the code is sorted
  # as a string: an ordering that depends on when an atom was created is not an
  # ordering a test may rely on.
  defp sort_key(%__MODULE__{} = issue) do
    {
      Map.fetch!(@severity_rank, issue.severity),
      issue.path,
      Atom.to_string(issue.code),
      issue.node_id || ""
    }
  end
end
