defmodule PumbleAutomation.Ingress.AutomationEvent do
  @moduledoc """
  One normalized provider event, as plan Section 12.3 specifies it.

  This is the only event shape workflow matching is allowed to see. It is a
  value: building one writes nothing and reads nothing, so it can be produced in
  a controller, a job, or a test with no difference in meaning.

  ## Fields

    * `:provider` — always `:pumble` today. The field exists because the shape
      is meant to outlive one provider, and a second provider must not be added
      by widening `:type` strings.
    * `:installation_id` — the tenant. Never `nil`: an event with no tenant is
      an unscoped event, and plan Section 12.3 forbids creating one.
    * `:kind` — `:event` here. Interactions use
      `PumbleAutomation.Ingress.InteractionCommand` and lifecycle callbacks use
      `PumbleAutomation.Ingress.LifecycleCommand`, so a workflow trigger can
      never be confused with a modal submission.
    * `:type` — the provider event name, one of the five selectable triggers.
    * `:actor_id`, `:channel_id`, `:resource_id`, `:thread_root_id` — the
      identities a condition or an action needs, already translated out of the
      abbreviated wire names.
    * `:occurred_at` — provider time when the payload carried a usable one,
      otherwise the receive time. `:occurred_at_source` says which, so a
      condition on time is never silently evaluated against the wrong clock.
    * `:delivery_key` — the deduplication key. See
      `PumbleAutomation.Pumble.Normalizer` for how it is derived and why.
    * `:correlation_id` — stitches this event to the request that carried it and
      to everything the event later causes.
    * `:bot_origin?` — `true` or `false` only when it was decided from a proven
      field (`N-4`: the message author equals the stored bot user id). `nil`
      means the question was not answerable here, never "no".
    * `:data` — the bounded remainder. Snake_case keys only, no credentials, and
      no provider abbreviations.
  """

  @typedoc "Which clock `:occurred_at` came from."
  @type time_source :: :provider | :received

  @type t :: %__MODULE__{
          provider: :pumble,
          installation_id: Ecto.UUID.t(),
          kind: :event,
          type: String.t(),
          actor_id: String.t() | nil,
          channel_id: String.t() | nil,
          resource_id: String.t() | nil,
          thread_root_id: String.t() | nil,
          occurred_at: DateTime.t(),
          occurred_at_source: time_source(),
          delivery_key: String.t(),
          correlation_id: String.t() | nil,
          bot_origin?: boolean() | nil,
          data: map()
        }

  @enforce_keys [
    :installation_id,
    :type,
    :occurred_at,
    :occurred_at_source,
    :delivery_key
  ]
  defstruct [
    :installation_id,
    :type,
    :actor_id,
    :channel_id,
    :resource_id,
    :thread_root_id,
    :occurred_at,
    :occurred_at_source,
    :delivery_key,
    :correlation_id,
    :bot_origin?,
    provider: :pumble,
    kind: :event,
    data: %{}
  ]
end
