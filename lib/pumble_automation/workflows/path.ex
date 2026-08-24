defmodule PumbleAutomation.Workflows.Path do
  @moduledoc """
  Runtime resolution of compiler-produced data paths.

  Compile time already decided what a path may name
  (`PumbleAutomation.Workflows.Expressions`). This module only walks a
  prepared segment list against a JSON-like tree. It never parses a string
  of code, never turns a segment into an atom, and never reads a struct,
  a PID, a function, or a secret.

  ## What a path is

  A path is a list of segments the compiler already produced. The first
  segment is a documented root; the rest name keys or bounded list indices:

      ["trigger", "data", "text"]
      ["steps", node_id, "output", "ticket_id"]
      ["execution", "id"]

  Compiler maps from `PumbleAutomation.Workflows.Compiler` decode to that
  list. A step's compiled `path` is the subpath *below* `output`; decoding
  inserts that segment so resolution matches the grammar an author wrote.

  ## What a path may read

  Roots are `trigger`, `steps`, `execution`, `workspace`, and `actor`.
  `secret` is a real compile-time root, but its values are not in the run
  context: the owning action resolves them, and this module refuses.

  Walking accepts string-keyed maps and lists. It refuses structs, PIDs,
  functions, ports, references, and atoms that are not JSON scalars. A
  user segment is never converted to an atom, so a hostile path cannot
  grow the atom table or reach `__struct__`.

  ## Null versus missing

  A key that is present with value `nil` resolves to `nil`. A key that is
  absent is a typed missing error. Descending into `nil` is a type error:
  null is a value, not a map.

  ## Errors

  Every failure is `{:error, %PumbleAutomation.Error{}}`. Nothing here
  raises into a worker. The error names the safe path (`trigger.data.text`)
  and never interpolates the value that was found or missing.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Workflows.Limits

  @type segment :: String.t() | non_neg_integer()
  @type tree :: map()
  @type value :: term()

  @data_roots ~w(trigger steps execution workspace actor)
  @secret_root "secret"

  @doc """
  Turns a compiler path map into the segment list `resolve/2` walks.

  A step path always includes the `output` segment, even when the compiled
  map's `path` is empty: that empty list is the whole output of the step.
  """
  @spec from_compiled(term()) :: {:ok, [segment()]} | {:error, Error.t()}
  def from_compiled(%{"root" => @secret_root}), do: secret_error([@secret_root])

  def from_compiled(%{"root" => root, "node_id" => node_id, "path" => path})
      when root == "steps" and is_binary(node_id) do
    case decode_tail(path) do
      {:ok, tail} -> check_length(["steps", node_id, "output" | tail])
      {:error, _reason} = error -> error
    end
  end

  def from_compiled(%{"root" => root, "path" => path}) when root in @data_roots do
    case decode_tail(path) do
      {:ok, tail} -> check_length([root | tail])
      {:error, _reason} = error -> error
    end
  end

  def from_compiled(%{"root" => root}) when is_binary(root) and root not in @data_roots do
    unknown_root_error([root])
  end

  def from_compiled(_compiled), do: invalid_path_error([])

  @doc """
  Reads `path` from `tree`.

  `path` is either a compiler map or a segment list. `tree` is the
  JSON-like document `PumbleAutomation.Executions.Context.tree/1` builds.
  """
  @spec resolve(term(), term()) :: {:ok, value()} | {:error, Error.t()}
  def resolve(%{"root" => _} = compiled, tree) do
    with {:ok, segments} <- from_compiled(compiled) do
      resolve(segments, tree)
    end
  end

  def resolve(segments, tree) when is_list(segments) do
    with :ok <- validate_segments(segments),
         {:ok, segments} <- check_length(segments) do
      walk_root(segments, tree)
    end
  end

  def resolve(_path, _tree), do: invalid_path_error([])

  defp decode_tail(path) when is_list(path) do
    if Enum.all?(path, &allowed_segment?/1) do
      {:ok, path}
    else
      invalid_segment_error(["<compiled>" | Enum.map(path, &segment_text/1)])
    end
  end

  defp decode_tail(_path), do: invalid_path_error([])

  defp validate_segments([@secret_root | rest]), do: secret_error([@secret_root | rest])

  defp validate_segments(segments) do
    case Enum.find_index(segments, &(not allowed_segment?(&1))) do
      nil ->
        :ok

      index ->
        invalid_segment_error(Enum.take(segments, index + 1))
    end
  end

  defp allowed_segment?(segment) when is_binary(segment) and segment != "" do
    not String.starts_with?(segment, "_")
  end

  defp allowed_segment?(segment) when is_integer(segment) and segment >= 0, do: true
  defp allowed_segment?(_segment), do: false

  defp check_length(segments) do
    if length(segments) > Limits.max_path_segments() do
      too_long_error(segments)
    else
      {:ok, segments}
    end
  end

  defp walk_root([root | rest], tree) when root in @data_roots do
    cond do
      rest == [] ->
        invalid_segment_error([root])

      root == "steps" and too_short_step?(rest) ->
        invalid_segment_error([root | rest])

      not json_map?(tree) ->
        type_error([root])

      true ->
        case Map.fetch(tree, root) do
          {:ok, value} -> walk(rest, value, [root])
          :error -> missing_error([root])
        end
    end
  end

  defp walk_root([@secret_root | rest], _tree), do: secret_error([@secret_root | rest])
  defp walk_root([root | _rest], _tree) when is_binary(root), do: unknown_root_error([root])
  defp walk_root(segments, _tree), do: invalid_path_error(segments)

  defp too_short_step?([_id, "output" | _rest]), do: false
  defp too_short_step?(_rest), do: true

  defp walk([], value, seen) do
    if json_value?(value), do: {:ok, value}, else: type_error(seen)
  end

  defp walk([segment | rest], value, seen) do
    seen = seen ++ [segment]

    cond do
      json_map?(value) and is_binary(segment) ->
        fetch_key(value, segment, rest, seen)

      is_list(value) and is_integer(segment) ->
        fetch_index(value, segment, rest, seen)

      true ->
        type_error(seen)
    end
  end

  defp fetch_key(map, key, rest, seen) do
    case Map.fetch(map, key) do
      {:ok, value} -> walk(rest, value, seen)
      :error -> missing_error(seen)
    end
  end

  defp fetch_index(list, index, rest, seen) do
    if index < length(list) do
      walk(rest, Enum.at(list, index), seen)
    else
      missing_error(seen)
    end
  end

  defp json_map?(value) when is_map(value) and not is_struct(value), do: true
  defp json_map?(_value), do: false

  defp json_value?(value) when is_binary(value), do: true
  defp json_value?(value) when is_integer(value), do: true
  defp json_value?(value) when is_float(value), do: true
  defp json_value?(value) when is_boolean(value), do: true
  defp json_value?(nil), do: true
  defp json_value?(value) when is_list(value), do: true
  defp json_value?(value), do: json_map?(value)

  defp secret_error(segments) do
    {:error,
     error(
       :secret_not_in_context,
       "This path names a secret, which is not part of the run context.",
       segments
     )}
  end

  defp unknown_root_error(segments) do
    {:error, error(:unknown_root, "This path does not start at a documented root.", segments)}
  end

  defp invalid_path_error(segments) do
    {:error, error(:invalid_path, "This path is not a compiler-produced path.", segments)}
  end

  defp invalid_segment_error(segments) do
    {:error, error(:invalid_segment, "This path names a level that cannot be read.", segments)}
  end

  defp missing_error(segments) do
    {:error, error(:path_missing, "This path names a value that is not there.", segments)}
  end

  defp type_error(segments) do
    {:error, error(:path_type_mismatch, "This path cannot be read from that value.", segments)}
  end

  defp too_long_error(segments) do
    {:error, error(:path_too_long, "This path names too many levels.", segments)}
  end

  defp error(code, message, segments) do
    Error.new(:validation, code,
      message: message,
      details: %{path: format(segments)}
    )
  end

  defp format([]), do: ""
  defp format(segments), do: Enum.map_join(segments, ".", &segment_text/1)

  defp segment_text(segment) when is_binary(segment), do: segment
  defp segment_text(segment) when is_integer(segment), do: Integer.to_string(segment)
  defp segment_text(_segment), do: "?"
end
