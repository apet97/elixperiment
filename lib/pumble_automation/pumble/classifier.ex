defmodule PumbleAutomation.Pumble.Classifier do
  @moduledoc """
  Turns a decoded callback envelope into exactly one typed payload.

  `classify/1` is the only door between "a map Pumble sent" and the rest of this
  application. It answers `{:ok, struct}` or `{:error, t:PumbleAutomation.Error.t/0}`
  and never anything in between, so no caller has to decide what a half-known
  body means.

  ## Exactly one class, or none

  The SDK dispatches through seven sequential guards, and the last five have no
  early `return`: a body matching two guards would be dispatched twice
  (evidence `X-5`). Every guard is an equality test on a single-valued field, so
  no well-formed body can do that — but "well-formed" is a server property this
  application cannot verify.

  This classifier is therefore exclusive by construction. It switches once on
  `messageType`, and before doing so it refuses any body that also carries the
  *recognized* secondary discriminator of a different class — a `SLASH_COMMAND`
  that also names a `sourceType` of `VIEW`, for instance. Such a body is the
  dual-match hazard `X-5` describes, and it is rejected as malformed rather than
  resolved by guard order.

  ## The nested body is parsed defensively

  An event envelope carries its body as a JSON **string** that must be parsed a
  second time (`2.3`). That string arrives from the network, so it is decoded
  with `Jason.decode/1` and a failure is an error return. A malformed nested
  body never raises, because the caller is a controller with a three-second
  deadline and an exception there is a 500 where a 400 was the answer.

  ## What the errors say

  Every failure is `:validation` class and not retryable: a body that is wrong
  now is wrong on redelivery. `:details` names the offending *field*, never its
  value, because details are written to logs and a callback field holds message
  text and channel ids.

  Two codes are load-bearing for the dispatcher and must stay distinguishable:

    * `:unknown_message_type` — the envelope names a class this application does
      not implement. The caller answers with a stable refusal.
    * `:unknown_event_type` — the envelope is a well-formed event naming an
      event outside the SDK's seven. Events have no `nack` (`K-6`) and what a
      non-2xx does to redelivery is unproven (`K-10`, `PR-02`), so the caller
      answers `200 ok` and drops it rather than inventing a failure reply.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Pumble.Payload

  # A class other than the owner naming one of these values is a dual-match
  # body: exactly the hazard `X-5` describes. Keys are wire names.
  @secondary_discriminators %{
    "type" => {["SHORTCUT"], Payload.shortcut_types()},
    "sourceType" => {["BLOCK_INTERACTION"], Payload.block_interaction_source_types()},
    "viewActionType" => {["VIEW_ACTION"], Payload.view_action_types()}
  }

  @doc """
  Classifies a decoded callback envelope.

  The argument is the parsed JSON object, with Pumble's string keys.
  """
  @spec classify(term()) :: {:ok, Payload.t()} | {:error, Error.t()}
  def classify(envelope) when is_map(envelope) and not is_struct(envelope) do
    with {:ok, message_type} <- fetch_string(envelope, "messageType"),
         :ok <- ensure_unambiguous(envelope, message_type) do
      build(message_type, envelope)
    end
  end

  def classify(_other), do: {:error, error(:callback_not_an_object)}

  defp build(message_type, envelope) when message_type in ["PUMBLE_EVENT", "APP_EVENT"] do
    with {:ok, event_type} <- fetch_event_type(envelope),
         {:ok, workspace_id} <- fetch_string(envelope, "workspaceId"),
         {:ok, encoded_body} <- fetch_string(envelope, "body"),
         {:ok, body} <- decode_body(encoded_body),
         {:ok, user_ids} <- fetch_string_list(envelope, "workspaceUserIds") do
      {:ok,
       %Payload.Event{
         message_type: message_type,
         event_type: event_type,
         workspace_id: workspace_id,
         workspace_user_ids: user_ids,
         body: body,
         unknown: unknown(envelope, ~w(messageType eventType workspaceId body workspaceUserIds))
       }}
    end
  end

  defp build("SLASH_COMMAND", envelope) do
    with {:ok, slash_command} <- fetch_string(envelope, "slashCommand"),
         {:ok, user_id} <- fetch_string(envelope, "userId"),
         {:ok, channel_id} <- fetch_string(envelope, "channelId"),
         {:ok, workspace_id} <- fetch_string(envelope, "workspaceId"),
         {:ok, trigger_id} <- fetch_string(envelope, "triggerId"),
         {:ok, thread_root_id} <- fetch_optional_string(envelope, "threadRootId"),
         {:ok, text} <- fetch_optional_string(envelope, "text") do
      {:ok,
       %Payload.SlashCommand{
         slash_command: slash_command,
         text: text || "",
         user_id: user_id,
         channel_id: channel_id,
         thread_root_id: thread_root_id,
         workspace_id: workspace_id,
         trigger_id: trigger_id,
         unknown:
           unknown(
             envelope,
             ~w(messageType slashCommand text blocks userId channelId threadRootId workspaceId triggerId)
           )
       }}
    end
  end

  defp build("SHORTCUT", envelope) do
    case fetch_enum(envelope, "type", Payload.shortcut_types()) do
      {:ok, "GLOBAL"} -> global_shortcut(envelope)
      {:ok, "ON_MESSAGE"} -> message_shortcut(envelope)
      {:error, error} -> {:error, error}
    end
  end

  defp build("BLOCK_INTERACTION", envelope) do
    with {:ok, source_type} <-
           fetch_enum(envelope, "sourceType", Payload.block_interaction_source_types()),
         {:ok, workspace_id} <- fetch_string(envelope, "workspaceId"),
         {:ok, user_id} <- fetch_string(envelope, "userId"),
         {:ok, source_id} <- fetch_string(envelope, "sourceId"),
         {:ok, trigger_id} <- fetch_string(envelope, "triggerId"),
         {:ok, channel_id} <- fetch_optional_string(envelope, "channelId"),
         {:ok, action_type} <- fetch_optional_string(envelope, "actionType"),
         {:ok, on_action} <- fetch_optional_string(envelope, "onAction"),
         {:ok, block_payload} <- fetch_optional_string(envelope, "payload"),
         {:ok, view} <- fetch_optional_map(envelope, "view"),
         {:ok, loading_timeout} <- fetch_optional_integer(envelope, "loadingTimeout") do
      {:ok,
       %Payload.BlockInteraction{
         workspace_id: workspace_id,
         user_id: user_id,
         channel_id: channel_id,
         source_type: source_type,
         source_id: source_id,
         action_type: action_type,
         on_action: on_action,
         payload: block_payload,
         view: view,
         trigger_id: trigger_id,
         loading_timeout: loading_timeout,
         unknown:
           unknown(
             envelope,
             ~w(messageType workspaceId userId channelId sourceType sourceId actionType onAction payload view triggerId loadingTimeout)
           )
       }}
    end
  end

  defp build("VIEW_ACTION", envelope) do
    with {:ok, view_action_type} <-
           fetch_enum(envelope, "viewActionType", Payload.view_action_types()),
         {:ok, workspace_id} <- fetch_string(envelope, "workspaceId"),
         {:ok, user_id} <- fetch_string(envelope, "userId"),
         {:ok, trigger_id} <- fetch_string(envelope, "triggerId"),
         {:ok, channel_id} <- fetch_optional_string(envelope, "channelId"),
         {:ok, view} <- fetch_optional_map(envelope, "view") do
      {:ok,
       %Payload.ViewAction{
         workspace_id: workspace_id,
         user_id: user_id,
         channel_id: channel_id,
         view_action_type: view_action_type,
         view: view,
         trigger_id: trigger_id,
         unknown:
           unknown(
             envelope,
             ~w(messageType workspaceId userId channelId viewActionType view triggerId)
           )
       }}
    end
  end

  defp build("DYNAMIC_MENU", envelope) do
    with {:ok, on_action} <- fetch_string(envelope, "onAction"),
         {:ok, workspace_id} <- fetch_string(envelope, "workspaceId"),
         {:ok, user_id} <- fetch_string(envelope, "userId"),
         {:ok, trigger_id} <- fetch_string(envelope, "triggerId"),
         {:ok, query} <- fetch_optional_string(envelope, "query"),
         {:ok, value} <- fetch_optional_string(envelope, "value") do
      {:ok,
       %Payload.DynamicMenu{
         on_action: on_action,
         query: query,
         value: value,
         workspace_id: workspace_id,
         user_id: user_id,
         trigger_id: trigger_id,
         unknown:
           unknown(envelope, ~w(messageType onAction query value workspaceId userId triggerId))
       }}
    end
  end

  defp build(_unknown, _envelope) do
    {:error, error(:unknown_message_type, "messageType")}
  end

  defp global_shortcut(envelope) do
    with {:ok, shortcut} <- fetch_string(envelope, "shortcut"),
         {:ok, user_id} <- fetch_string(envelope, "userId"),
         {:ok, channel_id} <- fetch_string(envelope, "channelId"),
         {:ok, workspace_id} <- fetch_string(envelope, "workspaceId"),
         {:ok, trigger_id} <- fetch_string(envelope, "triggerId"),
         {:ok, thread_root_id} <- fetch_optional_string(envelope, "threadRootId") do
      {:ok,
       %Payload.GlobalShortcut{
         shortcut: shortcut,
         user_id: user_id,
         channel_id: channel_id,
         thread_root_id: thread_root_id,
         workspace_id: workspace_id,
         trigger_id: trigger_id,
         unknown:
           unknown(
             envelope,
             ~w(messageType type shortcut userId channelId threadRootId workspaceId triggerId)
           )
       }}
    end
  end

  defp message_shortcut(envelope) do
    with {:ok, shortcut} <- fetch_string(envelope, "shortcut"),
         {:ok, message_id} <- fetch_string(envelope, "messageId"),
         {:ok, user_id} <- fetch_string(envelope, "userId"),
         {:ok, channel_id} <- fetch_string(envelope, "channelId"),
         {:ok, workspace_id} <- fetch_string(envelope, "workspaceId"),
         {:ok, trigger_id} <- fetch_string(envelope, "triggerId") do
      {:ok,
       %Payload.MessageShortcut{
         shortcut: shortcut,
         message_id: message_id,
         user_id: user_id,
         channel_id: channel_id,
         workspace_id: workspace_id,
         trigger_id: trigger_id,
         unknown:
           unknown(
             envelope,
             ~w(messageType type shortcut messageId userId channelId workspaceId triggerId)
           )
       }}
    end
  end

  # A body is ambiguous when it names the secondary discriminator of a class it
  # does not belong to, with a value that class recognizes.
  defp ensure_unambiguous(envelope, message_type) do
    Enum.reduce_while(@secondary_discriminators, :ok, fn {field, {owners, values}}, :ok ->
      if message_type not in owners and Map.get(envelope, field) in values do
        {:halt, {:error, error(:ambiguous_callback, field)}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp fetch_event_type(envelope) do
    case Map.get(envelope, "eventType") do
      value when is_binary(value) ->
        if value in Payload.event_types() do
          {:ok, value}
        else
          {:error, error(:unknown_event_type, "eventType")}
        end

      _missing_or_wrong_type ->
        {:error, error(:invalid_field, "eventType")}
    end
  end

  defp decode_body(encoded) do
    case Jason.decode(encoded) do
      {:ok, body} when is_map(body) -> {:ok, body}
      {:ok, _not_an_object} -> {:error, error(:invalid_field, "body")}
      {:error, _reason} -> {:error, error(:malformed_event_body, "body")}
    end
  end

  defp fetch_string(envelope, field) do
    case Map.get(envelope, field) do
      value when is_binary(value) -> {:ok, value}
      _missing_or_wrong_type -> {:error, error(:invalid_field, field)}
    end
  end

  defp fetch_optional_string(envelope, field) do
    case Map.get(envelope, field) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _wrong_type -> {:error, error(:invalid_field, field)}
    end
  end

  defp fetch_optional_map(envelope, field) do
    case Map.get(envelope, field) do
      nil -> {:ok, nil}
      value when is_map(value) -> {:ok, value}
      _wrong_type -> {:error, error(:invalid_field, field)}
    end
  end

  defp fetch_optional_integer(envelope, field) do
    case Map.get(envelope, field) do
      nil -> {:ok, nil}
      value when is_integer(value) -> {:ok, value}
      _wrong_type -> {:error, error(:invalid_field, field)}
    end
  end

  defp fetch_string_list(envelope, field) do
    case Map.get(envelope, field) do
      nil -> {:ok, []}
      value when is_list(value) -> string_list(value, field)
      _wrong_type -> {:error, error(:invalid_field, field)}
    end
  end

  defp string_list(values, field) do
    if Enum.all?(values, &is_binary/1) do
      {:ok, values}
    else
      {:error, error(:invalid_field, field)}
    end
  end

  defp fetch_enum(envelope, field, allowed) do
    case Map.get(envelope, field) do
      value when is_binary(value) ->
        if value in allowed, do: {:ok, value}, else: {:error, error(:invalid_field, field)}

      _missing_or_wrong_type ->
        {:error, error(:invalid_field, field)}
    end
  end

  defp unknown(envelope, known_keys), do: Payload.unknown_fields(envelope, known_keys)

  defp error(code, field \\ nil) do
    Error.new(:validation, code,
      message: "The callback could not be classified.",
      retryable?: false,
      details: if(field, do: %{field: field}, else: %{})
    )
  end
end
