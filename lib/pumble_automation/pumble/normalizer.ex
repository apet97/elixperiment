defmodule PumbleAutomation.Pumble.Normalizer do
  @moduledoc """
  Translates a classified Pumble payload into this application's own vocabulary.

  This module is the adapter boundary. Everything on its input side speaks
  Pumble — `aId`, `cId`, `tx`, `mId`, `tsm` — and nothing on its output side
  does. That is not a style preference: a workflow condition written against
  `aId` would have to be rewritten if Pumble renamed the field, and a second
  provider could never satisfy it.

  Three shapes come out, and which one is not a detail:

    * `PumbleAutomation.Ingress.AutomationEvent` for the five user-selectable
      trigger events (`E-1` to `E-5`);
    * `PumbleAutomation.Ingress.LifecycleCommand` for `APP_UNINSTALLED` and
      `APP_UNAUTHORIZED` (`L-1`, `L-2`), which the product contract forbids as
      triggers;
    * `PumbleAutomation.Ingress.InteractionCommand` for every interactive class.

  ## The delivery key

  `:delivery_key` is `"sha256:"` followed by the lowercase hex digest of the
  exact received bytes and the received signature. This is evidence row `I-9`,
  and it is deliberately not any of the identity fields the payloads carry:

    * `rid` (`I-1`, on all five abbreviated event payloads) is declared and
      commented "request id" in the SDK, and nothing states it is unique or that
      it repeats on a redelivery.
    * `mId` with `tsm` (`I-2`) identifies a message, not a delivery; an edit
      reuses `mId`.
    * `triggerId` (`I-3` to `I-7`) is an addressing token the SDK echoes back
      into modal and menu envelopes. It is never used for deduplication there.
    * `sourceId` (`I-5`) is the source object id — a message id or a parent view
      id — and is not a delivery identifier at all.
    * `id` on the two lifecycle payloads (`I-8`) is unstated in the same way.

  Every one of those is `PROBE REQUIRED` under `PR-01`. The byte digest is
  weaker — a genuine redelivery with a different signature or a re-serialized
  body would not collide with the first — but it is provably correct for a
  byte-identical redelivery, which is the only redelivery anyone can currently
  demonstrate. The candidates are carried in `:data` as `:provider_request_id`
  and friends, so `PR-01` can be answered from stored data and this choice
  revisited in one place.

  ## Time

  Provider time is preferred and used only when it parses into a plausible
  instant: epoch milliseconds as an integer or a digit string, or an ISO 8601
  string, landing between the years 2000 and 2100. `uninstalledAt` is typed
  `Date` in the SDK and its wire encoding is not proven (`L-1` note), which is
  why both encodings are accepted. Anything else falls back to the receive time
  and `:occurred_at_source` records `:received`, so a fallback is visible rather
  than inferred from a suspicious value.

  ## Bot origin

  `:bot_origin?` is set only from the proven rule (`N-4`, `N-7`): the message
  author id equals the bot user id stored at token exchange. Subtype, a
  payload `bot` flag, and any lineage-shaped field are ignored. When the
  caller passes no `:bot_user_id`, or the event carries no author, the field
  stays `nil` — the question was not answered, which is different from
  answering "no".

  ## Bounded data

  `:data` is capped at thirty-two keys, string values at 4 KiB, and lists at 32
  elements; nested values are flattened away rather than walked deeply. The cap
  exists because the map is persisted and logged, and a callback body is
  attacker-influenced input of up to a megabyte.

  No credential ever enters `:data`. The only credential-shaped field any
  callback carries is `grantedScopes` on `APP_UNAUTHORIZED`, which is a list of
  scope names and not a secret.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Ingress.AutomationEvent
  alias PumbleAutomation.Ingress.InteractionCommand
  alias PumbleAutomation.Ingress.LifecycleCommand
  alias PumbleAutomation.Pumble.Payload

  @max_data_keys 32
  @max_binary_bytes 4096
  @max_list_length 32
  @untrusted_data_keys MapSet.new([
                         :lineage_depth,
                         :root_execution_id,
                         :parent_execution_id,
                         :lineage,
                         :bot_origin
                       ])

  @min_unix_ms 946_684_800_000
  @max_unix_ms 4_102_444_800_000

  @typedoc """
  What normalization needs beyond the payload itself.

    * `:installation_id` — the resolved tenant. Required.
    * `:raw_body` and `:signature` — the exact received bytes and the received
      signature header, which together form the delivery key.
    * `:received_at` — the reference time. Defaults to now.
    * `:correlation_id` — carried through unchanged.
    * `:bot_user_id` — the stored bot user id, when the caller has it.
  """
  @type context :: %{
          optional(:received_at) => DateTime.t(),
          optional(:correlation_id) => String.t() | nil,
          optional(:bot_user_id) => String.t() | nil,
          required(:installation_id) => Ecto.UUID.t(),
          required(:raw_body) => binary(),
          required(:signature) => binary()
        }

  @typedoc "Everything normalization can produce."
  @type normalized :: AutomationEvent.t() | LifecycleCommand.t() | InteractionCommand.t()

  @doc """
  Normalizes one classified payload.

  Returns a permanent `:validation` error when the context cannot scope the
  result: an event with no tenant is an event no workflow may see, and retrying
  it would fail identically.
  """
  @spec normalize(Payload.t(), context()) :: {:ok, normalized()} | {:error, Error.t()}
  def normalize(payload, context) do
    with {:ok, scope} <- scope(context) do
      {:ok, build(payload, scope)}
    end
  end

  @doc "The cap on the number of keys `:data` may carry."
  @spec max_data_keys() :: pos_integer()
  def max_data_keys, do: @max_data_keys

  @doc "The cap on the byte size of any one string in `:data`."
  @spec max_binary_bytes() :: pos_integer()
  def max_binary_bytes, do: @max_binary_bytes

  @doc """
  The delivery key for the exact bytes of one callback (`I-9`).

  Exposed so that a caller which already has the bytes — a dedupe check, a test
  — derives the key the same way instead of rebuilding the rule.
  """
  @spec delivery_key(binary(), binary()) :: String.t()
  def delivery_key(raw_body, signature) when is_binary(raw_body) and is_binary(signature) do
    digest = :crypto.hash(:sha256, [raw_body, <<0x1F>>, signature])

    "sha256:" <> Base.encode16(digest, case: :lower)
  end

  defp scope(
         %{installation_id: installation_id, raw_body: raw_body, signature: signature} = context
       )
       when is_binary(installation_id) and installation_id != "" and is_binary(raw_body) and
              is_binary(signature) do
    {:ok,
     %{
       installation_id: installation_id,
       delivery_key: delivery_key(raw_body, signature),
       received_at: received_at(context),
       correlation_id: optional_string(context, :correlation_id),
       bot_user_id: optional_string(context, :bot_user_id)
     }}
  end

  defp scope(context) when is_map(context) do
    {:error,
     Error.new(:validation, :unmappable_identity,
       message: "The callback could not be scoped to an installation.",
       retryable?: false
     )}
  end

  defp build(payload, scope), do: shape(payload, scope)

  defp received_at(%{received_at: %DateTime{} = received_at}), do: received_at
  defp received_at(_context), do: DateTime.utc_now()

  defp optional_string(context, key) do
    case Map.get(context, key) do
      value when is_binary(value) -> value
      _absent_or_wrong_type -> nil
    end
  end

  defp shape(%Payload.Event{event_type: type} = event, scope) do
    if type in Payload.lifecycle_event_types() do
      lifecycle(event, scope)
    else
      automation_event(event, scope)
    end
  end

  defp shape(%Payload.SlashCommand{} = payload, scope) do
    interaction(scope, %{
      kind: :slash_command,
      type: payload.slash_command,
      workspace_id: payload.workspace_id,
      actor_id: payload.user_id,
      channel_id: payload.channel_id,
      thread_root_id: payload.thread_root_id,
      trigger_id: payload.trigger_id,
      data: %{slash_command: payload.slash_command, text: payload.text}
    })
  end

  defp shape(%Payload.GlobalShortcut{} = payload, scope) do
    interaction(scope, %{
      kind: :global_shortcut,
      type: payload.shortcut,
      workspace_id: payload.workspace_id,
      actor_id: payload.user_id,
      channel_id: payload.channel_id,
      thread_root_id: payload.thread_root_id,
      trigger_id: payload.trigger_id,
      data: %{shortcut: payload.shortcut}
    })
  end

  defp shape(%Payload.MessageShortcut{} = payload, scope) do
    interaction(scope, %{
      kind: :message_shortcut,
      type: payload.shortcut,
      workspace_id: payload.workspace_id,
      actor_id: payload.user_id,
      channel_id: payload.channel_id,
      resource_id: payload.message_id,
      trigger_id: payload.trigger_id,
      data: %{shortcut: payload.shortcut, message_id: payload.message_id}
    })
  end

  defp shape(%Payload.BlockInteraction{} = payload, scope) do
    interaction(scope, %{
      kind: :block_interaction,
      type: payload.action_type || payload.source_type,
      workspace_id: payload.workspace_id,
      actor_id: payload.user_id,
      channel_id: payload.channel_id,
      resource_id: payload.source_id,
      trigger_id: payload.trigger_id,
      data: %{
        source_type: payload.source_type,
        source_id: payload.source_id,
        action_type: payload.action_type,
        on_action: payload.on_action,
        block_value: payload.payload,
        loading_timeout: payload.loading_timeout,
        view_id: view_id(payload.view)
      }
    })
  end

  defp shape(%Payload.ViewAction{} = payload, scope) do
    interaction(scope, %{
      kind: :view_action,
      type: payload.view_action_type,
      workspace_id: payload.workspace_id,
      actor_id: payload.user_id,
      channel_id: payload.channel_id,
      resource_id: view_id(payload.view),
      trigger_id: payload.trigger_id,
      data: %{view_action_type: payload.view_action_type, view_id: view_id(payload.view)}
    })
  end

  defp shape(%Payload.DynamicMenu{} = payload, scope) do
    interaction(scope, %{
      kind: :dynamic_menu,
      type: payload.on_action,
      workspace_id: payload.workspace_id,
      actor_id: payload.user_id,
      trigger_id: payload.trigger_id,
      data: %{on_action: payload.on_action, query: payload.query, value: payload.value}
    })
  end

  defp interaction(scope, attrs) do
    struct!(
      InteractionCommand,
      attrs
      |> Map.merge(%{
        installation_id: scope.installation_id,
        delivery_key: scope.delivery_key,
        correlation_id: scope.correlation_id,
        occurred_at: scope.received_at,
        occurred_at_source: :received
      })
      |> Map.update!(:data, fn data ->
        data |> Map.put(:workspace_id, attrs.workspace_id) |> bound()
      end)
    )
  end

  defp automation_event(%Payload.Event{} = event, scope) do
    body = event.body
    {occurred_at, source} = occurred_at(event, scope)

    %AutomationEvent{
      installation_id: scope.installation_id,
      type: event.event_type,
      actor_id: actor_id(event.event_type, body),
      channel_id: string(body["cId"]),
      resource_id: resource_id(event.event_type, body),
      thread_root_id: string(body["trId"]),
      occurred_at: occurred_at,
      occurred_at_source: source,
      delivery_key: scope.delivery_key,
      correlation_id: scope.correlation_id,
      bot_origin?: bot_origin(event, scope),
      data: event_data(event, scope)
    }
  end

  defp lifecycle(%Payload.Event{} = event, scope) do
    body = event.body
    {occurred_at, source} = occurred_at(event, scope)

    %LifecycleCommand{
      installation_id: scope.installation_id,
      kind: lifecycle_kind(event.event_type),
      type: event.event_type,
      workspace_id: event.workspace_id,
      provider_event_id: string(body["id"]),
      occurred_at: occurred_at,
      occurred_at_source: source,
      delivery_key: scope.delivery_key,
      correlation_id: scope.correlation_id,
      data: event_data(event, scope)
    }
  end

  defp lifecycle_kind("APP_UNINSTALLED"), do: :app_uninstalled
  defp lifecycle_kind("APP_UNAUTHORIZED"), do: :app_unauthorized

  defp actor_id(type, body) when type in ["NEW_MESSAGE", "UPDATED_MESSAGE"],
    do: string(body["aId"])

  defp actor_id(_type, body), do: string(body["uId"])

  defp resource_id(type, body)
       when type in ["NEW_MESSAGE", "UPDATED_MESSAGE", "REACTION_ADDED"] do
    string(body["mId"])
  end

  defp resource_id("CHANNEL_CREATED", body), do: string(body["cId"])
  defp resource_id("WORKSPACE_USER_JOINED", body), do: string(body["uId"])
  defp resource_id(_type, body), do: string(body["id"])

  defp bot_origin(%Payload.Event{event_type: type, body: body}, %{bot_user_id: bot_user_id})
       when type in ["NEW_MESSAGE", "UPDATED_MESSAGE"] and is_binary(bot_user_id) do
    # Proven rule only: author id equals the stored bot user id. `st`, `bot`,
    # and caller-supplied lineage fields are not evidence of authorship.
    case string(body["aId"]) do
      nil -> nil
      author -> author == bot_user_id
    end
  end

  defp bot_origin(_event, _scope), do: nil

  defp event_data(%Payload.Event{event_type: type, body: body} = event, _scope) do
    type
    |> data_fields(body)
    |> Map.merge(%{
      workspace_id: event.workspace_id,
      provider_request_id: string(body["rid"]),
      provider_event_id: string(body["id"]),
      workspace_user_ids: event.workspace_user_ids
    })
    |> bound()
  end

  defp data_fields(type, body) when type in ["NEW_MESSAGE", "UPDATED_MESSAGE"] do
    %{
      text: body["tx"],
      subtype: body["st"],
      message_id: body["mId"],
      thread_root_id: body["trId"],
      also_sent_to_channel: body["stc"],
      edited?: body["e"],
      ephemeral?: body["eph"],
      mentions_direct: body["md"],
      mentions_channel: body["mc"],
      mentions_user: body["mu"],
      file_count: count(body["f"]),
      provider_timestamp_ms: body["tsm"]
    }
  end

  defp data_fields("REACTION_ADDED", body) do
    %{
      reaction_code: body["rc"],
      message_id: body["mId"],
      message_author_id: body["mat"],
      reacted_by_id: body["uId"]
    }
  end

  defp data_fields("CHANNEL_CREATED", body) do
    %{
      channel_id: body["cId"],
      channel_name: body["cN"],
      channel_type: body["cT"],
      channel_member_count: count(body["cU"])
    }
  end

  defp data_fields("WORKSPACE_USER_JOINED", body) do
    %{
      user_id: body["uId"],
      user_name: body["uN"],
      user_email: body["uE"],
      user_role: body["ro"],
      user_status: body["st"],
      timezone: body["tz"],
      invited_by_id: body["ib"]
    }
  end

  defp data_fields("APP_UNINSTALLED", body) do
    %{
      app_id: body["app"],
      workspace: body["workspace"],
      installed_by_id: body["installedBy"],
      bot_user_id: body["botUser"]
    }
  end

  defp data_fields("APP_UNAUTHORIZED", body) do
    %{
      app_id: body["app"],
      app_installation_id: body["appInstallation"],
      workspace: body["workspace"],
      workspace_user_id: body["workspaceUser"],
      granted_scopes: body["grantedScopes"],
      access_granted?: body["accessGranted"]
    }
  end

  defp data_fields(_type, _body), do: %{}

  defp occurred_at(%Payload.Event{body: body, event_type: type}, scope) do
    case body |> Map.get(time_field(type)) |> parse_time() do
      {:ok, occurred_at} -> {occurred_at, :provider}
      :error -> {scope.received_at, :received}
    end
  end

  defp time_field(type) when type in ["NEW_MESSAGE", "UPDATED_MESSAGE"], do: "tsm"
  defp time_field("APP_UNINSTALLED"), do: "uninstalledAt"
  defp time_field(_type), do: "__no_provider_time__"

  defp parse_time(value) when is_integer(value), do: from_unix_ms(value)

  defp parse_time(value) when is_binary(value) do
    case Integer.parse(value) do
      {milliseconds, ""} -> from_unix_ms(milliseconds)
      _not_an_integer -> from_iso8601(value)
    end
  end

  defp parse_time(_value), do: :error

  defp from_unix_ms(milliseconds) when milliseconds in @min_unix_ms..@max_unix_ms do
    DateTime.from_unix(milliseconds, :millisecond)
  end

  defp from_unix_ms(_milliseconds), do: :error

  defp from_iso8601(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> plausible(datetime)
      {:error, _reason} -> :error
    end
  end

  defp plausible(datetime) do
    if DateTime.to_unix(datetime, :millisecond) in @min_unix_ms..@max_unix_ms do
      {:ok, datetime}
    else
      :error
    end
  end

  defp view_id(view) when is_map(view), do: string(view["id"])
  defp view_id(_view), do: nil

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil

  defp count(value) when is_list(value), do: length(value)
  defp count(_value), do: nil

  # Drops what carries no information, then caps what is left. Sorting before
  # the cap keeps the same payload producing the same map.
  defp bound(data) do
    data
    |> Enum.reject(fn {key, value} -> is_nil(value) or untrusted_data_key?(key) end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.take(@max_data_keys)
    |> Map.new(fn {key, value} -> {key, bound_value(value)} end)
  end

  defp untrusted_data_key?(key), do: MapSet.member?(@untrusted_data_keys, key)

  defp bound_value(value) when is_binary(value), do: binary_part_safe(value)

  defp bound_value(value) when is_list(value) do
    value
    |> Enum.take(@max_list_length)
    |> Enum.map(&scalar/1)
    |> Enum.reject(&is_nil/1)
  end

  defp bound_value(value) when is_map(value), do: map_size(value)
  defp bound_value(value), do: value

  defp scalar(value) when is_binary(value), do: binary_part_safe(value)
  defp scalar(value) when is_number(value) or is_boolean(value), do: value
  defp scalar(_value), do: nil

  defp binary_part_safe(value) do
    value
    |> binary_part(0, min(byte_size(value), @max_binary_bytes))
    |> valid_prefix()
  end

  defp valid_prefix(value) do
    case :unicode.characters_to_binary(value, :utf8, :utf8) do
      valid when is_binary(valid) -> valid
      {:incomplete, valid, _rest} -> valid
      {:error, valid, _rest} -> valid
    end
  end
end
