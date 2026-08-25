defmodule PumbleAutomation.Workflows.Validator do
  @moduledoc """
  Decides whether a workflow definition could run, before anything tries.

  `validate/1` reads a `PumbleAutomation.Workflows.Definition` and returns
  every `PumbleAutomation.Workflows.ValidationIssue` it finds, in one stable
  order. It answers two questions at once, because an author asking "is this
  ready?" does not care which of them a given mistake belongs to:

    * *structural* — is there one supported trigger, are the step types real,
      do the branching steps branch anywhere, are the identifiers unique, and
      is the document within the configured structural limits;
    * *semantic* — does every data path name something that exists and will
      have run by then, does every template parse, and does each step's
      configuration make sense for the action it selected.

  ## Nothing is read and nothing is written

  There is no repository call, no network call, and no credential access on
  any path through this module. Whether a secret named `API_TOKEN` exists is
  not asked here; only whether `{{ secret.API_TOKEN }}` is a name and sits in
  a field allowed to carry one. Activation resolves the reference against the
  tenant's rows, and that is where a missing secret is found.

  ## What blocks and what only warns

  An error blocks activation. A warning does not. The line is whether the
  workflow can run and mean what it says: a step after a stop is dead but
  harmless, so it warns; a reference to a step that has not run yet cannot be
  resolved, so it blocks. Comparisons use the same rule —
  a type error between two literals is knowable now and blocks, while a type
  error that depends on what a message contains is a runtime failure and is
  not reported here at all.

  ## What a path may reach

  A step may read the trigger, any earlier step's output on its own path, and
  the run context. It may not read a later step, and it may not read across a
  branch that may not have run: inside `if_true`, the steps in `if_false` are
  not available, and neither are the steps nested under a *preceding* sibling
  that branches. The set of readable steps is therefore the steps before it in
  each sequence on its way down, plus the branching steps it is nested inside.

  ## The output schema

  Which steps publish output is fixed here. `pumble_action`, `http_action`,
  and `approval` produce a result a later step can read; `condition`,
  `delay`, and `stop` exist to branch, to wait, and to end, and publish
  nothing, so naming their output is an error rather than an empty value at
  run time. What the *fields* of an output are is settled by the node runners
  at expression-evaluation time, so a subpath below `output` is not checked here — checking it
  against a schema this validator invented would reject paths the runtime will
  happily resolve.

  The trigger's fields are fixed, and come from
  `PumbleAutomation.Ingress.AutomationEvent`. Its plumbing — the provider, the
  tenant, the kind, the deduplication key — is deliberately not reachable:
  those are how the event got here, not what it said. Everything a payload
  carried lands under `trigger.data`, whose keys vary by event type and are
  not checked.

  ## Bounds

  A definition is already bounded to the configured node limit from
  `PumbleAutomation.Limits` with bounded fields, and each template is bounded
  in how many references it may make, so the number of issues is bounded by
  construction. `max_issues/0` bounds it again after sorting, so a definition
  that is wrong in every possible way still returns a list a form can render.
  """

  alias PumbleAutomation.Connections.Connection
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Lineage
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.PumbleEventConfig
  alias PumbleAutomation.Workflows.Definition.ScheduleConfig
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Limits
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Node.ApprovalConfig
  alias PumbleAutomation.Workflows.Node.ConditionConfig
  alias PumbleAutomation.Workflows.Node.Config
  alias PumbleAutomation.Workflows.Node.HttpActionConfig
  alias PumbleAutomation.Workflows.Node.Predicate
  alias PumbleAutomation.Workflows.Node.PumbleActionConfig
  alias PumbleAutomation.Workflows.Node.StopConfig
  alias PumbleAutomation.Workflows.Schedule
  alias PumbleAutomation.Workflows.Templates
  alias PumbleAutomation.Workflows.ValidationIssue

  @max_issues 200

  # The reachable trigger fields, from PumbleAutomation.Ingress.AutomationEvent.
  @trigger_fields ~w(
    type actor_id channel_id resource_id thread_root_id
    occurred_at occurred_at_source correlation_id bot_origin data
  )

  # The step types whose output a later step may read.
  @output_types [:pumble_action, :http_action, :approval]

  # Which field each Pumble action needs, taken from the operation it calls in
  # PumbleAutomation.Pumble.Client.
  @pumble_required %{
    send_message: [:channel_id, :text],
    reply_message: [:channel_id, :message_id, :text],
    direct_message: [:user_id, :text],
    add_reaction: [:message_id, :reaction],
    remove_reaction: [:message_id, :reaction]
  }

  @pumble_fields [:channel_id, :user_id, :message_id, :text, :reaction]

  # Which fields carry a template. Everything else is literal text, and a
  # `{{ ... }}` in one of those is a mistake rather than a reference.
  @template_fields %{
    ApprovalConfig => [:prompt],
    HttpActionConfig => [:url],
    Predicate => [:left, :right],
    PumbleActionConfig => @pumble_fields,
    StopConfig => [:reason]
  }

  # A secret may reach an outbound header or body, and nowhere
  # else. A URL is excluded on purpose — it is logged and resolved.
  @secret_fields %{HttpActionConfig => [:body]}

  # Headers are a map whose keys carry rules of their own, so the generic
  # field walk leaves them to `header_issues/3`.
  @skipped_fields %{HttpActionConfig => [:headers]}

  # The codes that name something no encoder can write down: an atom outside
  # its mapping, a type nothing recognizes, a value that is not what it was
  # declared to be, or a configuration whose own fields were never checked
  # because it belongs to another type. The size limit is measured on the
  # encoded document, so it waits for a document that can be encoded rather
  # than turning a reportable mistake into an exception.
  @unencodable [
    :invalid_config,
    :invalid_type,
    :unknown_node_type,
    :unknown_trigger_type,
    :unknown_value
  ]

  @unary_comparators [:is_empty, :is_not_empty, :is_present]
  @numeric_comparators [:gt, :gte, :lt, :lte]
  @bodyless_methods [:get, :delete]

  @schedule_required %{
    once: [:run_at],
    every_minutes: [:interval],
    every_hours: [:interval],
    daily: [:time_of_day],
    weekly: [:time_of_day, :weekdays]
  }

  @time_of_day_format ~r/\A([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?\z/

  @messages %{
    action_field_missing: "This Pumble action needs this field.",
    action_field_unused: "This Pumble action ignores this field.",
    comparator_operand_missing: "This comparison needs a value to compare against.",
    comparator_operand_unused: "This comparison ignores the value to compare against.",
    comparator_type_mismatch: "This comparison needs two numbers.",
    empty_branches: "This step branches, but every branch is empty.",
    empty_path: "This reference names nothing.",
    empty_reference: "This template has an empty reference.",
    http_body_not_allowed: "A request with this method may not carry a body.",
    http_header_blocked: "This header is set by the transport and may not be set here.",
    http_header_invalid: "This is not a header a request may carry.",
    http_header_needs_secret: "This header may only carry a secret reference.",
    http_idempotency_header_conflict:
      "The idempotency header must not duplicate another configured header.",
    http_idempotency_header_reserved:
      "The execution effect key may not be written to this header.",
    http_not_allowed: "HTTP is not allowed; HTTPS is required.",
    http_url_not_absolute: "A URL must begin with https://.",
    invalid_config: "This step type does not take this kind of configuration.",
    invalid_connection_id: "This is not a connection identifier.",
    invalid_format: "This value has an invalid format.",
    invalid_id: "This is not a valid identifier.",
    invalid_run_at: "This is not a date and time.",
    invalid_secret_name: "This is not a secret name.",
    invalid_segment: "This reference uses a name that is not allowed.",
    invalid_step_reference: "A step reference must name a step and its output.",
    invalid_time_of_day: "This is not a time of day.",
    invalid_type: "This is not the kind of value this field takes.",
    invalid_timezone: "This is not a time zone name.",
    missing_required_field: "This field is required.",
    no_approvers: "An approval needs at least one approver.",
    no_predicates: "A condition needs at least one comparison.",
    no_steps: "A workflow needs at least one step.",
    path_too_long: "This reference names too many levels.",
    schedule_field_missing: "This schedule type needs this field.",
    secret_not_allowed: "A secret may only be used in an outbound header or body.",
    step_not_reachable: "This step does not always run before this one.",
    step_produces_no_output: "This step produces no output.",
    template_not_allowed: "This field takes plain text, not a reference.",
    too_many_items: "This list has too many items.",
    too_many_references: "This template has too many references.",
    unknown_node_type: "This is not a supported step type.",
    unknown_root: "This reference does not start from available data.",
    unknown_step_reference: "This reference names a step that does not exist.",
    unknown_trigger_field: "The trigger has no such field.",
    unknown_trigger_type: "This is not a supported trigger type.",
    unknown_value: "This is not a supported value.",
    unreachable_after_stop: "This step never runs, because an earlier step stops the workflow.",
    unsupported_schema_version: "This workflow uses an unsupported format version.",
    unterminated_reference: "This template opens a reference it never closes.",
    value_out_of_range: "This value is outside the allowed range.",
    value_too_long: "This value is too long."
  }

  @doc """
  Every issue in `definition`, ordered and deduplicated.

  An empty list means the definition may be compiled and activated. A list
  with no `:error` in it means the same; see
  `PumbleAutomation.Workflows.ValidationIssue.errors?/1`.
  """
  @spec validate(Definition.t()) :: [ValidationIssue.t()]
  def validate(%Definition{} = definition) do
    types = Map.new(Definition.nodes(definition), &{&1.id, &1.type})
    context = %{available: [], types: types, node_id: nil}

    issues =
      definition_issues(definition) ++
        trigger_issues(definition.trigger) ++
        sequence_issues(definition.steps, context, "/steps")

    (issues ++ limit_issues(definition, issues))
    |> Enum.uniq()
    |> ValidationIssue.sort()
    |> Enum.take(@max_issues)
  end

  @doc "The greatest number of issues one definition reports."
  @spec max_issues() :: pos_integer()
  def max_issues, do: @max_issues

  ## Definition

  defp definition_issues(%Definition{} = definition) do
    schema_issues(definition) ++ steps_issues(definition)
  end

  defp schema_issues(%Definition{schema_version: version}) do
    if version == Definition.schema_version() do
      []
    else
      [plain(:unsupported_schema_version, "/schema_version")]
    end
  end

  defp steps_issues(%Definition{steps: []}), do: [plain(:no_steps, "/steps")]
  defp steps_issues(%Definition{}), do: []

  defp limit_issues(%Definition{} = definition, issues) do
    if Enum.any?(issues, &(&1.code in @unencodable)), do: [], else: limits(definition)
  end

  # The structural limits already exist, with their own codes and their own
  # messages. Restating them here would give one limit two descriptions.
  defp limits(%Definition{} = definition) do
    case Definition.validate_limits(definition) do
      :ok -> []
      {:error, %Error{} = error} -> [ValidationIssue.error(error.code, "", error.message)]
    end
  end

  ## Trigger

  defp trigger_issues(%Trigger{} = trigger) do
    context = %{available: [], types: %{}, node_id: trigger.id}
    config_path = Config.join("/trigger", "config")

    trigger_type_issues(trigger, context) ++
      id_issues(trigger.id, context, Config.join("/trigger", "id")) ++
      trigger_config_issues(trigger, context, config_path)
  end

  defp trigger_type_issues(%Trigger{type: type} = trigger, context) do
    cond do
      type not in Map.values(Trigger.types()) ->
        [error(:unknown_trigger_type, Config.join("/trigger", "type"), context)]

      mismatched?(Trigger.config_module(type), trigger.config) ->
        [error(:invalid_config, Config.join("/trigger", "config"), context)]

      true ->
        []
    end
  end

  # A configuration belonging to another type describes fields this type does
  # not have, so reading it as this type's configuration would validate a
  # document nobody wrote. The mismatch is the finding; the fields are not.
  defp trigger_config_issues(%Trigger{type: type, config: config}, context, path) do
    if mismatched?(Trigger.config_module(type), config) do
      []
    else
      config_issues(config, context, path) ++
        schedule_issues(config, context, path) ++
        include_bot_issues(config, context, path)
    end
  end

  defp mismatched?(nil, _config), do: true
  defp mismatched?(module, %struct{}), do: module != struct

  defp id_issues(id, context, path) do
    case Ecto.UUID.cast(id) do
      {:ok, _uuid} -> []
      :error -> [error(:invalid_id, path, context)]
    end
  end

  defp schedule_issues(%ScheduleConfig{} = config, context, path) do
    required_schedule_issues(config, context, path) ++
      run_at_issues(config.run_at, context, Config.join(path, "run_at")) ++
      time_of_day_issues(config.time_of_day, context, Config.join(path, "time_of_day")) ++
      timezone_issues(config.timezone, context, Config.join(path, "timezone"))
  end

  defp schedule_issues(_config, _context, _path), do: []

  defp include_bot_issues(%PumbleEventConfig{ignore_bot_messages: false}, context, path) do
    [warning(:include_bot_loop_risk, Config.join(path, "ignore_bot_messages"), context)]
  end

  defp include_bot_issues(_config, _context, _path), do: []

  defp required_schedule_issues(%ScheduleConfig{} = config, context, path) do
    @schedule_required
    |> Map.get(config.schedule_type, [])
    |> Enum.filter(&blank?(Map.fetch!(config, &1)))
    |> Enum.map(&error(:schedule_field_missing, Config.join(path, Atom.to_string(&1)), context))
  end

  defp blank?(nil), do: true
  defp blank?([]), do: true
  defp blank?(_value), do: false

  defp run_at_issues(value, context, path) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> []
      {:error, _reason} -> naive_run_at_issues(value, context, path)
    end
  end

  defp run_at_issues(_value, _context, _path), do: []

  defp naive_run_at_issues(value, context, path) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, _datetime} -> []
      {:error, _reason} -> [error(:invalid_run_at, path, context)]
    end
  end

  defp time_of_day_issues(value, context, path) when is_binary(value) do
    if Regex.match?(@time_of_day_format, value) do
      []
    else
      [error(:invalid_time_of_day, path, context)]
    end
  end

  defp time_of_day_issues(_value, _context, _path), do: []

  defp timezone_issues(nil, _context, _path), do: []

  defp timezone_issues(value, context, path) do
    if Schedule.valid_timezone?(value), do: [], else: [error(:invalid_timezone, path, context)]
  end

  ## Sequences

  # The semantic walk reads collections the declared walk has already checked
  # the shape of, so anything that is not the collection it should be is left
  # alone here rather than described twice.
  defp sequence_issues(nodes, context, path) when is_list(nodes) do
    unreachable_issues(nodes, context, path) ++ walk(nodes, context, path)
  end

  defp sequence_issues(_nodes, _context, _path), do: []

  # One warning per sequence, on the first step that can never run. Marking
  # every step after a stop would turn one mistake into a wall of messages.
  defp unreachable_issues(nodes, context, path) do
    case Enum.find_index(nodes, &(&1.type == :stop)) do
      nil -> []
      index when index + 1 < length(nodes) -> [after_stop(nodes, context, path, index + 1)]
      _index -> []
    end
  end

  defp after_stop(nodes, context, path, index) do
    node = Enum.at(nodes, index)
    warning(:unreachable_after_stop, Config.join(path, index), %{context | node_id: node.id})
  end

  defp walk(nodes, context, path) do
    {issues, _available} =
      nodes
      |> Enum.with_index()
      |> Enum.reduce({[], context.available}, fn {node, index}, {issues, available} ->
        step = %{context | available: available}

        {issues ++ node_issues(node, step, Config.join(path, index)), [node.id | available]}
      end)

    issues
  end

  ## Nodes

  defp node_issues(%Node{} = node, context, path) do
    node_context = %{context | node_id: node.id}

    node_type_issues(node, node_context, path) ++
      id_issues(node.id, node_context, Config.join(path, "id")) ++
      node_config_issues(node, node_context, Config.join(path, "config")) ++
      branch_issues(node, node_context, path)
  end

  defp node_type_issues(%Node{type: type} = node, context, path) do
    cond do
      type not in Map.values(Node.types()) ->
        [error(:unknown_node_type, Config.join(path, "type"), context)]

      mismatched?(Node.config_module(type), node.config) ->
        [error(:invalid_config, Config.join(path, "config"), context)]

      Node.branch_keys(type) != [] and not Node.owns_branches?(node) ->
        [error(:empty_branches, path, context)]

      true ->
        []
    end
  end

  defp node_config_issues(%Node{type: type, config: config}, context, path) do
    if mismatched?(Node.config_module(type), config) do
      []
    else
      config_issues(config, context, path) ++ semantic_issues(config, context, path)
    end
  end

  # A branching step has run by the time its own branches run, so it joins the
  # available set for everything nested inside it. Its siblings' branches do
  # not: only one branch of a condition ever runs.
  defp branch_issues(%Node{} = node, context, path) do
    inner = %{context | available: [node.id | context.available]}

    Enum.flat_map(Node.branch_keys(node.type), fn key ->
      sequence_issues(
        Map.get(node.branches, key, []),
        inner,
        Config.join(path, Atom.to_string(key))
      )
    end)
  end

  ## Per-type semantics

  defp semantic_issues(%ConditionConfig{} = config, context, path) do
    condition_issues(config, context, path)
  end

  defp semantic_issues(%ApprovalConfig{approver_member_ids: []}, context, path) do
    [error(:no_approvers, Config.join(path, "approver_member_ids"), context)]
  end

  defp semantic_issues(%PumbleActionConfig{} = config, context, path) do
    pumble_issues(config, context, path)
  end

  defp semantic_issues(%HttpActionConfig{} = config, context, path) do
    http_issues(config, context, path)
  end

  defp semantic_issues(_config, _context, _path), do: []

  defp condition_issues(%ConditionConfig{predicates: []}, context, path) do
    [error(:no_predicates, Config.join(path, "predicates"), context)]
  end

  defp condition_issues(%ConditionConfig{predicates: predicates}, context, path)
       when is_list(predicates) do
    predicates_path = Config.join(path, "predicates")

    predicates
    |> Enum.with_index()
    |> Enum.flat_map(fn {predicate, index} ->
      predicate_issues(predicate, context, Config.join(predicates_path, index))
    end)
  end

  defp condition_issues(%ConditionConfig{}, _context, _path), do: []

  # A comparator that was never chosen is already reported as a missing field;
  # saying the right side is missing too would describe one mistake twice.
  defp predicate_issues(%Predicate{comparator: nil}, _context, _path), do: []

  defp predicate_issues(%Predicate{comparator: comparator} = predicate, context, path)
       when comparator in @unary_comparators do
    if is_nil(predicate.right) do
      []
    else
      [warning(:comparator_operand_unused, Config.join(path, "right"), context)]
    end
  end

  defp predicate_issues(%Predicate{right: nil}, context, path) do
    [error(:comparator_operand_missing, Config.join(path, "right"), context)]
  end

  defp predicate_issues(%Predicate{comparator: comparator} = predicate, context, path)
       when comparator in @numeric_comparators do
    if numeric_pair?(predicate.left, predicate.right) do
      []
    else
      [error(:comparator_type_mismatch, path, context)]
    end
  end

  defp predicate_issues(%Predicate{}, _context, _path), do: []
  defp predicate_issues(_predicate, _context, _path), do: []

  # A type error is a validation error only when it is static.
  # Once either side interpolates, what is being compared depends on the run.
  defp numeric_pair?(left, right) do
    if literal?(left) and literal?(right) do
      numeric?(left) and numeric?(right)
    else
      true
    end
  end

  defp literal?(value) when is_binary(value), do: :binary.match(value, "{{") == :nomatch
  defp literal?(_value), do: false

  # Only ever reached for a binary, because `literal?/1` refuses everything else.
  defp numeric?(value) when is_binary(value) do
    match?({_number, ""}, Float.parse(value))
  end

  defp pumble_issues(%PumbleActionConfig{action: nil}, _context, _path), do: []

  defp pumble_issues(%PumbleActionConfig{} = config, context, path) do
    required = Map.get(@pumble_required, config.action, [])

    Enum.flat_map(@pumble_fields, fn field ->
      pumble_field_issues(
        Map.fetch!(config, field),
        field in required,
        context,
        Config.join(path, Atom.to_string(field))
      )
    end)
  end

  defp pumble_field_issues(nil, true, context, path) do
    [error(:action_field_missing, path, context)]
  end

  defp pumble_field_issues(nil, false, _context, _path), do: []
  defp pumble_field_issues(_value, true, _context, _path), do: []

  defp pumble_field_issues(_value, false, context, path) do
    [warning(:action_field_unused, path, context)]
  end

  defp http_issues(%HttpActionConfig{} = config, context, path) do
    body_issues(config, context, path) ++
      url_issues(config.url, context, Config.join(path, "url")) ++
      connection_issues(config.connection_id, context, Config.join(path, "connection_id")) ++
      header_issues(config.headers, context, Config.join(path, "headers")) ++
      idempotency_header_issues(
        config.idempotency_header,
        config.headers,
        context,
        Config.join(path, "idempotency_header")
      )
  end

  defp body_issues(%HttpActionConfig{method: method, body: body}, context, path)
       when method in @bodyless_methods and is_binary(body) and body != "" do
    [error(:http_body_not_allowed, Config.join(path, "body"), context)]
  end

  defp body_issues(_config, _context, _path), do: []

  # The scheme must be literal. A URL whose scheme comes out of a template is
  # a URL nothing can reason about before the request is already being made.
  defp url_issues(url, context, path) when is_binary(url) do
    cond do
      String.starts_with?(url, "https://") ->
        []

      String.starts_with?(url, "http://") ->
        [error(:http_not_allowed, path, context)]

      true ->
        [error(:http_url_not_absolute, path, context)]
    end
  end

  defp url_issues(_url, _context, _path), do: []

  defp connection_issues(nil, _context, _path), do: []

  defp connection_issues(id, context, path) do
    case Ecto.UUID.cast(id) do
      {:ok, _uuid} -> []
      :error -> [error(:invalid_connection_id, path, context)]
    end
  end

  # An entry that is not a pair of strings is reported against the map as a
  # whole, so a key nothing can print never reaches a field path.
  defp header_issues(headers, context, path) when is_map(headers) and not is_struct(headers) do
    headers
    |> Enum.filter(fn {name, value} -> is_binary(name) and is_binary(value) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {name, value} ->
      header_issue(name, value, context, Config.join(path, name))
    end)
  end

  defp header_issues(_headers, _context, _path), do: []

  defp idempotency_header_issues(nil, _headers, _context, _path), do: []
  defp idempotency_header_issues("", _headers, _context, _path), do: []

  defp idempotency_header_issues(name, headers, context, path) when is_binary(name) do
    key = String.downcase(name)

    cond do
      not Regex.match?(Connection.header_name_format(), key) ->
        [error(:http_header_invalid, path, context)]

      key in Connection.blocked_headers() or key in Connection.secret_only_headers() or
        key in ["accept-encoding", "content-type"] or String.starts_with?(key, "proxy-") ->
        [error(:http_idempotency_header_reserved, path, context)]

      header_name_present?(headers, key) ->
        [error(:http_idempotency_header_conflict, path, context)]

      true ->
        []
    end
  end

  defp idempotency_header_issues(_name, _headers, _context, _path), do: []

  defp header_name_present?(headers, name) when is_map(headers) and not is_struct(headers) do
    Enum.any?(Map.keys(headers), fn
      key when is_binary(key) -> String.downcase(key) == name
      _key -> false
    end)
  end

  defp header_name_present?(_headers, _name), do: false

  # One outbound header rule, owned by `Connection`. A workflow differs from a
  # connection in one way only: `authorization` may be set here when a secret
  # fills it, which is why credential references are explicit.
  defp header_issue(name, value, context, path) do
    key = String.downcase(name)

    cond do
      not Regex.match?(Connection.header_name_format(), key) ->
        [error(:http_header_invalid, path, context)]

      key in Connection.blocked_headers() or String.starts_with?(key, "proxy-") ->
        [error(:http_header_blocked, path, context)]

      byte_size(value) > Connection.max_header_value() ->
        [error(:value_too_long, path, context)]

      not Regex.match?(Connection.header_value_format(), value) ->
        [error(:http_header_invalid, path, context)]

      key in Connection.secret_only_headers() and not secret_reference?(value) ->
        [error(:http_header_needs_secret, path, context)]

      true ->
        template_issues(value, :secret, context, path)
    end
  end

  defp secret_reference?(value) do
    {segments, _reasons} = Templates.parse(value)

    Enum.any?(Templates.references(segments), &match?({:secret, _name}, &1))
  end

  ## Declared fields

  # Driven by the same `fields/0` list the decoder reads, because a definition
  # can also be built in memory by the editor, which does not decode. One
  # description of a field, checked from both directions.
  defp config_issues(%module{} = config, context, path) do
    Enum.flat_map(module.fields(), fn {name, kind, opts} ->
      field_issues(
        Map.fetch!(config, name),
        kind,
        opts,
        field_policy(module, name),
        context,
        Config.join(path, Atom.to_string(name))
      )
    end)
  end

  defp field_issues(nil, _kind, opts, _policy, context, path) do
    if Keyword.get(opts, :required, false) do
      [error(:missing_required_field, path, context)]
    else
      []
    end
  end

  # A value that is not what it was declared to be is the only thing worth
  # saying about it. Reading a template out of a field that is the wrong type,
  # or walking a list already over its bound, expands work on a value that has
  # to be replaced anyway.
  defp field_issues(value, kind, opts, policy, context, path) do
    case declared_issues(value, kind, opts, context, path) do
      [] -> text_issues(value, kind, policy, context, path)
      issues -> issues
    end
  end

  defp declared_issues(value, :string, opts, context, path) when is_binary(value) do
    max = Keyword.get(opts, :max_length, Limits.max_string_length())
    format = Keyword.get(opts, :format)

    cond do
      byte_size(value) > max ->
        [
          field_error(
            :value_too_long,
            Keyword.get(opts, :max_length_message),
            path,
            context
          )
        ]

      not String.valid?(value) ->
        [error(:invalid_type, path, context)]

      match?(%Regex{}, format) and not Regex.match?(format, value) ->
        [field_error(:invalid_format, Keyword.get(opts, :format_message), path, context)]

      true ->
        []
    end
  end

  defp declared_issues(value, :integer, opts, context, path) when is_integer(value) do
    if out_of_range?(value, Keyword.get(opts, :min), Keyword.get(opts, :max)) do
      [error(:value_out_of_range, path, context)]
    else
      []
    end
  end

  defp declared_issues(value, :boolean, _opts, _context, _path) when is_boolean(value), do: []

  defp declared_issues(value, {:enum, mapping}, _opts, context, path) do
    if value in Map.values(mapping), do: [], else: [error(:unknown_value, path, context)]
  end

  defp declared_issues(values, {:list, element}, opts, context, path) when is_list(values) do
    if length(values) > Limits.max_list_length() do
      [error(:too_many_items, path, context)]
    else
      element_issues(values, element, opts, context, path)
    end
  end

  defp declared_issues(value, {:map, :string}, _opts, context, path)
       when is_map(value) and not is_struct(value) do
    cond do
      map_size(value) > Limits.max_map_size() -> [error(:too_many_items, path, context)]
      not text_pairs?(value) -> [error(:invalid_type, path, context)]
      true -> []
    end
  end

  defp declared_issues(_value, _kind, _opts, context, path) do
    [error(:invalid_type, path, context)]
  end

  defp out_of_range?(value, min, max) do
    (is_integer(min) and value < min) or (is_integer(max) and value > max)
  end

  defp text_pairs?(map) do
    Enum.all?(map, fn {key, value} -> is_binary(key) and is_binary(value) end)
  end

  defp element_issues(values, element, opts, context, path) do
    values
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} ->
      element_issue(value, element, opts, context, Config.join(path, index))
    end)
  end

  defp element_issue(%module{} = nested, {:struct, module}, _opts, context, path) do
    config_issues(nested, context, path)
  end

  defp element_issue(_value, {:struct, _module}, _opts, context, path) do
    [error(:invalid_type, path, context)]
  end

  defp element_issue(value, kind, opts, context, path) do
    declared_issues(value, kind, opts, context, path)
  end

  ## Templates and references

  defp field_policy(module, name) do
    cond do
      name in Map.get(@skipped_fields, module, []) -> :skip
      name in Map.get(@secret_fields, module, []) -> :secret
      name in Map.get(@template_fields, module, []) -> :template
      true -> :literal
    end
  end

  defp text_issues(_value, _kind, :skip, _context, _path), do: []

  defp text_issues(value, :string, policy, context, path) do
    template_issues(value, policy, context, path)
  end

  defp text_issues(values, {:list, :string}, policy, context, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} ->
      template_issues(value, policy, context, Config.join(path, index))
    end)
  end

  defp text_issues(_value, _kind, _policy, _context, _path), do: []

  # A template that does not parse still has references that do, and each of
  # those can be wrong in its own right.
  defp template_issues(value, policy, context, path) when is_binary(value) do
    {segments, reasons} = Templates.parse(value)

    Enum.map(reasons, &error(&1, path, context)) ++
      reference_issues(Templates.references(segments), policy, context, path)
  end

  defp template_issues(_value, _policy, _context, _path), do: []

  defp reference_issues([], _policy, _context, _path), do: []

  defp reference_issues(_references, :literal, context, path) do
    [error(:template_not_allowed, path, context)]
  end

  defp reference_issues(references, policy, context, path) do
    Enum.flat_map(references, &reference_issue(&1, policy, context, path))
  end

  defp reference_issue({:secret, _name}, :secret, _context, _path), do: []

  defp reference_issue({:secret, _name}, _policy, context, path) do
    [error(:secret_not_allowed, path, context)]
  end

  defp reference_issue({:trigger, [field | _rest]}, _policy, context, path) do
    if field in @trigger_fields, do: [], else: [error(:unknown_trigger_field, path, context)]
  end

  defp reference_issue({:step, node_id, _rest}, _policy, context, path) do
    step_issues(node_id, context, path)
  end

  defp reference_issue({:context, _root, _rest}, _policy, _context, _path), do: []

  defp step_issues(node_id, context, path) do
    cond do
      not Map.has_key?(context.types, node_id) ->
        [error(:unknown_step_reference, path, context)]

      Map.fetch!(context.types, node_id) not in @output_types ->
        [error(:step_produces_no_output, path, context)]

      node_id not in context.available ->
        [error(:step_not_reachable, path, context)]

      true ->
        []
    end
  end

  ## Issue construction

  defp error(code, path, context) do
    ValidationIssue.error(code, path, message(code), context.node_id)
  end

  defp field_error(code, nil, path, context), do: error(code, path, context)

  defp field_error(code, field_message, path, context) when is_binary(field_message) do
    ValidationIssue.error(code, path, field_message, context.node_id)
  end

  defp warning(code, path, context) do
    ValidationIssue.warning(code, path, message(code), context.node_id)
  end

  defp plain(code, path), do: ValidationIssue.error(code, path, message(code))

  defp message(:include_bot_loop_risk), do: Lineage.include_bot_warning_message()
  defp message(code), do: Map.fetch!(@messages, code)
end
