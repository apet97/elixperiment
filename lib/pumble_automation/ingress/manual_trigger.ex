defmodule PumbleAutomation.Ingress.ManualTrigger do
  @moduledoc """
  Converts a slash command, shortcut, or authorized browser run into executions.

  Workflows are resolved by installation plus a unique active alias, or by a
  version that already belongs to that installation. Unscoped identifiers are
  never used. Pumble interactions share the event engine API:
  `PumbleAutomation.Executions.Engine.create/2`.

  ## Responses

  Picker and not-found replies are built by adapter functions so P17 can
  replace the HTTP envelope without touching durability. The default picker
  is a modal-only envelope (`PR-14` / matrix `X-1`): an ack and a modal are
  mutually exclusive on HTTP, so the picker is not an acknowledgement that
  a run started.

  The fixed dynamic-menu action has no field that identifies which shortcut
  opened it. Its contract is therefore the sorted union of active aliases that
  opted into either the global or message picker. Slash-only aliases are not
  exposed. The lookup filters in PostgreSQL and returns at most 25 options, so
  a valid signed replay remains a bounded read and never becomes an execution.
  """

  import Ecto.Query, only: [from: 2]

  alias PumbleAutomation.Audit.Writer
  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Execution
  alias PumbleAutomation.Executions.Lineage
  alias PumbleAutomation.Ingress.Deduplication
  alias PumbleAutomation.Ingress.InteractionCommand
  alias PumbleAutomation.Ingress.RateLimiter
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.Ingress.TriggerMatcher
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Pumble.Manifest
  alias PumbleAutomation.Pumble.Normalizer
  alias PumbleAutomation.Pumble.Payload
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows.TriggerBinding
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomation.Workflows.WorkflowVersion

  @picker_action "run_workflow"
  @not_found_message "That workflow was not found."
  @max_picker_options 25
  @max_dynamic_menu_query_bytes 256
  @telemetry_event [:pumble_automation, :ingress, :manual]

  @typedoc "What the callback controller may turn into a protocol response."
  @type accept_ok ::
          :started
          | :duplicate
          | :ignored
          | :not_found
          | {:picker, map()}
          | {:dynamic_menu, map()}

  @type accept_result :: {:ok, accept_ok()} | {:error, Error.t()}

  @doc """
  Accepts one classified interactive callback for durable ingestion.

  `context` must include the exact `:raw_body` the signature plug verified.
  A missing body is a validation error and is not an acknowledgement that a
  run started.
  """
  @spec accept(Payload.t(), map()) :: accept_result()
  def accept(payload, context \\ %{}) when is_struct(payload) and is_map(context) do
    with {:ok, transport} <- parse_transport(context) do
      ingest(payload, transport)
    end
  end

  @doc """
  Starts a browser test or live run for an editor.

  `attrs` must name `:run_mode` as `"dry_run"` or `"live"`. Resolve the
  workflow with `:alias` or `:workflow_version_id` (tenant-scoped). An
  optional `:idempotency_key` collapses retries; otherwise a request id is
  generated.
  """
  @spec run_browser(Scope.t(), map()) :: {:ok, Execution.t()} | {:error, Error.t()}
  def run_browser(%Scope{} = scope, attrs) when is_map(attrs) do
    with :ok <- Policy.authorize(scope, :test_workflows),
         {:ok, request} <- parse_browser(scope, attrs),
         {:ok, version} <- resolve_browser_version(scope, request) do
      persist_browser(scope, version, request)
    end
  end

  @doc "Safe ephemeral copy for an unknown or disabled alias."
  @spec not_found_message() :: String.t()
  def not_found_message, do: @not_found_message

  @doc """
  Default picker envelope: a modal, no ack (`PR-14` strategy 1).

  Alternatives live in `picker_ack_message/1`.
  """
  @spec picker_modal_response([String.t()]) :: map()
  def picker_modal_response(aliases) when is_list(aliases) do
    buttons =
      aliases
      |> Enum.take(@max_picker_options)
      |> Enum.map(&picker_button/1)

    %{
      "view" => %{
        "type" => "modal",
        "title" => %{"type" => "plain_text", "text" => "Run workflow"},
        "blocks" => [%{"type" => "actions", "elements" => buttons}]
      }
    }
  end

  @doc """
  Alternative picker: an ack message listing aliases.

  Not used on the default path. Kept so a live probe can switch the adapter
  without rewriting ingestion.
  """
  @spec picker_ack_message([String.t()]) :: String.t()
  def picker_ack_message(aliases) when is_list(aliases) do
    listed = aliases |> Enum.take(@max_picker_options) |> Enum.join(", ")
    "Choose a workflow: #{listed}"
  end

  @doc "The maximum number of aliases returned by one dynamic-menu request."
  @spec dynamic_menu_option_limit() :: pos_integer()
  def dynamic_menu_option_limit, do: @max_picker_options

  @doc "Telemetry prefix for manual ingest."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  defp ingest(%Payload.DynamicMenu{} = payload, _transport) do
    case resolve_installation(payload) do
      {:ok, installation} -> resolve_dynamic_menu(payload, installation)
      :ignore -> {:ok, :not_found}
    end
  end

  defp ingest(%Payload.Event{}, _transport) do
    {:error,
     Error.new(:validation, :not_an_interaction,
       message: "That callback is not a manual trigger."
     )}
  end

  defp ingest(payload, transport) do
    case resolve_installation(payload) do
      {:ok, installation} -> accept_interaction(payload, installation, transport)
      :ignore -> {:ok, :not_found}
    end
  end

  defp accept_interaction(payload, installation, transport) do
    with {:ok, command} <- normalize(payload, installation, transport) do
      dispatch_interaction(command, installation, transport)
    end
  end

  defp dispatch_interaction(%InteractionCommand{kind: :view_action, type: "CLOSE"}, _, _) do
    {:ok, :ignored}
  end

  defp dispatch_interaction(command, installation, transport) do
    case resolve_matches(command) do
      {:picker, aliases} ->
        {:ok, {:picker, picker_modal_response(aliases)}}

      [] ->
        _ = audit_denied(command, installation, "not_found")
        {:ok, :not_found}

      matches ->
        persist_pumble(command, installation, transport, matches)
    end
  end

  defp persist_pumble(command, installation, transport, matches) do
    with :ok <- RateLimiter.check_manual_run(installation.id),
         {:ok, kind, receipt} <- record_interaction_receipt(command, installation, transport) do
      finish_pumble(kind, receipt, installation, command, matches)
    end
  end

  defp finish_pumble(_kind, %ReceivedEvent{processing_state: "processed"}, _, _, _) do
    {:ok, :duplicate}
  end

  defp finish_pumble(_kind, receipt, installation, command, matches) do
    snapshot = pumble_snapshot(command, receipt)

    case create_all(installation.id, receipt, matches, snapshot, "live") do
      {:ok, 0} ->
        with :ok <- mark_processed(receipt, 0) do
          {:ok, :not_found}
        end

      {:ok, count} ->
        with :ok <- mark_processed(receipt, count) do
          emit(:started)
          {:ok, :started}
        end

      {:error, error} ->
        {:error, maybe_retry_later(error)}
    end
  end

  defp persist_browser(scope, version, request) do
    with :ok <- RateLimiter.check_manual_run(scope.installation_id),
         {:ok, kind, receipt} <- record_browser_receipt(scope, request) do
      finish_browser(kind, receipt, scope, version, request)
    end
  end

  defp finish_browser(
         _kind,
         %ReceivedEvent{processing_state: "processed"} = receipt,
         scope,
         _version,
         _request
       ) do
    existing_execution(scope.installation_id, receipt.id)
  end

  defp finish_browser(_kind, receipt, scope, version, request) do
    snapshot = browser_snapshot(request, version, receipt)

    case Engine.create(scope.installation_id, %{
           workflow_version_id: version.id,
           execution_key: "man:" <> receipt.id,
           received_event_id: receipt.id,
           trigger_snapshot: snapshot,
           run_mode: request.run_mode
         }) do
      {:ok, execution} ->
        with :ok <- mark_processed(receipt, 1) do
          {:ok, execution}
        end

      {:error, %Error{code: code} = error} when code in [:not_active, :version_mismatch] ->
        {:error, error}

      {:error, %Error{code: :not_found}} ->
        {:error, Policy.not_found()}

      {:error, %Error{class: class} = error} when class in [:validation, :rate_limited] ->
        {:error, error}

      {:error, error} ->
        {:error, maybe_retry_later(error)}
    end
  end

  defp resolve_matches(%InteractionCommand{} = command) do
    case selected_alias(command) do
      alias_name when is_binary(alias_name) ->
        command
        |> put_alias(alias_name)
        |> match_selected()

      nil ->
        picker_or_single(command)
    end
  end

  defp match_selected(%InteractionCommand{kind: kind} = command)
       when kind in [:slash_command, :global_shortcut, :message_shortcut] do
    TriggerMatcher.match(command)
  end

  defp match_selected(%InteractionCommand{} = command) do
    alias_matches(command.installation_id, selected_alias(command))
  end

  defp picker_or_single(%InteractionCommand{} = command) do
    bindings = entry_bindings(command)

    case Enum.map(bindings, & &1.alias) |> Enum.reject(&is_nil/1) do
      [] ->
        []

      [alias_name] ->
        match_selected(put_alias(command, alias_name))

      aliases ->
        {:picker, Enum.sort(aliases)}
    end
  end

  defp resolve_dynamic_menu(%Payload.DynamicMenu{} = payload, installation) do
    with true <- payload.on_action == Manifest.dynamic_menu_action(),
         {:ok, query} <- bounded_menu_query(payload.query),
         [_ | _] = options <- dynamic_menu_options(installation.id, query) do
      body = %{
        "onAction" => payload.on_action,
        "options" => options,
        "triggerId" => payload.trigger_id
      }

      body = if is_nil(payload.value), do: body, else: Map.put(body, "value", payload.value)
      {:ok, {:dynamic_menu, body}}
    else
      _unsupported_or_empty -> {:ok, :not_found}
    end
  end

  defp bounded_menu_query(nil), do: {:ok, nil}

  defp bounded_menu_query(query) when is_binary(query) do
    if byte_size(query) <= @max_dynamic_menu_query_bytes do
      case String.trim(query) do
        "" -> {:ok, nil}
        trimmed -> {:ok, trimmed}
      end
    else
      :error
    end
  end

  defp dynamic_menu_options(installation_id, query) do
    base =
      installation_id
      |> TriggerBinding.candidates(kind: "manual")
      |> Ecto.Query.exclude(:order_by)
      |> Ecto.Query.exclude(:select)

    filtered =
      from [binding, installation, _workflow] in base,
        where: installation.status == "active",
        where: not is_nil(binding.alias),
        where:
          fragment("COALESCE(?->>'global_shortcut', 'false') = 'true'", binding.filter_config) or
            fragment(
              "COALESCE(?->>'message_shortcut', 'false') = 'true'",
              binding.filter_config
            ),
        order_by: [asc: binding.alias],
        limit: ^@max_picker_options,
        select: binding.alias

    filtered
    |> maybe_filter_menu_query(query)
    |> Repo.all()
    |> Enum.map(&dynamic_menu_option/1)
  end

  defp maybe_filter_menu_query(query, nil), do: query

  defp maybe_filter_menu_query(query, text) do
    pattern = "%" <> escape_like(text) <> "%"
    from binding in query, where: ilike(binding.alias, ^pattern)
  end

  defp escape_like(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp dynamic_menu_option(alias_name) do
    %{
      "text" => %{"type" => "plain_text", "text" => alias_name},
      "value" => alias_name
    }
  end

  defp entry_bindings(%InteractionCommand{} = command) do
    command.installation_id
    |> TriggerBinding.candidates(kind: "manual")
    |> Repo.all()
    |> Enum.filter(&entry_open?(&1, command.kind))
  end

  defp alias_matches(_installation_id, nil), do: []

  defp alias_matches(installation_id, alias_name) do
    installation_id
    |> TriggerBinding.candidates(kind: "manual", alias: alias_name)
    |> Repo.all()
    |> Enum.map(fn binding ->
      %TriggerMatcher{binding_id: binding.id, workflow_version_id: binding.workflow_version_id}
    end)
  end

  defp entry_open?(%TriggerBinding{filter_config: config}, kind) when is_map(config) do
    config = stringify_keys(config)

    case kind do
      :slash_command -> config["slash_command"] == true
      :global_shortcut -> config["global_shortcut"] == true
      :message_shortcut -> config["message_shortcut"] == true
      _other -> false
    end
  end

  defp entry_open?(_binding, _kind), do: false

  defp selected_alias(%InteractionCommand{kind: :slash_command, data: data}) do
    data
    |> map_get(:text)
    |> first_token()
  end

  defp selected_alias(%InteractionCommand{kind: :block_interaction, data: data}) do
    case map_get(data, :block_value) do
      value when is_binary(value) and value != "" -> value
      _missing -> nil
    end
  end

  defp selected_alias(%InteractionCommand{kind: :view_action, data: data}) do
    case map_get(data, :alias) do
      value when is_binary(value) and value != "" -> value
      _missing -> nil
    end
  end

  defp selected_alias(%InteractionCommand{data: data}) do
    case map_get(data, :alias) do
      value when is_binary(value) and value != "" -> value
      _missing -> nil
    end
  end

  defp put_alias(%InteractionCommand{} = command, alias_name) do
    %{command | data: Map.put(command.data, :alias, alias_name)}
  end

  defp first_token(text) when is_binary(text) do
    case text |> String.trim() |> String.split(~r/\s+/, parts: 2) do
      [alias_name | _] when alias_name != "" -> alias_name
      _empty -> nil
    end
  end

  defp first_token(_text), do: nil

  defp create_all(installation_id, receipt, matches, snapshot, run_mode) do
    Enum.reduce_while(matches, {:ok, 0}, fn match, {:ok, count} ->
      installation_id
      |> create_match(receipt, match, snapshot, run_mode)
      |> tally_create(count)
    end)
  end

  defp tally_create({:ok, _execution}, count), do: {:cont, {:ok, count + 1}}

  defp tally_create({:error, %Error{} = error}, count) do
    if skip_create?(error), do: {:cont, {:ok, count}}, else: {:halt, {:error, error}}
  end

  defp create_match(installation_id, receipt, match, snapshot, run_mode) do
    Engine.create(installation_id, %{
      workflow_version_id: match.workflow_version_id,
      execution_key: "recv:" <> receipt.id <> ":" <> match.binding_id,
      received_event_id: receipt.id,
      trigger_snapshot: Map.put(snapshot, "binding_id", match.binding_id),
      run_mode: run_mode
    })
  end

  defp skip_create?(%Error{code: code}) do
    code in [:not_active, :version_mismatch, :not_found] or
      code in Lineage.skip_create_codes()
  end

  defp record_interaction_receipt(command, installation, transport) do
    Deduplication.record(%{
      installation_id: installation.id,
      class: "interaction",
      type: receipt_type(command),
      provider: "pumble",
      provider_id: command.trigger_id,
      action_identity: action_identity(command),
      raw_body: transport.raw_body,
      signature: transport.signature,
      received_at: transport.received_at,
      occurred_at: command.occurred_at,
      data: pumble_snapshot(command, nil)
    })
  end

  defp record_browser_receipt(scope, request) do
    Deduplication.record(%{
      installation_id: scope.installation_id,
      class: "manual",
      type: "browser",
      provider: "browser",
      request_id: request.request_id,
      raw_body: request.raw_body,
      received_at: DateTime.utc_now(),
      data: %{
        "run_mode" => request.run_mode,
        "request_id" => request.request_id,
        "actor_id" => scope.member_id
      }
    })
  end

  defp receipt_type(%InteractionCommand{type: type}) when is_binary(type) and type != "",
    do: type

  defp receipt_type(%InteractionCommand{kind: kind}), do: Atom.to_string(kind)

  defp action_identity(%InteractionCommand{kind: :block_interaction, data: data}) do
    map_get(data, :on_action) || @picker_action
  end

  defp action_identity(%InteractionCommand{kind: :view_action, data: data}) do
    map_get(data, :view_id)
  end

  defp action_identity(%InteractionCommand{data: data}) do
    map_get(data, :alias)
  end

  defp pumble_snapshot(command, receipt) do
    %{
      "type" => receipt_type(command),
      "kind" => Atom.to_string(command.kind),
      "correlation_id" => command.correlation_id,
      "occurred_at" => DateTime.to_iso8601(command.occurred_at)
    }
    |> put_present("received_event_id", receipt && receipt.id)
    |> put_present("channel_id", command.channel_id)
    |> put_present("actor_id", command.actor_id)
    |> put_present("alias", selected_alias(command) || map_get(command.data, :alias))
    |> put_source_message(command)
  end

  defp put_source_message(snapshot, %InteractionCommand{kind: :message_shortcut} = command) do
    case {command.channel_id, command.resource_id} do
      {channel_id, message_id} when is_binary(channel_id) and is_binary(message_id) ->
        Map.put(snapshot, "source_message", %{
          "channel_id" => channel_id,
          "message_id" => message_id
        })

      _missing ->
        snapshot
    end
  end

  defp put_source_message(snapshot, _command), do: snapshot

  defp browser_snapshot(request, version, receipt) do
    %{
      "type" => "browser",
      "run_mode" => request.run_mode,
      "request_id" => request.request_id,
      "workflow_version_id" => version.id,
      "received_event_id" => receipt.id
    }
    |> put_present("alias", request.alias)
  end

  defp parse_browser(scope, attrs) do
    with {:ok, run_mode} <- required_run_mode(attrs),
         {:ok, alias_name, version_id} <- browser_target(attrs) do
      {:ok,
       %{
         run_mode: run_mode,
         alias: alias_name,
         workflow_version_id: version_id,
         request_id: browser_request_id(attrs),
         raw_body: browser_raw_body(scope, attrs)
       }}
    end
  end

  defp required_run_mode(attrs) do
    case attr(attrs, :run_mode) do
      mode when mode in ["dry_run", "live"] ->
        {:ok, mode}

      _missing ->
        {:error,
         Error.new(:validation, :invalid_run_mode,
           message: "A browser run must name dry_run or live explicitly."
         )}
    end
  end

  defp browser_target(attrs) do
    alias_name = optional_text(attr(attrs, :alias))
    version_id = attr(attrs, :workflow_version_id)

    cond do
      is_binary(alias_name) and not is_nil(version_id) ->
        {:error,
         Error.new(:validation, :ambiguous_target,
           message: "Choose a workflow by alias or by version, not both."
         )}

      is_binary(alias_name) ->
        {:ok, alias_name, nil}

      is_binary(version_id) ->
        {:ok, nil, version_id}

      true ->
        {:error,
         Error.new(:validation, :missing_target,
           message: "A browser run must name an alias or a version."
         )}
    end
  end

  defp browser_request_id(attrs) do
    optional_text(attr(attrs, :idempotency_key)) ||
      optional_text(attr(attrs, :request_id)) ||
      Ecto.UUID.generate()
  end

  defp browser_raw_body(scope, attrs) do
    [
      scope.installation_id,
      scope.member_id,
      inspect(attr(attrs, :alias)),
      inspect(attr(attrs, :workflow_version_id)),
      inspect(attr(attrs, :run_mode)),
      inspect(attr(attrs, :idempotency_key)),
      inspect(attr(attrs, :request_id))
    ]
    |> Enum.join("\n")
  end

  defp resolve_browser_version(scope, %{alias: alias_name, workflow_version_id: nil})
       when is_binary(alias_name) do
    matches = alias_matches(scope.installation_id, alias_name)

    case matches do
      [%TriggerMatcher{workflow_version_id: version_id}] ->
        fetch_version(scope.installation_id, version_id)

      [] ->
        {:error, Policy.not_found()}

      _many ->
        {:error, Policy.not_found()}
    end
  end

  defp resolve_browser_version(scope, %{workflow_version_id: version_id})
       when is_binary(version_id) do
    with {:ok, version} <- fetch_version(scope.installation_id, version_id),
         :ok <- assert_live_version(scope.installation_id, version) do
      {:ok, version}
    end
  end

  defp existing_execution(installation_id, receipt_id) do
    query =
      from execution in Execution,
        where:
          execution.installation_id == ^installation_id and
            execution.received_event_id == ^receipt_id,
        limit: 1

    case Repo.one(query) do
      %Execution{} = execution -> {:ok, execution}
      nil -> {:error, Policy.not_found()}
    end
  end

  defp fetch_version(installation_id, version_id) do
    query =
      from version in WorkflowVersion,
        where: version.id == ^version_id and version.installation_id == ^installation_id

    case Repo.one(query) do
      %WorkflowVersion{} = version -> {:ok, version}
      nil -> Scope.refuse_unknown(WorkflowVersion, version_id, installation_id, :manual_trigger)
    end
  end

  defp assert_live_version(installation_id, %WorkflowVersion{} = version) do
    query =
      from workflow in Workflow,
        where:
          workflow.id == ^version.workflow_id and workflow.installation_id == ^installation_id and
            workflow.active_version_id == ^version.id and workflow.status == "active"

    case Repo.one(query) do
      %Workflow{} -> :ok
      nil -> {:error, Policy.not_found()}
    end
  end

  defp mark_processed(receipt, count) do
    data =
      receipt.data
      |> Map.put("execution_count", count)
      |> Map.put("dispatch_cursor", count)

    case receipt
         |> ReceivedEvent.changeset(%{processing_state: "processed", data: data})
         |> Repo.update() do
      {:ok, _updated} ->
        :ok

      {:error, _changeset} ->
        {:error,
         Error.new(:internal, :receipt_update_failed,
           retryable?: true,
           message: "The receipt could not be marked processed."
         )}
    end
  end

  defp normalize(payload, installation, transport) do
    Normalizer.normalize(payload, %{
      installation_id: installation.id,
      raw_body: transport.raw_body,
      signature: transport.signature,
      received_at: transport.received_at,
      correlation_id: transport.correlation_id
    })
  end

  defp audit_denied(%InteractionCommand{} = command, %Installation{} = installation, reason) do
    Writer.append_denied(
      Map.merge(Writer.actor({:pumble, command.actor_id || "unknown"}), %{
        installation_id: installation.id,
        action: "execution.interaction_denied",
        resource_type: "installation",
        resource_id: installation.id,
        correlation_id: command.correlation_id,
        metadata: %{
          reason: reason,
          result: "denied",
          source: "pumble_callback",
          target_kind: Atom.to_string(command.kind)
        }
      })
    )
  end

  defp resolve_installation(payload) do
    workspace_id = payload.workspace_id

    query =
      from installation in Installation,
        where: installation.pumble_workspace_id == ^workspace_id

    case Repo.one(query) do
      %Installation{status: "active"} = installation -> {:ok, installation}
      _other -> :ignore
    end
  end

  defp parse_transport(context) do
    case attr(context, :raw_body) do
      raw when is_binary(raw) ->
        {:ok,
         %{
           raw_body: raw,
           signature: optional_text(attr(context, :signature)) || "",
           received_at: optional_datetime(attr(context, :received_at)) || DateTime.utc_now(),
           correlation_id: optional_text(attr(context, :correlation_id)) || Ecto.UUID.generate()
         }}

      _missing ->
        {:error,
         Error.new(:validation, :missing_body,
           message: "A receipt cannot be stored without the received bytes."
         )}
    end
  end

  defp maybe_retry_later(%Error{class: class} = error)
       when class in [:validation, :rate_limited] do
    error
  end

  defp maybe_retry_later(%Error{} = error) do
    Error.new(error.class, error.code,
      message: error.message,
      retryable?: true,
      details: error.details,
      cause: error.cause
    )
  end

  defp emit(outcome) do
    :telemetry.execute(@telemetry_event ++ [:accepted], %{count: 1}, %{outcome: outcome})
    :ok
  end

  defp picker_button(alias_name) do
    %{
      "type" => "button",
      "text" => %{"type" => "plain_text", "text" => alias_name},
      "onAction" => @picker_action,
      "value" => alias_name,
      "loadingTimeout" => 0
    }
  end

  defp stringify_keys(config) do
    Map.new(config, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp map_get(map, key) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp attr(map, key) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp optional_text(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp optional_text(_value), do: nil

  defp optional_datetime(%DateTime{} = datetime), do: datetime
  defp optional_datetime(_value), do: nil
end
