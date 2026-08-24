defmodule PumbleAutomation.Ingress.Deduplication do
  @moduledoc """
  Derives the stored identity of one ingress delivery.

  `received_events.dedup_key` is this module's output, not the
  `delivery_key` on a normalized Pumble struct. That field stays the byte
  digest from `PumbleAutomation.Pumble.Normalizer` (`I-9`) so `PR-01` can
  still compare candidates. This module chooses a *receipt* key:

    * a documented provider identity always wins over body heuristics;
    * keys that may carry secrets or attacker-controlled length are hashed
      before they touch an index;
    * a payload with no safe identity is accepted as distinct rather than
      collapsed onto another delivery.

  Nothing here claims exactly-once delivery. A duplicate callback that
  repeats a stored key becomes one receipt. A genuine event whose provider
  id is missing, unstable, or shared with another event may be stored twice.
  That is at-least-once, and it is intentional.

  ## Fallback window

  When no documented id is present, the key is `I-9` (SHA-256 of the raw
  body and signature) plus an epoch-aligned 900-second bucket. Byte-identical
  retries inside the window collapse. The same bytes after the window are a
  new receipt, so a body hash cannot suppress a later legitimate event
  forever. The strategy and the window length are emitted on
  `[:pumble_automation, :ingress, :dedup, :key]`.
  """

  import Ecto.Query, only: [from: 2]

  alias PumbleAutomation.Error
  alias PumbleAutomation.Ingress.ReceivedEvent
  alias PumbleAutomation.Pumble.Normalizer
  alias PumbleAutomation.Repo

  # PR-02 looks for retries inside ten minutes. Fifteen minutes covers that
  # horizon without turning a body digest into a permanent identity.
  @fallback_window_seconds 900
  @max_input_bytes 1024
  @max_provider_id 256
  @max_type 64
  @max_dedup_key 128

  @telemetry_event [:pumble_automation, :ingress, :dedup]

  @default_provider %{
    "event" => "pumble",
    "interaction" => "pumble",
    "lifecycle" => "pumble",
    "webhook" => "webhook",
    "manual" => "browser",
    "schedule" => "schedule"
  }

  @typedoc """
  How the stored key was chosen.

    * `:provider_id` — documented request id (`rid`) plus class and type.
    * `:interaction_identity` — trigger id plus documented action identity.
      `sourceId` is an object id, not a delivery id, and is never used.
    * `:lifecycle` — provider event id, install identifiers, and terminal type.
    * `:fallback` — `I-9` digest plus the bounded time bucket.
    * `:idempotency_key` — hashed `Idempotency-Key` scoped to the endpoint.
    * `:distinct` — no safe identity; each call is a new receipt.
    * `:schedule` — schedule id plus the scheduled-for UTC instant.
    * `:manual` — caller-supplied one-time request id.
  """
  @type strategy ::
          :provider_id
          | :interaction_identity
          | :lifecycle
          | :fallback
          | :idempotency_key
          | :distinct
          | :schedule
          | :manual

  @type t :: %__MODULE__{
          dedup_key: String.t(),
          strategy: strategy(),
          provider_id: String.t() | nil,
          window_started_at: DateTime.t() | nil
        }

  @enforce_keys [:dedup_key, :strategy]
  defstruct [:dedup_key, :strategy, :provider_id, :window_started_at]

  @doc """
  Builds the stored key for one delivery.

  `request` is a map. Required: `:installation_id`, `:class`, `:type`.
  Class-specific identity fields are listed in
  `docs/architecture/delivery_semantics.md`.
  """
  @spec key(map()) :: {:ok, t()} | {:error, Error.t()}
  def key(request) when is_map(request) do
    with {:ok, parsed} <- parse(request) do
      derived = derive(parsed)
      :ok = emit_key(derived, parsed)
      {:ok, derived}
    end
  end

  @doc """
  Inserts a receipt for `request`, collapsing on the derived key.

  Returns `{:ok, :new, event}` on the first insert and
  `{:ok, :duplicate, event}` when the unique index already holds the key.
  A duplicate whose raw-body digest does not match the stored digest emits
  `[:pumble_automation, :ingress, :dedup, :integrity_anomaly]` and still
  returns the existing row. The second body is not stored.
  """
  @spec record(map()) :: {:ok, :new | :duplicate, ReceivedEvent.t()} | {:error, Error.t()}
  def record(request) when is_map(request) do
    with {:ok, parsed} <- parse(request) do
      derived = derive(parsed)
      :ok = emit_key(derived, parsed)
      insert_receipt(parsed, derived)
    end
  end

  @doc "The fallback time bucket, in seconds."
  @spec fallback_window_seconds() :: pos_integer()
  def fallback_window_seconds, do: @fallback_window_seconds

  @doc "The cap applied to attacker-controlled identity strings before hashing."
  @spec max_input_bytes() :: pos_integer()
  def max_input_bytes, do: @max_input_bytes

  @doc "Telemetry prefix for key choice and integrity anomalies."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  defp parse(request) do
    with {:ok, installation_id} <- required_installation(request),
         {:ok, class} <- required_enum(request, :class, ReceivedEvent.classes(), :invalid_class),
         {:ok, type} <- required_type(request),
         {:ok, provider} <- optional_provider(request, class) do
      parsed = %{
        installation_id: installation_id,
        provider: provider,
        class: class,
        type: type,
        raw_body: optional_binary(request, :raw_body),
        signature: optional_binary(request, :signature) || "",
        received_at: optional_datetime(request, :received_at) || DateTime.utc_now(),
        occurred_at: optional_datetime(request, :occurred_at),
        provider_id: bounded_text(attr(request, :provider_id)),
        action_identity: bounded_text(attr(request, :action_identity)),
        workspace_id: bounded_text(attr(request, :workspace_id)),
        terminal_state: bounded_text(attr(request, :terminal_state)),
        idempotency_key: bounded_text(attr(request, :idempotency_key)),
        endpoint_id: bounded_text(attr(request, :endpoint_id)),
        schedule_id: bounded_text(attr(request, :schedule_id)),
        scheduled_for: optional_datetime(request, :scheduled_for),
        request_id: bounded_text(attr(request, :request_id)),
        data: optional_map(request, :data)
      }

      validate_class_fields(parsed)
    end
  end

  defp validate_class_fields(
         %{class: "schedule", schedule_id: id, scheduled_for: %DateTime{}} = parsed
       )
       when is_binary(id) do
    {:ok, parsed}
  end

  defp validate_class_fields(%{class: "schedule"}) do
    {:error,
     Error.new(:validation, :missing_schedule_identity,
       message: "A schedule delivery must name the schedule and the scheduled instant."
     )}
  end

  defp validate_class_fields(%{class: "webhook", endpoint_id: id} = parsed) when is_binary(id) do
    {:ok, parsed}
  end

  defp validate_class_fields(%{class: "webhook"}) do
    {:error,
     Error.new(:validation, :missing_endpoint,
       message: "A webhook delivery must name its endpoint."
     )}
  end

  defp validate_class_fields(parsed), do: {:ok, parsed}

  defp derive(%{class: "event"} = parsed) do
    case parsed.provider_id do
      id when is_binary(id) ->
        stored("pid", :provider_id, ["event", parsed.type, id], id)

      nil ->
        fallback_or_distinct(parsed)
    end
  end

  defp derive(%{class: "interaction"} = parsed) do
    case parsed.provider_id do
      id when is_binary(id) ->
        parts = ["interaction", parsed.type, id] ++ optional_part(parsed.action_identity)
        stored("int", :interaction_identity, parts, id)

      nil ->
        fallback_or_distinct(parsed)
    end
  end

  defp derive(%{class: "lifecycle"} = parsed) do
    case parsed.provider_id do
      id when is_binary(id) ->
        stored(
          "lc",
          :lifecycle,
          [
            "lifecycle",
            parsed.type,
            id,
            parsed.workspace_id || "",
            parsed.terminal_state || parsed.type
          ],
          id
        )

      nil ->
        fallback_or_distinct(parsed)
    end
  end

  defp derive(%{class: "webhook"} = parsed) do
    case parsed.idempotency_key do
      key when is_binary(key) ->
        %__MODULE__{
          dedup_key: hash_key("ik", ["webhook", parsed.endpoint_id, key]),
          strategy: :idempotency_key,
          provider_id: nil,
          window_started_at: nil
        }

      nil ->
        distinct()
    end
  end

  defp derive(%{class: "schedule"} = parsed) do
    instant = Integer.to_string(DateTime.to_unix(parsed.scheduled_for, :microsecond))

    stored("sch", :schedule, ["schedule", parsed.schedule_id, instant], parsed.schedule_id)
  end

  defp derive(%{class: "manual"} = parsed) do
    case parsed.request_id do
      id when is_binary(id) ->
        stored("man", :manual, ["manual", id], id)

      nil ->
        distinct()
    end
  end

  defp fallback_or_distinct(%{raw_body: raw} = parsed) when is_binary(raw) do
    bucket = bucket(parsed.received_at)
    digest = Normalizer.delivery_key(raw, parsed.signature)

    %__MODULE__{
      dedup_key:
        hash_key("fb", [
          "fallback",
          parsed.class,
          parsed.type,
          digest,
          Integer.to_string(bucket)
        ]),
      strategy: :fallback,
      provider_id: nil,
      window_started_at: DateTime.from_unix!(bucket * @fallback_window_seconds)
    }
  end

  defp fallback_or_distinct(_parsed), do: distinct()

  defp distinct do
    %__MODULE__{
      dedup_key: hash_key("dt", ["distinct", Ecto.UUID.generate()]),
      strategy: :distinct,
      provider_id: nil,
      window_started_at: nil
    }
  end

  defp stored(tag, strategy, parts, provider_id) do
    %__MODULE__{
      dedup_key: hash_key(tag, parts),
      strategy: strategy,
      provider_id: stored_provider_id(provider_id),
      window_started_at: nil
    }
  end

  defp insert_receipt(parsed, derived) do
    with {:ok, attrs} <- receipt_attrs(parsed, derived) do
      %ReceivedEvent{}
      |> ReceivedEvent.changeset(attrs)
      |> Repo.insert()
      |> finish_record(parsed, derived, attrs)
    end
  end

  defp receipt_attrs(parsed, derived) do
    case parsed.raw_body do
      raw when is_binary(raw) ->
        {:ok,
         %{
           installation_id: parsed.installation_id,
           provider: parsed.provider,
           class: parsed.class,
           type: parsed.type,
           dedup_key: derived.dedup_key,
           provider_id: derived.provider_id,
           raw_body_hash: ReceivedEvent.hash_body(raw),
           data: parsed.data,
           received_at: parsed.received_at,
           occurred_at: parsed.occurred_at || parsed.received_at
         }}

      _missing ->
        {:error,
         Error.new(:validation, :missing_body,
           message: "A receipt cannot be stored without the received bytes."
         )}
    end
  end

  defp finish_record({:ok, event}, parsed, derived, _attrs) do
    emit_record("new", parsed, derived)
    {:ok, :new, event}
  end

  defp finish_record({:error, changeset}, parsed, derived, attrs) do
    if violated?(changeset, "received_events_installation_id_provider_dedup_key_index") do
      resolve_duplicate(parsed, derived, attrs)
    else
      {:error,
       Error.new(:validation, :invalid_receipt, message: "The receipt could not be stored.")}
    end
  end

  defp resolve_duplicate(parsed, derived, attrs) do
    case fetch_existing(parsed.installation_id, parsed.provider, derived.dedup_key) do
      {:ok, existing} ->
        if existing.raw_body_hash != attrs.raw_body_hash do
          :ok = emit_anomaly(parsed, derived)
        end

        emit_record("duplicate", parsed, derived)
        {:ok, :duplicate, existing}

      {:error, error} ->
        {:error, error}
    end
  end

  defp fetch_existing(installation_id, provider, dedup_key) do
    query =
      from event in ReceivedEvent,
        where:
          event.installation_id == ^installation_id and event.provider == ^provider and
            event.dedup_key == ^dedup_key

    case Repo.one(query) do
      %ReceivedEvent{} = event ->
        {:ok, event}

      nil ->
        {:error,
         Error.new(:conflict, :dedup_key_taken,
           retryable?: true,
           message: "Another receipt with that key is already being stored. Try again."
         )}
    end
  end

  defp emit_key(derived, parsed) do
    :telemetry.execute(
      @telemetry_event ++ [:key],
      %{count: 1},
      %{
        provider: parsed.provider,
        class: parsed.class,
        strategy: derived.strategy,
        fallback?: derived.strategy == :fallback,
        window_seconds: if(derived.strategy == :fallback, do: @fallback_window_seconds, else: nil)
      }
    )

    :ok
  end

  defp emit_anomaly(parsed, derived) do
    :telemetry.execute(
      @telemetry_event ++ [:integrity_anomaly],
      %{count: 1},
      %{
        provider: parsed.provider,
        class: parsed.class,
        type: parsed.type,
        strategy: derived.strategy
      }
    )

    :ok
  end

  defp emit_record(outcome, parsed, derived) do
    PumbleAutomation.Telemetry.execute(
      @telemetry_event ++ [:record],
      %{count: 1},
      %{
        outcome: outcome,
        class: parsed.class,
        type: parsed.type,
        kind: derived.strategy,
        installation_id: parsed.installation_id
      }
    )
  end

  defp hash_key(tag, parts) do
    digest = :crypto.hash(:sha256, Enum.intersperse(parts, <<0x1F>>))
    key = tag <> ":" <> Base.encode16(digest, case: :lower)
    if byte_size(key) <= @max_dedup_key, do: key, else: binary_part(key, 0, @max_dedup_key)
  end

  defp bucket(%DateTime{} = received_at) do
    div(DateTime.to_unix(received_at, :second), @fallback_window_seconds)
  end

  defp stored_provider_id(id) when is_binary(id), do: valid_prefix(id, @max_provider_id)

  defp optional_part(nil), do: []
  defp optional_part(value) when is_binary(value), do: [value]

  defp required_installation(request) do
    case attr(request, :installation_id) do
      id when is_binary(id) and id != "" ->
        case Ecto.UUID.cast(id) do
          {:ok, id} ->
            {:ok, id}

          :error ->
            {:error,
             Error.new(:validation, :invalid_installation,
               message: "The delivery is not scoped to an installation."
             )}
        end

      _missing ->
        {:error,
         Error.new(:validation, :missing_installation,
           message: "The delivery is not scoped to an installation."
         )}
    end
  end

  defp required_enum(request, field, allowed, code) do
    case attr(request, field) do
      value when is_atom(value) ->
        required_enum(%{field => Atom.to_string(value)}, field, allowed, code)

      value when is_binary(value) ->
        if value in allowed do
          {:ok, value}
        else
          {:error, Error.new(:validation, code, message: "The delivery class is not accepted.")}
        end

      _other ->
        {:error, Error.new(:validation, code, message: "The delivery class is not accepted.")}
    end
  end

  defp required_type(request) do
    case attr(request, :type) do
      type when is_binary(type) and byte_size(type) >= 1 and byte_size(type) <= @max_type ->
        {:ok, type}

      _other ->
        {:error, Error.new(:validation, :missing_type, message: "The delivery has no type.")}
    end
  end

  defp optional_provider(request, class) do
    allowed = ReceivedEvent.providers()

    case attr(request, :provider) do
      nil ->
        {:ok, Map.fetch!(@default_provider, class)}

      value when is_atom(value) ->
        optional_provider(%{provider: Atom.to_string(value)}, class)

      value when is_binary(value) ->
        if value in allowed do
          {:ok, value}
        else
          {:error,
           Error.new(:validation, :invalid_provider,
             message: "The delivery provider is not accepted."
           )}
        end

      _other ->
        {:error,
         Error.new(:validation, :invalid_provider,
           message: "The delivery provider is not accepted."
         )}
    end
  end

  defp optional_binary(request, field) do
    case attr(request, field) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp optional_datetime(request, field) do
    case attr(request, field) do
      %DateTime{} = datetime -> datetime
      _other -> nil
    end
  end

  defp optional_map(request, field) do
    case attr(request, field) do
      value when is_map(value) and not is_struct(value) -> value
      _other -> %{}
    end
  end

  defp bounded_text(value) when is_binary(value) do
    trimmed = if String.valid?(value), do: String.trim(value), else: value
    bounded = valid_prefix(trimmed, @max_input_bytes)

    if bounded == "", do: nil, else: bounded
  end

  defp bounded_text(_value), do: nil

  defp valid_prefix(value, max) do
    value
    |> binary_part(0, min(byte_size(value), max))
    |> :unicode.characters_to_binary(:utf8, :utf8)
    |> case do
      valid when is_binary(valid) -> valid
      {:incomplete, valid, _rest} -> valid
      {:error, valid, _rest} -> valid
    end
  end

  defp attr(request, key) when is_atom(key) do
    Map.get(request, key, Map.get(request, Atom.to_string(key)))
  end

  defp violated?(%Ecto.Changeset{errors: errors}, name) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint_name) == name
    end)
  end
end
