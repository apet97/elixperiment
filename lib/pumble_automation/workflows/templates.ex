defmodule PumbleAutomation.Workflows.Templates do
  @moduledoc """
  The workflow template syntax and the runtime that evaluates the form the
  compiler stored.

  A template is text with `{{ path }}` references in it:

      Deploy of {{ trigger.data.text }} finished as {{ steps.<uuid>.output.status }}

  `parse/1` splits that into literals and parsed references. It runs at edit
  time. `render/3` walks the compiler-produced segments against a JSON tree.
  It never scans template text: a plain string is a finished value, and a
  `%{"template" => segments}` map is already literals and paths.

  ## Scanning, not matching

  The scanner walks the binary with `:binary.match/2` looking for `{{` and
  then `}}`. It is not a regular expression, so there is no pattern a hostile
  template can make backtrack: the work is linear in the length of the text,
  once.

  Text that is not a reference is a literal, including a lone `{`, a lone `}`,
  and a `}}` that never had a `{{`. Only `{{` starts a reference, and a `{{`
  with no `}}` after it is an error rather than a literal, because silently
  treating it as text is how an author ends up sending the word "trigger" to a
  channel.

  ## Rendering

  String interpolation converts scalars with no locale and no timezone:
  strings as-is, integers as decimal digits, floats as JSON numbers,
  booleans as `true`/`false`, and null as `null`. Arrays and objects are
  not stringified. They require explicit JSON insertion: a `%{"json" => path}`
  segment, or `insert: :json` for a JSON field.

  JSON insertion of a template that is only one reference returns the native
  JSON value. JSON insertion into surrounding text splices the canonical
  JSON encoding of the value, so quotes and control characters are escaped
  and object keys are sorted.

  Missing values fail by default. `on_missing: :empty` and `on_missing: :null`
  exist for fields whose schema permits them; this module does not look up
  a field schema.

  Secrets are not read. A secret segment becomes a write-only placeholder
  (`secret_placeholder/1`, or `%{"secret" => name}` when the whole JSON
  field is that secret). `used_paths` names `secret.NAME` and never a value.

  ## Bounds

  A template may interpolate at most
  `PumbleAutomation.Workflows.Limits.max_template_references/0` references.
  Source text is bounded by `Limits.max_template_source/0`, each interpolated
  value by `Limits.max_template_value/0`, and the finished expansion by
  `Limits.max_template_expansion/0`.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Workflows.Expressions
  alias PumbleAutomation.Workflows.Limits
  alias PumbleAutomation.Workflows.Path

  @open "{{"
  @close "}}"
  @secret_placeholder_prefix "{{secret."
  @secret_placeholder_suffix "}}"

  @type segment :: {:literal, String.t()} | {:reference, Expressions.t()}

  @type reason ::
          :unterminated_reference
          | :empty_reference
          | :too_many_references
          | :invalid_type
          | Expressions.reason()

  @type result :: %{value: term(), used_paths: [String.t()]}

  @doc """
  Parses `template` into its segments and the reasons it is not valid.

  Both halves are always returned, because one malformed reference must not
  hide the rest: a field holding `{{ steps.<gone>.output.x }} {{ unclosed`
  names a step that does not exist *and* never closes, and an author fixing
  one of those should not then be told about the other.

  Every reason is returned, deduplicated and in the order the scanner met
  them. A template over the reference bound returns no segments at all, so
  nothing downstream expands work the bound exists to prevent.
  """
  @spec parse(term()) :: {[segment()], [reason()]}
  def parse(template) when is_binary(template) do
    {segments, reasons} = scan(template, [], [])

    bounded(segments, reasons |> Enum.reverse() |> Enum.uniq())
  end

  def parse(_template), do: {[], [:invalid_type]}

  @doc "The parsed references among `segments`, in the order they appear."
  @spec references([segment()]) :: [Expressions.t()]
  def references(segments) when is_list(segments) do
    for {:reference, reference} <- segments, do: reference
  end

  @doc """
  Renders a compiler-produced template against a JSON tree.

  `compiled` is either a plain string (nothing to interpolate) or
  `%{"template" => segments}` whose segments are `%{"literal" => text}`,
  `%{"path" => compiled_path}`, or `%{"json" => compiled_path}`.

  Options:

    * `:on_missing` — `:error` (default), `:empty`, or `:null`.
    * `:insert` — `:string` (default) or `:json`.

  The successful result is the rendered value and the paths that were
  read, as safe dotted strings, with no resolved values.
  """
  @spec render(term(), term(), keyword()) :: {:ok, result()} | {:error, Error.t()}
  def render(compiled, tree, opts \\ [])

  def render(text, _tree, opts) when is_binary(text) do
    with :ok <- options(opts),
         :ok <- source_size(text) do
      done(text, [])
    end
  end

  def render(%{"template" => segments}, tree, opts) when is_list(segments) do
    with :ok <- options(opts),
         :ok <- source_segments(segments),
         :ok <- reference_count(segments) do
      evaluate(segments, tree, opts)
    end
  end

  def render(_compiled, _tree, _opts) do
    {:error, invalid_template_error()}
  end

  @doc """
  The write-only placeholder interpolated for a secret name.

  It contains the name and never a value. The owning action substitutes the
  secret at the last moment.
  """
  @spec secret_placeholder(String.t()) :: String.t()
  def secret_placeholder(name) when is_binary(name) do
    @secret_placeholder_prefix <> name <> @secret_placeholder_suffix
  end

  defp scan(rest, acc, reasons) do
    case :binary.match(rest, @open) do
      :nomatch -> {finish(rest, acc), reasons}
      {start, _length} -> open(rest, start, acc, reasons)
    end
  end

  defp finish("", acc), do: Enum.reverse(acc)
  defp finish(literal, acc), do: Enum.reverse([{:literal, literal} | acc])

  defp open(rest, start, acc, reasons) do
    acc = literal(binary_part(rest, 0, start), acc)
    tail = binary_part(rest, start + 2, byte_size(rest) - start - 2)

    case :binary.match(tail, @close) do
      :nomatch -> {Enum.reverse(acc), [:unterminated_reference | reasons]}
      {stop, _length} -> close(tail, stop, acc, reasons)
    end
  end

  defp close(tail, stop, acc, reasons) do
    inner = tail |> binary_part(0, stop) |> String.trim()
    rest = binary_part(tail, stop + 2, byte_size(tail) - stop - 2)

    case reference(inner) do
      {:ok, parsed} -> scan(rest, [{:reference, parsed} | acc], reasons)
      {:error, reason} -> scan(rest, acc, [reason | reasons])
    end
  end

  defp reference(""), do: {:error, :empty_reference}
  defp reference(inner), do: Expressions.parse(inner)

  defp literal("", acc), do: acc
  defp literal(text, acc), do: [{:literal, text} | acc]

  defp bounded(segments, reasons) do
    if length(references(segments)) > Limits.max_template_references() do
      {[], reasons ++ [:too_many_references]}
    else
      {segments, reasons}
    end
  end

  defp options(opts) do
    missing = Keyword.get(opts, :on_missing, :error)
    insert = Keyword.get(opts, :insert, :string)

    cond do
      missing not in [:error, :empty, :null] -> {:error, invalid_template_error()}
      insert not in [:string, :json] -> {:error, invalid_template_error()}
      true -> :ok
    end
  end

  defp source_size(text) do
    size = byte_size(text)

    if size > Limits.max_template_source() do
      {:error, source_error(size)}
    else
      :ok
    end
  end

  defp source_segments(segments) do
    size =
      Enum.reduce(segments, 0, fn
        %{"literal" => text}, acc when is_binary(text) -> acc + byte_size(text)
        _segment, acc -> acc
      end)

    if size > Limits.max_template_source() do
      {:error, source_error(size)}
    else
      :ok
    end
  end

  defp reference_count(segments) do
    count = Enum.count(segments, &reference_segment?/1)

    if count > Limits.max_template_references() do
      {:error,
       error(:too_many_references, "This template has too many references.", %{
         limit: Limits.max_template_references(),
         actual: count
       })}
    else
      :ok
    end
  end

  defp evaluate(segments, tree, opts) do
    json_field? = Keyword.get(opts, :insert, :string) == :json

    case native_target(segments) do
      {:ok, path, json?} -> resolve_native(path, json_field? or json?, tree, opts)
      :string -> render_string(segments, tree, opts, json_field?)
    end
  end

  defp native_target(segments) do
    {literals, references} =
      Enum.reduce(segments, {[], []}, fn segment, {lits, refs} ->
        cond do
          match?(%{"literal" => text} when is_binary(text) and text != "", segment) ->
            {[:lit | lits], refs}

          reference_segment?(segment) ->
            {lits, [segment | refs]}

          match?(%{"literal" => text} when is_binary(text), segment) ->
            {lits, refs}

          true ->
            {[:invalid | lits], refs}
        end
      end)

    case {literals, Enum.reverse(references)} do
      {[], [one]} -> {:ok, compiled_path(one), json_segment?(one)}
      _other -> :string
    end
  end

  defp resolve_native(path, json?, tree, opts) do
    label = path_text(path)

    case read(path, tree, opts) do
      {:secret, name} ->
        value = if json?, do: %{"secret" => name}, else: secret_placeholder(name)
        done(value, [label])

      {:ok, value} when json? ->
        with {:ok, measured} <- json_text(value, label),
             :ok <- expansion_size(byte_size(measured)) do
          {:ok, %{value: canonicalize(value), used_paths: [label]}}
        end

      {:ok, value} ->
        with {:ok, bytes} <- stringify(value, label),
             :ok <- expansion_size(byte_size(bytes)) do
          {:ok, %{value: bytes, used_paths: [label]}}
        end

      {:error, _error} = error ->
        error
    end
  end

  defp render_string(segments, tree, opts, json_field?) do
    Enum.reduce_while(segments, {:ok, [], [], 0}, fn segment, acc ->
      append_contribution(segment, tree, opts, json_field?, acc)
    end)
    |> finish_string()
  end

  defp append_contribution(segment, tree, opts, json_field?, {:ok, parts, used, size}) do
    case contribute(segment, tree, opts, json_field?) do
      {:ok, bytes, paths} -> take_bytes(bytes, paths, parts, used, size)
      {:error, _error} = error -> {:halt, error}
    end
  end

  defp take_bytes(bytes, paths, parts, used, size) do
    new_size = size + byte_size(bytes)

    if new_size > Limits.max_template_expansion() do
      {:halt, {:error, expansion_error(new_size)}}
    else
      {:cont, {:ok, [bytes | parts], used ++ paths, new_size}}
    end
  end

  defp finish_string({:ok, parts, used, _size}) do
    {:ok, %{value: parts |> Enum.reverse() |> IO.iodata_to_binary(), used_paths: used}}
  end

  defp finish_string({:error, _error} = error), do: error

  defp contribute(%{"literal" => text}, _tree, _opts, _json_field?) when is_binary(text) do
    {:ok, text, []}
  end

  defp contribute(%{"path" => path}, tree, opts, json_field?) do
    interpolate(path, tree, opts, json_field?)
  end

  defp contribute(%{"json" => path}, tree, opts, _json_field?) do
    interpolate(path, tree, opts, true)
  end

  defp contribute(_segment, _tree, _opts, _json_field?) do
    {:error, invalid_template_error()}
  end

  defp interpolate(path, tree, opts, json?) do
    label = path_text(path)

    case read(path, tree, opts) do
      {:secret, name} ->
        {:ok, secret_placeholder(name), [label]}

      {:ok, value} ->
        encoder = if json?, do: &json_text/2, else: &stringify/2

        case encoder.(value, label) do
          {:ok, bytes} -> {:ok, bytes, [label]}
          {:error, _error} = error -> error
        end

      {:error, _error} = error ->
        error
    end
  end

  defp read(%{"root" => "secret", "name" => name}, _tree, _opts) when is_binary(name) do
    {:secret, name}
  end

  defp read(%{"root" => _} = path, tree, opts) do
    case Path.resolve(path, tree) do
      {:ok, value} -> {:ok, value}
      {:error, %Error{code: :path_missing} = error} -> missing(error, opts)
      {:error, _error} = error -> error
    end
  end

  defp read(_path, _tree, _opts), do: {:error, invalid_template_error()}

  defp missing(%Error{} = error, opts) do
    case Keyword.get(opts, :on_missing, :error) do
      :error -> {:error, error}
      :empty -> {:ok, ""}
      :null -> {:ok, nil}
    end
  end

  defp stringify(value, label) when is_binary(value), do: value_size(value, label)

  defp stringify(value, label) when is_integer(value),
    do: stringify(Integer.to_string(value), label)

  defp stringify(true, label), do: stringify("true", label)
  defp stringify(false, label), do: stringify("false", label)
  defp stringify(nil, label), do: stringify("null", label)

  defp stringify(value, label) when is_float(value) do
    stringify(Jason.encode!(value), label)
  end

  defp stringify(value, label) when is_list(value) do
    {:error, json_required_error(label)}
  end

  defp stringify(value, label) when is_map(value) and not is_struct(value) do
    {:error, json_required_error(label)}
  end

  defp stringify(_value, label) do
    {:error, type_error(label)}
  end

  defp json_text(value, label) do
    if json_term?(value) do
      case Jason.encode(canonicalize(value)) do
        {:ok, json} -> value_size(json, label)
        {:error, _reason} -> {:error, type_error(label)}
      end
    else
      {:error, type_error(label)}
    end
  end

  defp json_term?(value) when is_binary(value), do: true
  defp json_term?(value) when is_integer(value), do: true
  defp json_term?(value) when is_float(value), do: true
  defp json_term?(value) when is_boolean(value), do: true
  defp json_term?(nil), do: true
  defp json_term?(value) when is_list(value), do: Enum.all?(value, &json_term?/1)

  defp json_term?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn
      {key, inner} when is_binary(key) -> json_term?(inner)
      _entry -> false
    end)
  end

  defp json_term?(_value), do: false

  defp canonicalize(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.map(fn {key, inner} -> {to_string(key), canonicalize(inner)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp canonicalize(value) when is_list(value), do: Enum.map(value, &canonicalize/1)
  defp canonicalize(value), do: value

  defp value_size(bytes, label) do
    limit = Limits.max_template_value()

    if byte_size(bytes) > limit do
      {:error,
       error(:template_value_too_large, "An interpolated value is too large.", %{
         path: label,
         limit: limit,
         actual: byte_size(bytes)
       })}
    else
      {:ok, bytes}
    end
  end

  defp expansion_size(size) do
    if size > Limits.max_template_expansion() do
      {:error, expansion_error(size)}
    else
      :ok
    end
  end

  defp done(value, used) when is_binary(value) do
    with :ok <- expansion_size(byte_size(value)) do
      {:ok, %{value: value, used_paths: used}}
    end
  end

  defp done(%{"secret" => _name} = value, used) do
    {:ok, %{value: value, used_paths: used}}
  end

  defp done(value, used) do
    {:ok, %{value: value, used_paths: used}}
  end

  defp reference_segment?(%{"path" => _path}), do: true
  defp reference_segment?(%{"json" => _path}), do: true
  defp reference_segment?(_segment), do: false

  defp json_segment?(%{"json" => _path}), do: true
  defp json_segment?(_segment), do: false

  defp compiled_path(%{"path" => path}), do: path
  defp compiled_path(%{"json" => path}), do: path

  defp path_text(%{"root" => "secret", "name" => name}) when is_binary(name) do
    "secret.#{name}"
  end

  defp path_text(%{"root" => _} = compiled) do
    case Path.from_compiled(compiled) do
      {:ok, segments} -> Enum.map_join(segments, ".", &segment_text/1)
      {:error, %Error{details: %{path: path}}} when is_binary(path) -> path
      {:error, _error} -> ""
    end
  end

  defp path_text(_compiled), do: ""

  defp segment_text(segment) when is_binary(segment), do: segment
  defp segment_text(segment) when is_integer(segment), do: Integer.to_string(segment)
  defp segment_text(_segment), do: "?"

  defp source_error(actual) do
    error(:template_too_large, "This template is too large.", %{
      limit: Limits.max_template_source(),
      actual: actual
    })
  end

  defp expansion_error(actual) do
    error(:template_expansion_too_large, "This template expands to too much text.", %{
      limit: Limits.max_template_expansion(),
      actual: actual
    })
  end

  defp json_required_error(path) do
    error(
      :template_json_required,
      "This value is not a string; insert it as JSON.",
      %{path: path}
    )
  end

  defp type_error(path) do
    error(:template_type_mismatch, "This value cannot be inserted into a template.", %{
      path: path
    })
  end

  defp invalid_template_error do
    error(:invalid_template, "This is not a compiler-produced template.", %{})
  end

  defp error(code, message, details) do
    Error.new(:validation, code, message: message, details: details)
  end
end
