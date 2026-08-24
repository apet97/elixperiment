defmodule PumbleAutomation.Workflows.Node.Config do
  @moduledoc """
  The field engine every node and trigger configuration is described with.

  A configuration is a plain struct with a finite, declared field list. Each
  owning module returns that list from `fields/0`, and this module turns the
  list into a decoder and an encoder. Writing the field list once, instead of
  writing a decoder and an encoder per configuration, is what keeps the two
  directions from drifting apart, and it is what makes "the configuration is
  finite" a property of the data rather than a claim in a comment.

  ## Field descriptors

  A descriptor is `{name, kind, opts}`. The JSON key is the field name, so the
  wire shape is readable from the struct definition alone.

  Kinds:

    * `:string`, `:integer`, `:boolean` — scalars.
    * `{:enum, mapping}` — a *literal* map from the accepted string to an atom
      that already exists in the compiled module. This is the only way a string
      from user input becomes an atom anywhere in this engine, and the mapping
      is written out in source, so no atom can be created at run time.
    * `{:list, :string}` — an ordered list of strings.
    * `{:map, :string}` — a string-to-string map, such as HTTP headers.
    * `{:list, {:struct, module}}` — an ordered list of nested configurations.

  Options: `:required` (default `false`), `:default` (default `nil`),
  `:max_length` for strings, `:min` and `:max` for integers.

  ## Bounds

  Every string, list, and map is bounded by
  `PumbleAutomation.Workflows.Limits` *before* the value is placed in a struct.
  A payload that is too large is refused while it is still the caller's data,
  so a hostile input never becomes a term this application holds.

  ## Issues

  Decoding returns a list of issues rather than the first failure, because a
  form with three bad fields should light up three fields. An issue is
  `%{path: "/steps/0/config/url", reason: :invalid_type, message: "..."}`, where
  the path is a JSON pointer into the document the caller sent.
  """

  alias PumbleAutomation.Workflows.Limits

  @max_issues 50

  @type issue :: %{path: String.t(), reason: atom(), message: String.t()}

  @doc """
  Decodes `raw` into a struct of `module`, using that module's field list.
  """
  @spec decode(module(), term(), String.t()) :: {:ok, struct()} | {:error, [issue()]}
  def decode(module, raw, path) when is_map(raw) and not is_struct(raw) do
    if map_size(raw) > Limits.max_map_size() do
      {:error, [issue(path, :too_many_keys, "has too many fields")]}
    else
      decode_fields(module, raw, path)
    end
  end

  def decode(_module, _raw, path) do
    {:error, [issue(path, :invalid_type, "must be an object")]}
  end

  @doc """
  Encodes a configuration struct into a plain, string-keyed map.
  """
  @spec encode(struct()) :: map()
  def encode(%module{} = config) do
    Map.new(module.fields(), fn {name, kind, _opts} ->
      {Atom.to_string(name), encode_value(Map.fetch!(config, name), kind)}
    end)
  end

  @doc "Builds one decode issue."
  @spec issue(String.t(), atom(), String.t()) :: issue()
  def issue(path, reason, message), do: %{path: path, reason: reason, message: message}

  @doc """
  Appends a segment to a JSON pointer path.
  """
  @spec join(String.t(), String.t() | non_neg_integer()) :: String.t()
  def join(path, segment), do: path <> "/" <> to_string(segment)

  @doc "Refuses keys outside a closed wire schema without inspecting their values."
  @spec ensure_known_keys(map(), [String.t()], String.t()) :: :ok | {:error, [issue()]}
  def ensure_known_keys(raw, allowed, path)
      when is_map(raw) and is_list(allowed) and is_binary(path) do
    if map_size(raw) > Limits.max_map_size() do
      {:error, [issue(path, :too_many_keys, "has too many fields")]}
    else
      issues = unknown_key_issues(raw, MapSet.new(allowed), path)
      if issues == [], do: :ok, else: {:error, issues}
    end
  end

  defp decode_fields(module, raw, path) do
    allowed = Enum.map(module.fields(), fn {name, _kind, _opts} -> Atom.to_string(name) end)
    unknown_issues = unknown_key_issues(raw, MapSet.new(allowed), path)

    {values, issues} =
      Enum.reduce(
        module.fields(),
        {%{}, unknown_issues},
        fn {name, _kind, _opts} = field, {values, issues} ->
          case decode_field(field, raw, path) do
            {:ok, value} -> {Map.put(values, name, value), issues}
            {:error, new_issues} -> {values, issues ++ new_issues}
          end
        end
      )

    case issues do
      [] -> {:ok, struct(module, values)}
      _ -> {:error, issues}
    end
  end

  defp unknown_key_issues(raw, allowed, path) do
    raw
    |> Enum.reduce([], fn {key, _value}, issues ->
      if is_binary(key) and MapSet.member?(allowed, key) do
        issues
      else
        new_issue =
          issue(unknown_key_path(path, key), :unknown_field, "is not a declared field")

        [new_issue | issues]
        |> Enum.sort_by(& &1.path)
        |> Enum.take(@max_issues)
      end
    end)
  end

  defp unknown_key_path(path, key) when is_binary(key) do
    case safe_key(key) do
      "" -> path
      safe -> join(path, safe)
    end
  end

  defp unknown_key_path(path, _key), do: path

  defp safe_key(key) when is_binary(key) do
    if byte_size(key) <= Limits.max_string_length() and String.valid?(key), do: key, else: ""
  end

  defp decode_field({name, kind, opts}, raw, path) do
    field_path = join(path, Atom.to_string(name))

    case Map.get(raw, Atom.to_string(name)) do
      nil ->
        if Keyword.get(opts, :required, false) do
          {:error, [issue(field_path, :missing, "is required")]}
        else
          {:ok, Keyword.get(opts, :default)}
        end

      value ->
        decode_value(value, kind, opts, field_path)
    end
  end

  defp decode_value(value, :string, opts, path) when is_binary(value) do
    max =
      min(Keyword.get(opts, :max_length, Limits.max_string_length()), Limits.max_string_length())

    cond do
      byte_size(value) > max -> {:error, [issue(path, :too_long, "is too long")]}
      not String.valid?(value) -> {:error, [issue(path, :invalid_type, "must be valid text")]}
      true -> {:ok, value}
    end
  end

  defp decode_value(value, :integer, opts, path) when is_integer(value) do
    min = Keyword.get(opts, :min)
    max = Keyword.get(opts, :max)

    cond do
      is_integer(min) and value < min -> {:error, [issue(path, :out_of_range, "is too small")]}
      is_integer(max) and value > max -> {:error, [issue(path, :out_of_range, "is too large")]}
      true -> {:ok, value}
    end
  end

  defp decode_value(value, :boolean, _opts, _path) when is_boolean(value), do: {:ok, value}

  defp decode_value(value, {:enum, mapping}, _opts, path) when is_binary(value) do
    case Map.fetch(mapping, value) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, [issue(path, :unknown_value, "is not a supported value")]}
    end
  end

  defp decode_value(value, {:list, element}, opts, path) when is_list(value) do
    if length(value) > Limits.max_list_length() do
      {:error, [issue(path, :too_many_items, "has too many items")]}
    else
      decode_list(value, element, opts, path)
    end
  end

  defp decode_value(value, {:map, :string}, opts, path)
       when is_map(value) and not is_struct(value) do
    if map_size(value) > Limits.max_map_size() do
      {:error, [issue(path, :too_many_keys, "has too many entries")]}
    else
      decode_string_map(value, opts, path)
    end
  end

  defp decode_value(_value, _kind, _opts, path) do
    {:error, [issue(path, :invalid_type, "is the wrong type")]}
  end

  defp decode_list(value, element, opts, path) do
    {items, issues} =
      value
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {raw, index}, {items, issues} ->
        case decode_element(raw, element, opts, join(path, index)) do
          {:ok, item} -> {[item | items], issues}
          {:error, new_issues} -> {items, issues ++ new_issues}
        end
      end)

    case issues do
      [] -> {:ok, Enum.reverse(items)}
      _ -> {:error, issues}
    end
  end

  defp decode_element(raw, {:struct, module}, _opts, path), do: decode(module, raw, path)
  defp decode_element(raw, kind, opts, path), do: decode_value(raw, kind, opts, path)

  defp decode_string_map(value, opts, path) do
    {pairs, issues} =
      Enum.reduce(value, {%{}, []}, fn {key, entry}, {pairs, issues} ->
        entry_path = join(path, to_string(key))

        with true <- is_binary(key),
             {:ok, bounded_key} <- decode_value(key, :string, opts, entry_path),
             {:ok, bounded_value} <- decode_value(entry, :string, opts, entry_path) do
          {Map.put(pairs, bounded_key, bounded_value), issues}
        else
          false -> {pairs, issues ++ [issue(entry_path, :invalid_type, "must have text keys")]}
          {:error, new_issues} -> {pairs, issues ++ new_issues}
        end
      end)

    case issues do
      [] -> {:ok, pairs}
      _ -> {:error, issues}
    end
  end

  defp encode_value(nil, _kind), do: nil

  defp encode_value(value, {:enum, mapping}) do
    mapping |> Enum.find(fn {_string, atom} -> atom == value end) |> elem(0)
  end

  defp encode_value(value, {:list, {:struct, _module}}), do: Enum.map(value, &encode/1)
  defp encode_value(value, _kind), do: value
end
