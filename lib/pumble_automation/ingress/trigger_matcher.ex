defmodule PumbleAutomation.Ingress.TriggerMatcher do
  @moduledoc """
  Finds live workflow versions for one normalized trigger.

  The lookup is an index read, not a workflow scan. Tenant, class, type, and
  the selective discriminators (channel, manual alias) are applied in
  `PumbleAutomation.Workflows.TriggerBinding.candidates/2`. Keyword, bot-origin,
  and manual entry-point flags are small typed filters and run in Elixir on
  that candidate set. Draft JSON is never loaded.

  The return value is version id plus binding id, in a stable order, so a
  later ingestion transaction can create one execution per match without
  deciding which binding won.

  ## Malformed projections

  A binding whose `filter_config` is not the typed summary activation writes
  is skipped, not a crash of the whole match. Telemetry
  `[:pumble_automation, :ingress, :matcher, :invalid_filter]` marks that
  row invalid so the healthy candidates still return.
  """

  alias PumbleAutomation.Executions.Lineage
  alias PumbleAutomation.Ingress.AutomationEvent
  alias PumbleAutomation.Ingress.InteractionCommand
  alias PumbleAutomation.Ingress.LifecycleCommand
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Workflows.TriggerBinding

  @telemetry_event [:pumble_automation, :ingress, :matcher]

  @type t :: %__MODULE__{
          binding_id: Ecto.UUID.t(),
          workflow_version_id: Ecto.UUID.t()
        }

  @enforce_keys [:binding_id, :workflow_version_id]
  defstruct [:binding_id, :workflow_version_id]

  @doc """
  Returns the live matches for a normalized trigger.

  Lifecycle callbacks are not workflow triggers and always return `[]`.
  """
  @spec match(AutomationEvent.t() | InteractionCommand.t() | LifecycleCommand.t()) :: [t()]
  def match(%AutomationEvent{} = event) do
    event.installation_id
    |> TriggerBinding.candidates(
      kind: "pumble_event",
      type: event.type,
      channel_id: event.channel_id
    )
    |> Repo.all()
    |> accept(event)
    |> tap(&emit_match(&1, event))
  end

  def match(%InteractionCommand{} = command) do
    case trigger_alias(command) do
      alias_name when is_binary(alias_name) and alias_name != "" ->
        command.installation_id
        |> TriggerBinding.candidates(kind: "manual", alias: alias_name)
        |> Repo.all()
        |> accept(command)
        |> tap(&emit_match(&1, command))

      _missing ->
        emit_match([], command)
        []
    end
  end

  def match(%LifecycleCommand{}), do: []

  @doc "Telemetry prefix for invalid filter projections."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  defp accept(bindings, trigger) do
    Enum.flat_map(bindings, fn binding ->
      case decide(binding, trigger) do
        :keep ->
          [
            %__MODULE__{
              binding_id: binding.id,
              workflow_version_id: binding.workflow_version_id
            }
          ]

        :drop ->
          []

        :invalid ->
          emit_invalid(binding)
          []
      end
    end)
  end

  defp decide(%TriggerBinding{kind: "pumble_event"} = binding, %AutomationEvent{} = event) do
    case event_filter(binding.filter_config) do
      {:ok, filter} -> if event_matches?(filter, event), do: :keep, else: :drop
      :error -> :invalid
    end
  end

  defp decide(%TriggerBinding{kind: "manual"} = binding, %InteractionCommand{} = command) do
    case manual_filter(binding.filter_config) do
      {:ok, filter} -> if entry_open?(filter, command.kind), do: :keep, else: :drop
      :error -> :invalid
    end
  end

  defp decide(_binding, _trigger), do: :drop

  defp event_filter(config) when is_map(config) do
    config = stringify_keys(config)
    keyword = Map.get(config, "keyword")
    ignore = Map.get(config, "ignore_bot_messages", true)

    cond do
      not keyword_value?(keyword) -> :error
      not is_boolean(ignore) -> :error
      true -> {:ok, %{keyword: present_keyword(keyword), ignore_bot_messages: ignore}}
    end
  end

  defp event_filter(_config), do: :error

  defp event_matches?(filter, event) do
    keyword_matches?(filter.keyword, event) and bot_allowed?(filter.ignore_bot_messages, event)
  end

  defp keyword_matches?(nil, _event), do: true

  defp keyword_matches?(keyword, event) do
    case event_text(event) do
      text when is_binary(text) ->
        String.contains?(String.downcase(text), String.downcase(keyword))

      _missing ->
        false
    end
  end

  defp bot_allowed?(false, _event), do: true

  defp bot_allowed?(true, %AutomationEvent{bot_origin?: true} = event) do
    Lineage.record(:bot_filtered, event.installation_id)
    false
  end

  defp bot_allowed?(true, _event), do: true

  defp event_text(%AutomationEvent{data: data}) when is_map(data) do
    Map.get(data, :text) || Map.get(data, "text")
  end

  defp manual_filter(config) when is_map(config) do
    config = stringify_keys(config)
    slash = Map.get(config, "slash_command", false)
    global = Map.get(config, "global_shortcut", false)
    message = Map.get(config, "message_shortcut", false)

    if is_boolean(slash) and is_boolean(global) and is_boolean(message) do
      {:ok, %{slash_command: slash, global_shortcut: global, message_shortcut: message}}
    else
      :error
    end
  end

  defp manual_filter(_config), do: :error

  defp entry_open?(filter, :slash_command), do: filter.slash_command
  defp entry_open?(filter, :global_shortcut), do: filter.global_shortcut
  defp entry_open?(filter, :message_shortcut), do: filter.message_shortcut
  defp entry_open?(_filter, _kind), do: false

  defp trigger_alias(%InteractionCommand{data: data}) when is_map(data) do
    case Map.get(data, :alias) || Map.get(data, "alias") do
      alias_name when is_binary(alias_name) -> alias_name
      _missing -> nil
    end
  end

  defp keyword_value?(keyword) when is_binary(keyword) or is_nil(keyword), do: true
  defp keyword_value?(_keyword), do: false

  defp present_keyword(nil), do: nil
  defp present_keyword(""), do: nil
  defp present_keyword(keyword), do: keyword

  defp stringify_keys(config) do
    Map.new(config, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp emit_invalid(binding) do
    :telemetry.execute(
      @telemetry_event ++ [:invalid_filter],
      %{count: 1},
      %{kind: binding.kind, type: binding.type}
    )

    :ok
  end

  defp emit_match(matches, trigger) do
    PumbleAutomation.Telemetry.execute(
      @telemetry_event ++ [:match],
      %{count: length(matches)},
      match_metadata(trigger)
    )
  end

  defp match_metadata(%AutomationEvent{} = event) do
    %{
      kind: "pumble_event",
      type: event.type,
      installation_id: event.installation_id
    }
  end

  defp match_metadata(%InteractionCommand{} = command) do
    %{
      kind: "manual",
      type: command.type,
      installation_id: command.installation_id
    }
  end
end
