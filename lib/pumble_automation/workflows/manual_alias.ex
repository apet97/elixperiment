defmodule PumbleAutomation.Workflows.ManualAlias do
  @moduledoc """
  The one syntax contract for a workflow's manual route name.

  A manual trigger stores this value in its definition and the workflow row
  projects it into `:slug`. Keeping normalization, validation, and form help in
  one module prevents those two representations from accepting different
  names.
  """

  alias PumbleAutomation.Error

  @max_length 64
  @format ~r/\A[a-z0-9][a-z0-9_-]*\z/
  @html_pattern "[a-z0-9][a-z0-9_-]*"
  @definition_path "/trigger/config/manual_alias"
  @message "Manual alias must be 1–64 characters, start with a lowercase letter or number, and contain only lowercase letters, numbers, hyphens, or underscores."

  @doc "The greatest accepted alias length."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc "The server-side alias format."
  @spec format() :: Regex.t()
  def format, do: @format

  @doc "The equivalent pattern for an HTML input."
  @spec html_pattern() :: String.t()
  def html_pattern, do: @html_pattern

  @doc "Actionable validation copy shared by API and forms."
  @spec message() :: String.t()
  def message, do: @message

  @doc "Trims an alias and represents blank text as no alias."
  @spec normalize(term()) :: term()
  def normalize(value) when is_binary(value) do
    if String.valid?(value) do
      case String.trim(value) do
        "" -> nil
        trimmed -> trimmed
      end
    else
      value
    end
  end

  def normalize(other), do: other

  @doc "Normalizes the manual alias in a plain definition before it is decoded."
  @spec normalize_definition(term()) :: term()
  def normalize_definition(
        %{
          "trigger" => %{
            "type" => "manual",
            "config" => %{} = config
          }
        } = definition
      )
      when not is_struct(config) do
    case Map.fetch(config, "manual_alias") do
      {:ok, value} -> put_in(definition, ["trigger", "config", "manual_alias"], normalize(value))
      :error -> definition
    end
  end

  def normalize_definition(definition), do: definition

  @doc "A typed local validation error, distinct from a database collision."
  @spec invalid_error() :: Error.t()
  def invalid_error do
    Error.new(:validation, :invalid_manual_alias, message: @message)
  end

  @doc "Turns an alias-only definition failure into the manual-alias domain error."
  @spec translate_definition_error(Error.t()) :: Error.t()
  def translate_definition_error(
        %Error{code: :invalid_definition, details: %{issues: issues}} = error
      )
      when is_list(issues) do
    if issues != [] and Enum.all?(issues, &manual_alias_issue?/1) do
      invalid_error()
    else
      error
    end
  end

  def translate_definition_error(%Error{} = error), do: error

  defp manual_alias_issue?(%{path: @definition_path}), do: true
  defp manual_alias_issue?(_issue), do: false
end
