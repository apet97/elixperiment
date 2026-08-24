defmodule PumbleAutomationWeb.WorkflowLive.NodeForms.Params do
  @moduledoc """
  Turns LiveView form params into the map `Node.Config.decode/3` expects.

  HTML posts strings, indexed maps, and checkbox lists. Decode still wants
  integers, booleans, string maps, and nested objects. This module is the
  only place that coercion happens, so a form cannot invent a field the
  configuration does not declare.
  """

  alias PumbleAutomation.Workflows.Node.Config

  @type issue :: Config.issue()

  @doc "Decodes `params` through `module.fields/0`."
  @spec decode(module(), map()) :: {:ok, struct()} | {:error, [issue()]}
  def decode(module, params) when is_atom(module) and is_map(params) do
    Config.decode(module, coerce(module, params), "")
  end

  @doc "A string-keyed map suitable for `to_form/2`, derived from a config struct."
  @spec form_params(struct()) :: map()
  def form_params(%module{} = config) do
    display(module, Config.encode(config))
  end

  @doc "Indexed or list rows under `key`, as a list of string-keyed maps."
  @spec rows(map(), String.t()) :: [map()]
  def rows(params, key) when is_map(params) and is_binary(key) do
    case Map.get(params, key) do
      list when is_list(list) -> Enum.map(list, &row_map/1)
      map when is_map(map) -> Enum.map(indexed_values(map), &row_map/1)
      _other -> []
    end
  end

  @doc "Joins a list field for a textarea or comma-separated input."
  @spec joined(map(), String.t(), String.t()) :: String.t()
  def joined(params, key, separator) when is_map(params) do
    params
    |> Map.get(key)
    |> coerce_string_list()
    |> Enum.join(separator)
  end

  @doc "Keyword errors `to_form/2` understands, keyed by declared fields only."
  @spec form_errors(module(), [map()]) :: keyword()
  def form_errors(module, issues) when is_list(issues) do
    allowed =
      Map.new(module.fields(), fn {name, _kind, _opts} -> {Atom.to_string(name), name} end)

    issues
    |> Enum.flat_map(&field_error(&1, allowed))
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp coerce(module, params) do
    raw = stringify_keys(params)

    Map.new(module.fields(), fn {name, kind, _opts} ->
      key = Atom.to_string(name)
      {key, coerce_value(kind, Map.get(raw, key))}
    end)
  end

  defp display(module, encoded) do
    Map.new(module.fields(), fn {name, kind, _opts} ->
      key = Atom.to_string(name)
      {key, display_value(kind, Map.get(encoded, key))}
    end)
  end

  defp coerce_value(:string, value), do: blank_to_nil(value)
  defp coerce_value(:integer, value), do: coerce_integer(value)
  defp coerce_value(:boolean, value), do: coerce_boolean(value)
  defp coerce_value({:enum, _mapping}, value), do: blank_to_nil(value)
  defp coerce_value({:list, :string}, value), do: coerce_string_list(value)
  defp coerce_value({:map, :string}, value), do: coerce_string_map(value)
  defp coerce_value({:list, {:struct, nested}}, value), do: coerce_struct_list(nested, value)
  defp coerce_value(_kind, value), do: value

  defp display_value({:map, :string}, value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.with_index()
    |> Map.new(fn {{name, entry}, index} ->
      {Integer.to_string(index), %{"name" => name, "value" => entry}}
    end)
  end

  defp display_value({:list, {:struct, _module}}, value) when is_list(value) do
    value
    |> Enum.with_index()
    |> Map.new(fn {item, index} -> {Integer.to_string(index), stringify_keys(item)} end)
  end

  defp display_value({:list, :string}, value) when is_list(value), do: value
  defp display_value(_kind, nil), do: nil
  defp display_value(_kind, value), do: value

  defp coerce_integer(nil), do: nil
  defp coerce_integer(value) when is_integer(value), do: value

  defp coerce_integer(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {number, ""} -> number
      _other -> if(trimmed == "", do: nil, else: value)
    end
  end

  defp coerce_integer(value), do: value

  defp coerce_boolean(true), do: true
  defp coerce_boolean(false), do: false
  defp coerce_boolean("true"), do: true
  defp coerce_boolean("false"), do: false
  defp coerce_boolean(_value), do: nil

  defp coerce_string_list(nil), do: []
  defp coerce_string_list(value) when is_list(value), do: Enum.map(value, &blank_to_nil/1)

  defp coerce_string_list(value) when is_binary(value) do
    value
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp coerce_string_list(value) when is_map(value) do
    value
    |> indexed_values()
    |> Enum.map(&blank_to_nil/1)
    |> Enum.reject(&is_nil/1)
  end

  defp coerce_string_list(_value), do: []

  defp coerce_string_map(nil), do: %{}

  defp coerce_string_map(value) when is_map(value) and not is_struct(value) do
    if header_rows?(value) do
      value
      |> indexed_values()
      |> Enum.reduce(%{}, &put_header/2)
    else
      Map.new(value, fn {key, entry} -> {to_string(key), blank_to_nil(entry)} end)
    end
  end

  defp coerce_string_map(value) when is_list(value) do
    Enum.reduce(value, %{}, &put_header/2)
  end

  defp coerce_string_map(_value), do: %{}

  defp header_rows?(value) do
    value
    |> Map.values()
    |> Enum.any?(fn
      inner when is_map(inner) -> Map.has_key?(stringify_keys(inner), "name")
      _other -> false
    end)
  end

  defp put_header(row, acc) when is_map(row) do
    inner = stringify_keys(row)
    name = inner |> Map.get("name", "") |> to_string() |> String.trim()
    entry = inner |> Map.get("value", "") |> to_string()

    if name == "", do: acc, else: Map.put(acc, name, entry)
  end

  defp put_header(_row, acc), do: acc

  defp coerce_struct_list(module, value) do
    value
    |> indexed_values()
    |> Enum.map(&coerce(module, stringify_keys(&1)))
  end

  defp row_map(row) when is_map(row), do: stringify_keys(row)
  defp row_map(_row), do: %{}

  defp indexed_values(nil), do: []
  defp indexed_values(list) when is_list(list), do: list

  defp indexed_values(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> sort_index(key) end)
    |> Enum.map(&elem(&1, 1))
  end

  defp indexed_values(_value), do: []

  defp sort_index(key) when is_integer(key), do: key

  defp sort_index(key) when is_binary(key) do
    case Integer.parse(key) do
      {number, ""} -> number
      _other -> 0
    end
  end

  defp sort_index(_key), do: 0

  defp stringify_keys(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_keys(map) when is_map(map), do: Map.new()
  defp stringify_keys(_other), do: %{}

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp field_error(%{path: path, message: message, reason: reason}, allowed)
       when is_binary(path) do
    wrap_error(relative_segment(path), message, reason, allowed)
  end

  defp field_error(%{path: path, message: message, code: code}, allowed)
       when is_binary(path) do
    wrap_error(relative_segment(path), message, code, allowed)
  end

  defp field_error(_issue, _allowed), do: []

  defp wrap_error(segment, message, code, allowed) do
    case Map.fetch(allowed, segment) do
      {:ok, field} -> [{field, {message, [code: code]}}]
      :error -> []
    end
  end

  defp relative_segment(path) do
    rest =
      case String.split(path, "/config/", parts: 2) do
        [_prefix, relative] -> relative
        _other -> String.trim_leading(path, "/")
      end

    rest |> String.split("/") |> List.first() |> to_string()
  end
end
