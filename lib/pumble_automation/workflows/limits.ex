defmodule PumbleAutomation.Workflows.Limits do
  @moduledoc """
  The structural limits every workflow definition obeys.

  These values are the canonical validation limits. They live here, once,
  because the decoder, the persistence layer, and every editing primitive must
  agree on them: a limit copied into several places can be bypassed when one
  copy drifts.

  Two families of limit are defined:

    * *structural* limits describe a whole definition — node count, branch
      depth, serialized size. `PumbleAutomation.Workflows.Definition.validate_limits/1`
      composes the checks below, and every editing primitive runs it on the
      finished result rather than on an intermediate state.
    * *decode* limits bound one untrusted value while it is being read —
      string length, list length, map size, nesting depth of raw JSON. They
      exist so that a hostile payload is refused before any structure is built
      from it, not after.

  Limits are operational safety defaults, not commercial plan limits.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Limits, as: Catalog

  # Decode bounds. A definition that respects the structural limits cannot come
  # close to these, so they only ever fire on input that was never a workflow.
  @max_list_length 64
  @max_map_size 64
  @max_json_depth 64

  # Expression bounds for template source and expansion.
  @max_path_segments 16
  @max_template_references 32
  @max_template_value_bytes 2 * 1024

  @doc "The greatest number of nodes one definition may contain."
  @spec max_nodes() :: pos_integer()
  def max_nodes, do: Catalog.get(:workflow_nodes)

  @doc "The greatest branch nesting depth one definition may reach."
  @spec max_depth() :: pos_integer()
  def max_depth, do: Catalog.get(:branch_depth)

  @doc "The greatest serialized size, in bytes, of one definition."
  @spec max_definition_bytes() :: pos_integer()
  def max_definition_bytes, do: Catalog.get(:definition_size_bytes)

  @doc "The greatest length, in bytes, of one string read from user input."
  @spec max_string_length() :: pos_integer()
  def max_string_length, do: Catalog.get(:template_source_bytes)

  @doc "The greatest number of elements in one list read from user input."
  @spec max_list_length() :: pos_integer()
  def max_list_length, do: @max_list_length

  @doc "The greatest number of keys in one map read from user input."
  @spec max_map_size() :: pos_integer()
  def max_map_size, do: @max_map_size

  @doc "The greatest nesting depth of raw decoded JSON read from user input."
  @spec max_json_depth() :: pos_integer()
  def max_json_depth, do: @max_json_depth

  @doc "The greatest number of segments one data path may name."
  @spec max_path_segments() :: pos_integer()
  def max_path_segments, do: @max_path_segments

  @doc "The greatest number of references one template may interpolate."
  @spec max_template_references() :: pos_integer()
  def max_template_references, do: @max_template_references

  @doc "The greatest size, in bytes, of a template's source text."
  @spec max_template_source() :: pos_integer()
  def max_template_source, do: Catalog.get(:template_source_bytes)

  @doc "The greatest size, in bytes, of one interpolated value."
  @spec max_template_value() :: pos_integer()
  def max_template_value, do: @max_template_value_bytes

  @doc "The greatest size, in bytes, of a rendered template."
  @spec max_template_expansion() :: pos_integer()
  def max_template_expansion, do: Catalog.get(:template_expansion_bytes)

  @doc """
  Checks that an encoded definition serializes within the size limit.

  Takes the plain map produced by encoding, so that the size checked is the
  size that will be written to the database.
  """
  @spec check_size(map()) :: :ok | {:error, Error.t()}
  def check_size(encoded) when is_map(encoded) do
    limit = max_definition_bytes()

    case Jason.encode(encoded) do
      {:ok, json} when byte_size(json) <= limit ->
        :ok

      {:ok, json} ->
        {:error,
         error(:definition_too_large, "The workflow definition is too large.", %{
           limit: limit,
           actual: byte_size(json)
         })}

      {:error, _reason} ->
        {:error,
         error(:definition_not_serializable, "The workflow definition cannot be serialized.", %{})}
    end
  end

  @doc "Checks a node count against the node limit."
  @spec check_nodes(non_neg_integer()) :: :ok | {:error, Error.t()}
  def check_nodes(count) when is_integer(count) and count >= 0 do
    limit = max_nodes()

    if count <= limit do
      :ok
    else
      {:error,
       error(:too_many_nodes, "The workflow has too many steps.", %{
         limit: limit,
         actual: count
       })}
    end
  end

  @doc "Checks a branch depth against the depth limit."
  @spec check_depth(non_neg_integer()) :: :ok | {:error, Error.t()}
  def check_depth(depth) when is_integer(depth) and depth >= 0 do
    limit = max_depth()

    if depth <= limit do
      :ok
    else
      {:error,
       error(:branch_too_deep, "The workflow branches are nested too deeply.", %{
         limit: limit,
         actual: depth
       })}
    end
  end

  @doc "Checks that no node identifier appears twice in a definition."
  @spec check_unique_ids([String.t()]) :: :ok | {:error, Error.t()}
  def check_unique_ids(ids) do
    duplicates = ids -- Enum.uniq(ids)

    if duplicates == [] do
      :ok
    else
      {:error,
       error(:duplicate_node_ids, "The workflow contains duplicate step identifiers.", %{
         count: length(Enum.uniq(duplicates))
       })}
    end
  end

  defp error(code, message, details) do
    Error.new(:validation, code, message: message, details: details)
  end
end
