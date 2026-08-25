defmodule PumbleAutomation.Workflows.Expressions do
  @moduledoc """
  The workflow data-path grammar.

  A path is a root followed by dot-separated segments. There is no function
  call, no index, no wildcard, and no operator: a path names a value and
  nothing else, so reading one can neither run code nor cost more than the
  number of segments it contains.

  ## Roots

      trigger.<field>...            the event that started the run
      steps.<node_id>.output...     what an earlier step produced
      execution...                  facts about this run
      workspace...                  facts about the workspace
      actor...                      who caused the run
      secret.<NAME>                 a stored credential

  Nothing else is a root. That is what "no arbitrary map traversal" means in
  practice: a path cannot start anywhere the runtime did not put data.

  `secret` is a root here because `{{ secret.API_TOKEN }}` is the explicit
  credential-reference form. Whether a *field* may use it is a separate
  question, and `PumbleAutomation.Workflows.Validator` is what answers it —
  only outbound headers and bodies may.

  ## Segments

  A segment is lowercase snake_case: `[a-z][a-z0-9_]*`. Two consequences
  matter. A segment can never be a struct's internals, because `__struct__`
  and every other reserved name begins with an underscore. And a segment is
  never turned into an atom by this module, so a path a stranger wrote cannot
  grow the atom table.

  A step reference is the one exception to the segment grammar: its first
  segment is a node identifier, which is a UUID, and its second must be the
  literal `output`. A secret name is the other: it is the same grammar a
  stored secret's name obeys, which is why this module asks
  `PumbleAutomation.Connections.Secret` rather than restating it.

  ## Bounds

  A path may name at most `PumbleAutomation.Workflows.Limits.max_path_segments/0`
  segments. Every pattern used here is anchored and has no nested quantifier,
  so matching is linear in the length of the segment.

  ## Runtime conditions

  `evaluate/2` walks a compiler-produced condition configuration against a
  JSON tree. It never parses predicate text. Operands are literals or the
  maps `PumbleAutomation.Workflows.Templates` stored; paths go through
  `PumbleAutomation.Workflows.Path.resolve/2`. Comparators follow the
  activation contract (`eq`, `neq`, `contains`, `not_contains`,
  `starts_with`, `ends_with`, `gt`, `gte`, `lt`, `lte`, `is_empty`,
  `is_not_empty`) plus `in` and `is_present`.
  Combinators are `all` (AND), `any` (OR), and `none` (NOT over the group).
  Nested groups are allowed. Logical forms short-circuit. Types are never
  coerced: a numeric string from the run is not a number, and `false` is
  not empty.
  """

  alias PumbleAutomation.Connections.Secret
  alias PumbleAutomation.Error
  alias PumbleAutomation.Workflows.Limits
  alias PumbleAutomation.Workflows.Node.ConditionConfig
  alias PumbleAutomation.Workflows.Node.Predicate
  alias PumbleAutomation.Workflows.Path
  alias PumbleAutomation.Workflows.Templates

  @roots %{
    "trigger" => :trigger,
    "steps" => :steps,
    "execution" => :execution,
    "workspace" => :workspace,
    "actor" => :actor,
    "secret" => :secret
  }

  @segment_format ~r/\A[a-z][a-z0-9_]*\z/

  @unary [:is_empty, :is_not_empty, :is_present]
  @ordered [:gt, :gte, :lt, :lte]

  @typedoc """
  A parsed path.

  `{:step, node_id, subpath}` carries the path *below* `output`, so an empty
  subpath is the whole output of that step.
  """
  @type t ::
          {:trigger, [String.t()]}
          | {:step, String.t(), [String.t()]}
          | {:context, :execution | :workspace | :actor, [String.t()]}
          | {:secret, String.t()}

  @type reason ::
          :empty_path
          | :unknown_root
          | :invalid_segment
          | :invalid_step_reference
          | :invalid_secret_name
          | :path_too_long

  @type evaluation :: %{matched: boolean(), decided: String.t(), combinator: String.t()}

  @doc """
  Parses one path.

  Returns the first reason the path is not a path. Paths are short and a
  caller shows one message per field, so there is nothing to gain from
  collecting more than one.
  """
  @spec parse(term()) :: {:ok, t()} | {:error, reason()}
  def parse(path) when is_binary(path) do
    case String.split(path, ".") do
      [""] -> {:error, :empty_path}
      segments -> bounded(segments)
    end
  end

  def parse(_path), do: {:error, :empty_path}

  @doc """
  Evaluates a compiled condition configuration against a JSON tree.

  `config` is the string-keyed map the compiler stored. The result names
  the combinator and the predicate that decided the branch, never the
  compared values.
  """
  @spec evaluate(term(), term()) :: {:ok, evaluation()} | {:error, Error.t()}
  def evaluate(config, tree) when is_map(config) and not is_struct(config) do
    with {:ok, combinator} <- known_combinator(config, ""),
         {:ok, matched, decided} <- eval_group(config, tree, "", 0) do
      {:ok, %{matched: matched, decided: decided, combinator: combinator_name(combinator)}}
    end
  end

  def evaluate(_config, _tree) do
    {:error, config_error("", :no_predicates, "A condition needs at least one comparison.")}
  end

  defp bounded(segments) do
    if length(segments) > Limits.max_path_segments() do
      {:error, :path_too_long}
    else
      root(segments)
    end
  end

  defp root([name | rest]) do
    case Map.fetch(@roots, name) do
      {:ok, :steps} -> step(rest)
      {:ok, :secret} -> secret(rest)
      {:ok, :trigger} -> data(rest, {:trigger, rest})
      {:ok, context} -> data(rest, {:context, context, rest})
      :error -> {:error, :unknown_root}
    end
  end

  defp step([id, "output" | rest]) do
    case Ecto.UUID.cast(id) do
      {:ok, node_id} -> segments(rest, {:step, node_id, rest})
      :error -> {:error, :invalid_step_reference}
    end
  end

  defp step(_rest), do: {:error, :invalid_step_reference}

  defp secret([name]) do
    if Regex.match?(Secret.name_format(), name) do
      {:ok, {:secret, name}}
    else
      {:error, :invalid_secret_name}
    end
  end

  defp secret(_rest), do: {:error, :invalid_secret_name}

  # A root on its own names a whole context map, which is not a value a
  # template can render and not a value a comparison can use.
  defp data([], _parsed), do: {:error, :invalid_segment}
  defp data(rest, parsed), do: segments(rest, parsed)

  defp segments(rest, parsed) do
    if Enum.all?(rest, &Regex.match?(@segment_format, &1)) do
      {:ok, parsed}
    else
      {:error, :invalid_segment}
    end
  end

  ## Condition evaluation

  defp eval_group(config, tree, prefix, depth) do
    with :ok <- group_depth(depth),
         {:ok, combinator} <- known_combinator(config, prefix),
         {:ok, predicates} <- predicate_list(config, prefix) do
      reduce_predicates(combinator, predicates, tree, prefix, depth)
    end
  end

  defp group_depth(depth) do
    case Limits.check_depth(depth) do
      :ok -> :ok
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp reduce_predicates(combinator, predicates, tree, prefix, depth) do
    do_reduce(predicates, 0, combinator, tree, prefix, depth, prefix <> "predicates")
  end

  defp do_reduce([], _index, :all, _tree, _prefix, _depth, decided), do: {:ok, true, decided}
  defp do_reduce([], _index, :any, _tree, _prefix, _depth, decided), do: {:ok, false, decided}
  defp do_reduce([], _index, :none, _tree, _prefix, _depth, decided), do: {:ok, true, decided}

  defp do_reduce([predicate | rest], index, combinator, tree, prefix, depth, _previous) do
    field = prefix <> "predicates.#{index}"

    case eval_node(predicate, tree, field, depth) do
      {:ok, matched, decided} ->
        case {combinator, matched} do
          {:all, false} -> {:ok, false, decided}
          {:any, true} -> {:ok, true, decided}
          {:none, true} -> {:ok, false, decided}
          _continue -> do_reduce(rest, index + 1, combinator, tree, prefix, depth, decided)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp eval_node(%{"predicates" => _predicates} = group, tree, field, depth) do
    eval_group(group, tree, field <> ".", depth + 1)
  end

  defp eval_node(%{"comparator" => _comparator} = predicate, tree, field, _depth) do
    eval_predicate(predicate, tree, field)
  end

  defp eval_node(_other, _tree, field, _depth) do
    {:error, config_error(field, :unknown_value, "This is not a supported comparison.")}
  end

  defp eval_predicate(predicate, tree, field) do
    with {:ok, comparator} <- known_comparator(predicate, field),
         {:ok, matched} <- apply_comparator(comparator, predicate, tree, field) do
      {:ok, matched, field <> "." <> comparator_name(comparator)}
    end
  end

  defp apply_comparator(comparator, predicate, tree, field) when comparator in @unary do
    case resolve_operand(Map.get(predicate, "left"), tree, field <> ".left", :allow_missing) do
      {:ok, :missing} -> {:ok, unary(comparator, :missing)}
      {:ok, value} -> {:ok, unary(comparator, unwrap(value))}
      {:error, _reason} = error -> error
    end
  end

  defp apply_comparator(comparator, predicate, tree, field) do
    with {:ok, left} <-
           resolve_operand(Map.get(predicate, "left"), tree, field <> ".left", :error),
         {:ok, right} <- required_right(Map.get(predicate, "right"), tree, field) do
      compare(comparator, left, right, field)
    end
  end

  defp required_right(nil, _tree, field) do
    {:error,
     config_error(
       field <> ".right",
       :comparator_operand_missing,
       "This comparison needs a value to compare against."
     )}
  end

  defp required_right(compiled, tree, field) do
    resolve_operand(compiled, tree, field <> ".right", :error)
  end

  defp unary(:is_empty, value), do: empty?(value)
  defp unary(:is_not_empty, value), do: not empty?(value)
  defp unary(:is_present, :missing), do: false
  defp unary(:is_present, _value), do: true

  defp empty?(:missing), do: true
  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?([]), do: true
  defp empty?(value) when is_map(value) and not is_struct(value), do: map_size(value) == 0
  defp empty?(_value), do: false

  defp compare(:eq, left, right, field), do: typed_equal(unwrap(left), unwrap(right), field)

  defp compare(:neq, left, right, field),
    do: negate(typed_equal(unwrap(left), unwrap(right), field))

  defp compare(:contains, left, right, field),
    do: contains(unwrap(left), unwrap(right), field)

  defp compare(:not_contains, left, right, field),
    do: negate(contains(unwrap(left), unwrap(right), field))

  defp compare(:starts_with, left, right, field),
    do: prefix_match(unwrap(left), unwrap(right), field, :starts_with)

  defp compare(:ends_with, left, right, field),
    do: prefix_match(unwrap(left), unwrap(right), field, :ends_with)

  defp compare(:in, left, right, field), do: membership(unwrap(left), unwrap(right), field)

  defp compare(comparator, left, right, field) when comparator in @ordered do
    ordered(comparator, left, right, field)
  end

  defp unwrap({:literal, text}), do: text
  defp unwrap({:resolved, value}), do: value

  defp typed_equal(left, right, field) do
    cond do
      number?(left) and number?(right) -> {:ok, left == right}
      same_kind?(left, right) -> {:ok, left == right}
      true -> type_error(field)
    end
  end

  defp contains(left, right, _field) when is_binary(left) and is_binary(right) do
    {:ok, String.contains?(left, right)}
  end

  defp contains(left, right, field) when is_list(left) do
    with :ok <- bound_list(left, field) do
      {:ok, Enum.any?(left, &strict_member?(&1, right))}
    end
  end

  defp contains(_left, _right, field), do: type_error(field)

  defp membership(left, right, field) when is_list(right) do
    with :ok <- bound_list(right, field) do
      {:ok, Enum.any?(right, &strict_member?(&1, left))}
    end
  end

  defp membership(_left, _right, field), do: type_error(field)

  defp prefix_match(left, right, _field, :starts_with)
       when is_binary(left) and is_binary(right) do
    {:ok, String.starts_with?(left, right)}
  end

  defp prefix_match(left, right, _field, :ends_with) when is_binary(left) and is_binary(right) do
    {:ok, String.ends_with?(left, right)}
  end

  defp prefix_match(_left, _right, field, _kind), do: type_error(field)

  defp ordered(comparator, left, right, field) do
    case {ordered_number(left), ordered_number(right)} do
      {{:ok, left_number}, {:ok, right_number}} ->
        {:ok, numeric_order(comparator, left_number, right_number)}

      _other ->
        case date_pair(unwrap(left), unwrap(right)) do
          {:ok, left_date, right_date} -> {:ok, date_order(comparator, left_date, right_date)}
          :error -> type_error(field)
        end
    end
  end

  defp numeric_order(:gt, left, right), do: left > right
  defp numeric_order(:gte, left, right), do: left >= right
  defp numeric_order(:lt, left, right), do: left < right
  defp numeric_order(:lte, left, right), do: left <= right

  defp date_order(comparator, {:date, left}, {:date, right}) do
    numeric_order(comparator, Date.to_gregorian_days(left), Date.to_gregorian_days(right))
  end

  defp date_order(comparator, {:datetime, left}, {:datetime, right}) do
    case DateTime.compare(left, right) do
      :gt -> comparator in [:gt, :gte]
      :lt -> comparator in [:lt, :lte]
      :eq -> comparator in [:gte, :lte]
    end
  end

  defp date_pair(left, right) do
    case {parse_date(left), parse_date(right)} do
      {{:ok, {kind, left_date}}, {:ok, {kind, right_date}}} ->
        {:ok, {kind, left_date}, {kind, right_date}}

      _other ->
        :error
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        {:ok, {:date, date}}

      {:error, _reason} ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> {:ok, {:datetime, datetime}}
          _other -> :error
        end
    end
  end

  defp parse_date(_value), do: :error

  defp negate({:ok, matched}), do: {:ok, not matched}
  defp negate({:error, _reason} = error), do: error

  defp strict_member?(item, value) do
    match?({:ok, true}, typed_equal(item, value, "membership"))
  end

  defp same_kind?(left, right) when is_binary(left) and is_binary(right), do: true
  defp same_kind?(left, right) when is_boolean(left) and is_boolean(right), do: true
  defp same_kind?(nil, nil), do: true
  defp same_kind?(left, right) when is_list(left) and is_list(right), do: true

  defp same_kind?(left, right)
       when is_map(left) and is_map(right) and not is_struct(left) and not is_struct(right),
       do: true

  defp same_kind?(_left, _right), do: false

  defp number?(value) when is_integer(value) or is_float(value), do: true
  defp number?(_value), do: false

  defp bound_list(list, field) do
    limit = Limits.max_list_length()

    if length(Enum.take(list, limit + 1)) > limit do
      {:error, config_error(field, :too_many_items, "This list has too many items.")}
    else
      :ok
    end
  end

  defp resolve_operand(compiled, tree, field, missing_policy) do
    case compiled_operand(compiled) do
      {:path, path} ->
        resolve_path(path, tree, field, missing_policy)

      {:literal, text} ->
        {:ok, {:literal, text}}

      {:template, template} ->
        resolve_template(template, tree, field, missing_policy)

      :invalid ->
        {:error, config_error(field, :unknown_value, "This comparison operand is invalid.")}
    end
  end

  defp compiled_operand(%{"template" => [%{"path" => path}]}), do: {:path, path}
  defp compiled_operand(%{"template" => [%{"json" => path}]}), do: {:path, path}

  defp compiled_operand(%{"template" => [%{"literal" => text}]}) when is_binary(text) do
    {:literal, text}
  end

  defp compiled_operand(%{"root" => _} = path), do: {:path, path}
  defp compiled_operand(text) when is_binary(text), do: {:literal, text}
  defp compiled_operand(nil), do: :invalid
  defp compiled_operand(other) when is_map(other), do: {:template, other}
  defp compiled_operand(_other), do: :invalid

  defp resolve_path(path, tree, field, missing_policy) do
    case Path.resolve(path, tree) do
      {:ok, value} ->
        reject_secret(value, [path_label(path)], field)

      {:error, %Error{code: :path_missing} = error} ->
        missing_result(error, field, missing_policy)

      {:error, %Error{} = error} ->
        annotate(error, field)
    end
  end

  defp resolve_template(template, tree, field, missing_policy) do
    case Templates.render(template, tree, insert: :json) do
      {:ok, %{value: value, used_paths: paths}} ->
        reject_secret(value, paths, field)

      {:error, %Error{code: :path_missing} = error} ->
        missing_result(error, field, missing_policy)

      {:error, %Error{} = error} ->
        annotate(error, field)
    end
  end

  defp missing_result(_error, _field, :allow_missing), do: {:ok, :missing}
  defp missing_result(error, field, :error), do: annotate(error, field)

  defp reject_secret(value, paths, field) do
    if secret_value?(value) or Enum.any?(paths, &secret_path?/1) do
      {:error,
       config_error(
         field,
         :secret_not_in_context,
         "This path names a secret, which is not part of the run context."
       )}
    else
      {:ok, {:resolved, value}}
    end
  end

  defp secret_value?(%{"secret" => name}) when is_binary(name), do: true
  defp secret_value?(_value), do: false

  defp secret_path?(path) when is_binary(path), do: String.starts_with?(path, "secret.")
  defp secret_path?(_path), do: false

  defp ordered_number({:literal, text}), do: parse_numeric_literal(text)

  defp ordered_number({:resolved, value}) when is_integer(value) or is_float(value),
    do: {:ok, value}

  defp ordered_number(_value), do: :error

  defp parse_numeric_literal(text) do
    case Integer.parse(text) do
      {int, ""} ->
        {:ok, int}

      _other ->
        case Float.parse(text) do
          {float, ""} -> {:ok, float}
          _other -> :error
        end
    end
  end

  defp known_combinator(config, field) do
    name = Map.get(config, "combinator", "all")

    case fetch_enum(ConditionConfig.combinators(), name) do
      {:ok, combinator} ->
        {:ok, combinator}

      :error ->
        {:error, config_error(field, :unknown_value, "This is not a supported value.")}
    end
  end

  defp known_comparator(predicate, field) do
    name = Map.get(predicate, "comparator")

    case fetch_enum(comparators(), name) do
      {:ok, comparator} ->
        {:ok, comparator}

      :error ->
        {:error,
         config_error(field <> ".comparator", :unknown_value, "This is not a supported value.")}
    end
  end

  defp comparators, do: Predicate.comparators()

  defp fetch_enum(mapping, name) when is_binary(name), do: Map.fetch(mapping, name)

  defp fetch_enum(mapping, name) when is_atom(name) do
    if name in Map.values(mapping), do: {:ok, name}, else: :error
  end

  defp fetch_enum(_mapping, _name), do: :error

  defp predicate_list(%{"predicates" => predicates}, _field)
       when is_list(predicates) and predicates != [] do
    {:ok, predicates}
  end

  defp predicate_list(_config, field) do
    {:error, config_error(field, :no_predicates, "A condition needs at least one comparison.")}
  end

  defp combinator_name(combinator), do: Atom.to_string(combinator)
  defp comparator_name(comparator), do: Atom.to_string(comparator)

  defp path_label(%{"root" => _} = compiled) do
    case Path.from_compiled(compiled) do
      {:ok, segments} -> Enum.map_join(segments, ".", &segment_text/1)
      {:error, %Error{details: %{path: path}}} when is_binary(path) -> path
      {:error, _} -> ""
    end
  end

  defp path_label(_compiled), do: ""

  defp segment_text(segment) when is_binary(segment), do: segment
  defp segment_text(segment) when is_integer(segment), do: Integer.to_string(segment)

  defp annotate(%Error{} = error, field) do
    {:error,
     Error.new(error.class, error.code,
       message: error.message,
       details: Map.put(error.details, :field, field),
       cause: error.cause
     )}
  end

  defp type_error(field) do
    {:error,
     config_error(field, :comparator_type_mismatch, "This comparison needs matching types.")}
  end

  defp config_error(field, code, message) do
    Error.new(:validation, code,
      message: message,
      details: %{field: field}
    )
  end
end
