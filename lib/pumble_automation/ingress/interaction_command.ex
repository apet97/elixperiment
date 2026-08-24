defmodule PumbleAutomation.Ingress.InteractionCommand do
  @moduledoc """
  A person asked this application to do something, and is waiting for an answer.

  Slash commands, shortcuts, block interactions, view actions, and dynamic-menu
  requests all normalize here. They are not events and are deliberately not
  represented as events: an event is something that happened and may match a
  workflow, while an interaction is a synchronous request with a three-second
  deadline, a `triggerId` that addresses the reply, and a person watching a
  spinner.

  `:trigger_id` is the addressing token for a modal or an options reply. It is
  not a delivery identifier — the SDK never uses it as one (`I-3` to `I-7`
  annotation) — so `:delivery_key` is derived separately.

  `:occurred_at` is always the receive time with `:occurred_at_source` set to
  `:received`: no interactive payload carries a provider timestamp.
  """

  alias PumbleAutomation.Ingress.AutomationEvent

  @typedoc "Which interactive class this command came from."
  @type kind ::
          :slash_command
          | :global_shortcut
          | :message_shortcut
          | :block_interaction
          | :view_action
          | :dynamic_menu

  @type t :: %__MODULE__{
          provider: :pumble,
          installation_id: Ecto.UUID.t(),
          kind: kind(),
          type: String.t(),
          workspace_id: String.t(),
          actor_id: String.t(),
          channel_id: String.t() | nil,
          resource_id: String.t() | nil,
          thread_root_id: String.t() | nil,
          trigger_id: String.t(),
          occurred_at: DateTime.t(),
          occurred_at_source: AutomationEvent.time_source(),
          delivery_key: String.t(),
          correlation_id: String.t() | nil,
          data: map()
        }

  @enforce_keys [
    :installation_id,
    :kind,
    :type,
    :workspace_id,
    :actor_id,
    :trigger_id,
    :occurred_at,
    :delivery_key
  ]
  defstruct [
    :installation_id,
    :kind,
    :type,
    :workspace_id,
    :actor_id,
    :channel_id,
    :resource_id,
    :thread_root_id,
    :trigger_id,
    :occurred_at,
    :delivery_key,
    :correlation_id,
    provider: :pumble,
    occurred_at_source: :received,
    data: %{}
  ]
end
