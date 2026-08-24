defmodule PumbleAutomation.Workflows.HttpExtraction do
  @moduledoc """
  Bounded JSON response extraction using the workflow path grammar.

  There is no JSONPath engine. A field names a list of map keys and list
  indexes, or a dotted string of the same. Walking refuses structs, leading
  underscores, and paths longer than the documented segment cap. Extracted
  values stay JSON scalars, lists, and maps, and the whole result must fit
  the execution context budget.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Workflows.Limits

  @type path :: String.t() | [String.t() | non_neg_integer()]

  @doc "Reads each named path from a JSON body or already-decoded document."
  @spec extract(term(), map()) :: {:ok, map()} | {:error, Error.t()}
  def extract(source, fields) when is_map(fields) and not is_struct(fields) do
    with {:ok, document} <- document(source),
         {:ok, extracted} <- collect(fields, document) do
      bound(extracted)
    end
  end

  def extract(_source, _fields) do
    {:error, fail(:invalid_extraction, "HTTP extraction fields must be an object.")}
  end

  defp document(source) when is_binary(source) do
    case Jason.decode(source) do
      {:ok, value} ->
        acceptable(value)

      {:error, _reason} ->
        {:error, fail(:invalid_json, "The HTTP response body is not valid JSON.")}
    end
  end

  defp document(value) when is_map(value) and not is_struct(value), do: {:ok, value}
  defp document(value) when is_list(value), do: {:ok, value}

  defp document(_value) do
    {:error, fail(:invalid_json, "The HTTP response body is not valid JSON.")}
  end

  defp acceptable(value) when is_map(value) and not is_struct(value), do: {:ok, value}
  defp acceptable(value) when is_list(value), do: {:ok, value}

  defp acceptable(_value) do
    {:error, fail(:invalid_json, "The HTTP response body is not valid JSON.")}
  end

  defp collect(fields, document) do
    Enum.reduce_while(fields, {:ok, %{}}, fn pair, {:ok, acc} ->
      collect_one(pair, document, acc)
    end)
  end

  defp collect_one({name, path}, document, acc) when is_binary(name) and name != "" do
    case resolve(path, document) do
      {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
      {:error, %Error{}} = error -> {:halt, error}
    end
  end

  defp collect_one(_pair, _document, _acc) do
    {:halt, {:error, fail(:invalid_extraction, "HTTP extraction fields must be an object.")}}
  end

  defp resolve(path, document) do
    with {:ok, segments} <- segments(path) do
      walk(segments, document, [])
    end
  end

  defp segments(path) when is_binary(path) do
    path
    |> String.split(".", trim: false)
    |> decode_segments()
  end

  defp segments(path) when is_list(path), do: decode_segments(path)
  defp segments(_path), do: {:error, invalid_path([])}

  defp decode_segments(parts) do
    cond do
      parts == [] or parts == [""] ->
        {:error, invalid_path([])}

      length(parts) > Limits.max_path_segments() ->
        {:error, too_long(parts)}

      true ->
        decoded = Enum.map(parts, &decode_segment/1)

        if Enum.any?(decoded, &(&1 == :invalid)) do
          {:error, invalid_segment(parts)}
        else
          {:ok, decoded}
        end
    end
  end

  defp decode_segment(segment) when is_integer(segment) and segment >= 0, do: segment

  defp decode_segment(segment) when is_binary(segment) and segment != "" do
    cond do
      String.starts_with?(segment, "_") ->
        :invalid

      match?({_index, ""}, Integer.parse(segment)) and not String.starts_with?(segment, "-") and
          not leading_zero?(segment) ->
        {index, ""} = Integer.parse(segment)
        index

      true ->
        segment
    end
  end

  defp decode_segment(_segment), do: :invalid

  defp leading_zero?("0"), do: false
  defp leading_zero?(segment), do: String.starts_with?(segment, "0")

  defp walk([], value, seen) do
    if json_value?(value), do: {:ok, value}, else: type_error(seen)
  end

  defp walk([segment | rest], value, seen) do
    seen = seen ++ [segment]

    cond do
      json_map?(value) and is_binary(segment) -> fetch_key(value, segment, rest, seen)
      is_list(value) and is_integer(segment) -> fetch_index(value, segment, rest, seen)
      true -> type_error(seen)
    end
  end

  defp fetch_key(map, key, rest, seen) do
    case Map.fetch(map, key) do
      {:ok, value} -> walk(rest, value, seen)
      :error -> missing(seen)
    end
  end

  defp fetch_index(list, index, rest, seen) do
    if index < length(list) do
      walk(rest, Enum.at(list, index), seen)
    else
      missing(seen)
    end
  end

  defp bound(extracted) do
    if Execution.json_within?(extracted, Execution.max_context_bytes()) do
      {:ok, extracted}
    else
      {:error,
       Error.new(:validation, :output_too_large, message: "The HTTP extraction is too large.")}
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

  defp invalid_path(segments) do
    fail(:invalid_path, "This path is not a compiler-produced path.", segments)
  end

  defp invalid_segment(segments) do
    fail(:invalid_segment, "This path names a level that cannot be read.", segments)
  end

  defp too_long(segments) do
    fail(:path_too_long, "This path names too many levels.", segments)
  end

  defp missing(segments) do
    {:error, fail(:path_missing, "This path names a value that is not there.", segments)}
  end

  defp type_error(segments) do
    {:error, fail(:path_type_mismatch, "This path cannot be read from that value.", segments)}
  end

  defp fail(code, message, segments \\ []) do
    Error.new(:validation, code,
      message: message,
      details: drop_blank(%{path: format(segments)})
    )
  end

  defp format([]), do: nil
  defp format(segments), do: Enum.map_join(segments, ".", &segment_text/1)

  defp segment_text(segment) when is_binary(segment), do: segment
  defp segment_text(segment) when is_integer(segment), do: Integer.to_string(segment)
  defp segment_text(_segment), do: "?"

  defp drop_blank(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) or value == "" end)
  end
end
