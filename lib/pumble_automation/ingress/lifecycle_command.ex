defmodule PumbleAutomation.Ingress.LifecycleCommand do
  @moduledoc """
  A control-plane callback: the app was uninstalled or its authorization changed.

  `APP_UNINSTALLED` and `APP_UNAUTHORIZED` arrive through the same event
  envelope as a workflow trigger, and that is the only thing they have in common
  with one. They are instructions to this application about its own
  installation, they are forbidden as user-selectable triggers (product contract
  Section 1.1), and their payloads use full field names rather than the
  abbreviated ones (`L-1`, `L-2`).

  They therefore normalize to their own struct. A lifecycle callback that
  arrived as a `PumbleAutomation.Ingress.AutomationEvent` could be matched by a
  workflow, which is exactly the outcome the contract forbids, and no filter
  later in the pipeline would be as reliable as not building the value.

  `:provider_event_id` is the payload's `id`. Its uniqueness and its behaviour
  across redelivery are unproven (`I-8`, `PR-01`), so it is carried for
  diagnostics and correlation and is not the deduplication key;
  `:delivery_key` is.
  """

  alias PumbleAutomation.Ingress.AutomationEvent

  @typedoc "Which lifecycle callback this is."
  @type kind :: :app_uninstalled | :app_unauthorized

  @type t :: %__MODULE__{
          provider: :pumble,
          installation_id: Ecto.UUID.t(),
          kind: kind(),
          type: String.t(),
          workspace_id: String.t(),
          provider_event_id: String.t() | nil,
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
    :occurred_at,
    :occurred_at_source,
    :delivery_key
  ]
  defstruct [
    :installation_id,
    :kind,
    :type,
    :workspace_id,
    :provider_event_id,
    :occurred_at,
    :occurred_at_source,
    :delivery_key,
    :correlation_id,
    provider: :pumble,
    data: %{}
  ]
end
