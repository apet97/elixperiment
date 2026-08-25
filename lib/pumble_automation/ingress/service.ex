defmodule PumbleAutomation.Ingress.Service do
  @moduledoc """
  The boundary between the callback transport and the automation domain.

  The controller's job ends here. It verifies, decodes, classifies, hands the
  typed payload plus the retained raw bytes to one of the two functions below,
  and answers Pumble. What happens to the payload afterwards is this module's
  problem, and the controller is deliberately given no way to find out — a
  controller that could wait for ingestion would eventually be made to.

  ## Event ingestion

  `enqueue_event/2` is the event-to-execution consistency boundary. For a
  verified Pumble event it:

    * resolves the installation from the workspace id and ignores inactive
      tenants;
    * normalizes through `PumbleAutomation.Pumble.Normalizer`;
    * inserts a `received_events` row through
      `PumbleAutomation.Ingress.Deduplication` (never through
      `Normalizer.delivery_key/2`);
    * matches live bindings through `PumbleAutomation.Ingress.TriggerMatcher`;
    * creates one execution plus initial Oban job per match via
      `PumbleAutomation.Executions.Engine.create/2`;
    * marks the receipt `processed` with the execution count.

  A duplicate callback whose receipt is already `processed` returns
  `:accepted` and creates nothing. A crash after the receipt insert leaves
  the row `received`; the next call is the resume. Execution keys are
  `recv:<receipt-id>:<binding-id>`, so a retry cannot insert a second run
  for a match that already committed.

  One event creates at most `max_executions_per_event/0` runs. Matcher order
  is stable, so the cap is deterministic.

  The ingress acknowledgement contract forbids any call to Pumble or another
  external service on this path.

  ## Lifecycle callbacks

  `APP_UNINSTALLED` and `APP_UNAUTHORIZED` are classified before trigger
  matching. They are deduplicated as class `lifecycle` and applied through
  `PumbleAutomation.Installations.Service.apply_lifecycle/3`. No user
  execution is created. The transport may acknowledge only after the
  installation is durably blocked and its credentials are unusable.

  An unknown workspace is acknowledged and counted as an anomaly. It does
  not create a tenant.

  `record_interaction/2` turns a slash command, shortcut, or picker
  selection into the same durable receipt-and-execution path. Unknown or
  disabled aliases answer `:not_found` rather than starting a run.
  """

  import Ecto.Query, only: [from: 2]

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.Engine
  alias PumbleAutomation.Executions.Lineage
  alias PumbleAutomation.Ingress.AutomationEvent
  alias PumbleAutomation.Ingress.Deduplication
  alias PumbleAutomation.Ingress.LifecycleCommand
  alias PumbleAutomation.Ingress.ManualTrigger
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.Ingress.TriggerMatcher
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Service, as: InstallationsService
  alias PumbleAutomation.Pumble.Normalizer
  alias PumbleAutomation.Pumble.Payload
  alias PumbleAutomation.Repo

  @max_executions_per_event 50
  @telemetry_event [:pumble_automation, :ingress, :enqueue]

  @typedoc """
  What the boundary can answer.

  `:accepted` means the transport may acknowledge. A retryable `{:error, _}`
  means the durable write did not finish and the caller should fail the
  callback so the provider retries.
  """
  @type outcome :: :accepted | {:error, PumbleAutomation.Error.t()}

  @typedoc "The retained transport bytes a callback already verified."
  @type context :: %{
          optional(:raw_body) => binary(),
          optional(:signature) => binary(),
          optional(:received_at) => DateTime.t(),
          optional(:correlation_id) => String.t(),
          optional(:after_receipt) => (-> any())
        }

  @doc """
  Accepts one classified Pumble event for durable ingestion.

  `context` must include the exact `:raw_body` the signature plug verified.
  `:signature` and `:received_at` are optional; a missing signature is treated
  as empty bytes so the I-9 fallback still hashes.
  """
  @spec enqueue_event(Payload.Event.t(), context()) :: outcome()
  def enqueue_event(%Payload.Event{} = event, context \\ %{}) when is_map(context) do
    with {:ok, transport} <- parse_transport(context) do
      ingest(event, transport)
    end
  end

  @doc """
  Records the intent behind one interactive callback.

  Returns a tagged result the controller maps onto a protocol response. A
  started or duplicate run may be acknowledged. A picker is a modal envelope
  and is not an acknowledgement that a run started. Unknown aliases are
  `:not_found`. A retryable error means the durable write did not finish.
  """
  @spec record_interaction(Payload.t(), context()) :: ManualTrigger.accept_result()
  def record_interaction(payload, context \\ %{}) when is_struct(payload) do
    ManualTrigger.accept(payload, context)
  end

  @doc "How many executions one event is allowed to start."
  @spec max_executions_per_event() :: pos_integer()
  def max_executions_per_event, do: @max_executions_per_event

  @doc "Telemetry prefix for receipt-insert and processed-count events."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  defp ingest(event, transport) do
    if lifecycle_event?(event) do
      ingest_lifecycle(event, transport)
    else
      ingest_trigger(event, transport)
    end
  end

  defp lifecycle_event?(%Payload.Event{event_type: type}) do
    type in Payload.lifecycle_event_types()
  end

  defp ingest_trigger(event, transport) do
    case resolve_installation(event.workspace_id) do
      {:ok, installation} -> accept_event(event, installation, transport)
      :ignore -> :accepted
    end
  end

  defp ingest_lifecycle(event, transport) do
    case InstallationsService.fetch_by_workspace_id(event.workspace_id) do
      {:ok, installation} -> accept_lifecycle(event, installation, transport)
      :error -> acknowledge_unknown_lifecycle(event)
    end
  end

  defp acknowledge_unknown_lifecycle(%Payload.Event{} = event) do
    :telemetry.execute(
      @telemetry_event ++ [:unknown_workspace],
      %{count: 1},
      %{class: "lifecycle", type: event.event_type}
    )

    :accepted
  end

  defp accept_event(event, installation, transport) do
    with {:ok, normalized} <- normalize(event, installation, transport),
         {:ok, kind, receipt} <- record_receipt(normalized, installation, transport) do
      finish_receipt(kind, receipt, installation, normalized, transport)
    end
  end

  defp finish_receipt(
         _kind,
         %ReceivedEvent{processing_state: "processed"},
         _installation,
         _normalized,
         _transport
       ) do
    :accepted
  end

  defp finish_receipt(:new, receipt, installation, normalized, transport) do
    emit_receipt(receipt)
    interrupt_after_receipt!(transport)
    dispatch_and_finish(receipt, installation, normalized)
  end

  defp finish_receipt(:duplicate, receipt, installation, normalized, _transport) do
    dispatch_and_finish(receipt, installation, normalized)
  end

  defp accept_lifecycle(event, installation, transport) do
    case normalize(event, installation, transport) do
      {:ok, %LifecycleCommand{} = command} ->
        persist_lifecycle(command, installation, transport)

      {:ok, _other} ->
        retry_later(
          Error.new(:internal, :lifecycle_misrouted,
            message: "A lifecycle callback was routed as a workflow trigger."
          )
        )

      {:error, error} ->
        {:error, error}
    end
  end

  defp persist_lifecycle(command, installation, transport) do
    with {:ok, kind, receipt} <- record_receipt(command, installation, transport) do
      finish_lifecycle(kind, receipt, installation, command, transport)
    end
  end

  defp finish_lifecycle(
         _kind,
         %ReceivedEvent{processing_state: "processed"},
         _installation,
         _command,
         _transport
       ) do
    :accepted
  end

  defp finish_lifecycle(:new, receipt, installation, command, transport) do
    emit_receipt(receipt)
    interrupt_after_receipt!(transport)
    apply_and_finish(receipt, installation, command)
  end

  defp finish_lifecycle(:duplicate, receipt, installation, command, _transport) do
    apply_and_finish(receipt, installation, command)
  end

  defp apply_and_finish(receipt, installation, command) do
    case apply_lifecycle(installation, command) do
      {:ok, _installation} -> mark_processed(receipt, 0)
      {:error, %Error{code: :installation_not_found}} -> mark_processed(receipt, 0)
      {:error, %Error{} = error} -> retry_later(error)
    end
  end

  defp apply_lifecycle(installation, %LifecycleCommand{} = command) do
    InstallationsService.apply_lifecycle(installation.id, command.type,
      source: "pumble_callback",
      correlation_id: command.correlation_id
    )
  end

  defp retry_later(%Error{} = error) do
    {:error,
     Error.new(error.class, error.code,
       message: error.message,
       retryable?: true,
       details: error.details,
       cause: error.cause
     )}
  end

  defp interrupt_after_receipt!(%{after_receipt: fun}) when is_function(fun, 0), do: fun.()
  defp interrupt_after_receipt!(_transport), do: :ok

  defp dispatch_and_finish(receipt, installation, normalized) do
    matches = take_matches(normalized)
    snapshot = trigger_snapshot(normalized, receipt)

    case create_all(installation.id, receipt, matches, snapshot) do
      {:ok, count} -> mark_processed(receipt, count)
      {:error, error} -> {:error, error}
    end
  end

  defp take_matches(normalized) do
    normalized
    |> TriggerMatcher.match()
    |> Enum.take(@max_executions_per_event)
  end

  defp create_all(installation_id, receipt, matches, snapshot) do
    Enum.reduce_while(matches, {:ok, 0}, fn match, {:ok, count} ->
      installation_id
      |> create_match(receipt, match, snapshot)
      |> tally_create(count)
    end)
  end

  defp tally_create({:ok, _execution}, count), do: {:cont, {:ok, count + 1}}

  defp tally_create({:error, %Error{} = error}, count) do
    if skip_create?(error), do: {:cont, {:ok, count}}, else: {:halt, {:error, error}}
  end

  defp skip_create?(%Error{code: code}) do
    code in [:not_active, :version_mismatch, :not_found] or
      code in Lineage.skip_create_codes()
  end

  defp create_match(installation_id, receipt, match, snapshot) do
    Engine.create(installation_id, %{
      workflow_version_id: match.workflow_version_id,
      execution_key: execution_key(receipt, match),
      received_event_id: receipt.id,
      trigger_snapshot: Map.put(snapshot, "binding_id", match.binding_id),
      run_mode: "live",
      lineage_source: :pumble_event
    })
  end

  defp execution_key(%ReceivedEvent{id: receipt_id}, %TriggerMatcher{binding_id: binding_id}) do
    "recv:" <> receipt_id <> ":" <> binding_id
  end

  defp mark_processed(receipt, count) do
    data =
      receipt.data
      |> Map.put("execution_count", count)
      |> Map.put("dispatch_cursor", count)

    receipt
    |> ReceivedEvent.changeset(%{processing_state: "processed", data: data})
    |> Repo.update()
    |> case do
      {:ok, _updated} ->
        emit_processed(receipt, count)
        :accepted

      {:error, _changeset} ->
        {:error,
         Error.new(:internal, :receipt_update_failed,
           retryable?: true,
           message: "The receipt could not be marked processed."
         )}
    end
  end

  defp record_receipt(normalized, installation, transport) do
    Deduplication.record(receipt_request(normalized, installation, transport))
  end

  defp receipt_request(normalized, installation, transport) do
    identity = identity_fields(normalized)

    Map.merge(
      %{
        installation_id: installation.id,
        class: receipt_class(normalized),
        type: receipt_type(normalized),
        provider: "pumble",
        raw_body: transport.raw_body,
        signature: transport.signature,
        received_at: transport.received_at,
        occurred_at: normalized.occurred_at,
        data: trigger_snapshot(normalized, nil)
      },
      identity
    )
  end

  defp identity_fields(%AutomationEvent{data: data}) do
    %{provider_id: map_get(data, :provider_request_id)}
  end

  defp identity_fields(%LifecycleCommand{} = command) do
    %{
      provider_id: command.provider_event_id,
      workspace_id: command.workspace_id,
      terminal_state: command.type
    }
  end

  defp receipt_class(%AutomationEvent{}), do: "event"
  defp receipt_class(%LifecycleCommand{}), do: "lifecycle"

  defp receipt_type(%AutomationEvent{type: type}), do: type
  defp receipt_type(%LifecycleCommand{type: type}), do: type

  defp trigger_snapshot(normalized, receipt) do
    normalized
    |> snapshot_fields()
    |> put_present("received_event_id", receipt && receipt.id)
  end

  defp snapshot_fields(%AutomationEvent{} = event) do
    %{
      "type" => event.type,
      "correlation_id" => event.correlation_id,
      "occurred_at" => DateTime.to_iso8601(event.occurred_at),
      "occurred_at_source" => Atom.to_string(event.occurred_at_source)
    }
    |> put_present("channel_id", event.channel_id)
    |> put_present("actor_id", event.actor_id)
    |> put_present("resource_id", event.resource_id)
    |> put_present("thread_root_id", event.thread_root_id)
    |> put_present("bot_origin", event.bot_origin?)
    |> put_present("text", event_text(event))
  end

  defp snapshot_fields(%LifecycleCommand{} = command) do
    %{
      "type" => command.type,
      "correlation_id" => command.correlation_id,
      "occurred_at" => DateTime.to_iso8601(command.occurred_at),
      "occurred_at_source" => Atom.to_string(command.occurred_at_source)
    }
    |> put_present("workspace_id", command.workspace_id)
    |> put_present("provider_event_id", command.provider_event_id)
  end

  defp event_text(%AutomationEvent{data: data}), do: map_get(data, :text)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp normalize(event, installation, transport) do
    Normalizer.normalize(event, %{
      installation_id: installation.id,
      raw_body: transport.raw_body,
      signature: transport.signature,
      received_at: transport.received_at,
      correlation_id: transport.correlation_id,
      bot_user_id: installation.bot_user_id
    })
  end

  defp resolve_installation(workspace_id) when is_binary(workspace_id) do
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
           signature: optional_binary(attr(context, :signature)) || "",
           received_at: optional_datetime(attr(context, :received_at)) || DateTime.utc_now(),
           correlation_id:
             optional_binary(attr(context, :correlation_id)) || Ecto.UUID.generate(),
           after_receipt: attr(context, :after_receipt)
         }}

      _missing ->
        {:error,
         Error.new(:validation, :missing_body,
           message: "A receipt cannot be stored without the received bytes."
         )}
    end
  end

  defp emit_receipt(receipt) do
    :telemetry.execute(
      @telemetry_event ++ [:receipt],
      %{count: 1},
      %{class: receipt.class, type: receipt.type, processing_state: receipt.processing_state}
    )

    :ok
  end

  defp emit_processed(receipt, count) do
    :telemetry.execute(
      @telemetry_event ++ [:processed],
      %{count: count},
      %{class: receipt.class, type: receipt.type}
    )

    :ok
  end

  defp map_get(map, key) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp attr(map, key) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp optional_binary(value) when is_binary(value) and value != "", do: value
  defp optional_binary(_value), do: nil

  defp optional_datetime(%DateTime{} = datetime), do: datetime
  defp optional_datetime(_value), do: nil
end
