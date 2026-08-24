defmodule PumbleAutomation.Pumble.Payload do
  @moduledoc """
  The finite union of Pumble callback shapes, as typed structs.

  One POST to `/pumble/callbacks` carries exactly one callback, and the wire
  shape of that callback depends on its class. This module names the classes and
  the fields each one carries, so that everything downstream matches on a struct
  instead of digging through a map with `Map.get/2`.

  The classes are the nine of evidence rows `C-1` to `C-9`, collapsed to the
  seven structs a body can actually be: `SHORTCUT` splits into
  `PumbleAutomation.Pumble.Payload.GlobalShortcut` and
  `PumbleAutomation.Pumble.Payload.MessageShortcut` by its `type`, and the three
  block-interaction sources stay one struct carrying `source_type`, because they
  differ in what may be *answered*, not in what arrives.

  ## Field names

  Every struct field is the internal snake_case name. The wire names — including
  the abbreviated `aId`, `cId`, `tx`, `mId` family of the event bodies (`E-1` to
  `E-5`) — appear only in
  `PumbleAutomation.Pumble.Classifier` and
  `PumbleAutomation.Pumble.Normalizer`. Nothing past those two modules is
  allowed to know them.

  The one deliberate exception is `PumbleAutomation.Pumble.Payload.Event`'s
  `:body`, which holds the decoded event body with its wire keys intact. That
  map is the classifier's output and the normalizer's input, and it goes no
  further: the normalizer translates it and the translated result is what
  domain code sees.

  ## `:unknown` holds names, never values

  Pumble may add a field at any time, and a diagnostic that cannot say *what*
  arrived is hard to act on. Each struct therefore carries `:unknown`, a map of
  the envelope keys this application did not recognize.

  The values in that map are type tags — `:string`, `:integer`, `:list`, and so
  on — and never the field's content. A callback body is message text, channel
  ids, and actor ids (which is why the route is mounted with `log: false`), and
  a diagnostic map is exactly the kind of value that ends up in a log line or an
  error report. The name and the type answer "did the shape change?", which is
  what the map is for; the content would answer a question nobody asked.

  The map is capped at sixteen keys, so a body with a thousand unknown fields
  costs a bounded amount of memory and produces a bounded log line.
  """

  alias PumbleAutomation.Pumble.Payload

  @max_unknown_keys 16

  @message_types ~w(SLASH_COMMAND SHORTCUT APP_EVENT PUMBLE_EVENT BLOCK_INTERACTION DYNAMIC_MENU VIEW_ACTION)

  @trigger_event_types ~w(NEW_MESSAGE UPDATED_MESSAGE REACTION_ADDED CHANNEL_CREATED WORKSPACE_USER_JOINED)

  @lifecycle_event_types ~w(APP_UNINSTALLED APP_UNAUTHORIZED)

  @block_interaction_source_types ~w(VIEW MESSAGE EPHEMERAL_MESSAGE)

  @view_action_types ~w(SUBMIT CLOSE)

  @shortcut_types ~w(GLOBAL ON_MESSAGE)

  @typedoc "The unknown-field diagnostic map: wire key to a type tag."
  @type unknown :: %{optional(String.t()) => atom()}

  @typedoc "Every callback this application can classify."
  @type t ::
          Payload.Event.t()
          | Payload.SlashCommand.t()
          | Payload.GlobalShortcut.t()
          | Payload.MessageShortcut.t()
          | Payload.BlockInteraction.t()
          | Payload.ViewAction.t()
          | Payload.DynamicMenu.t()

  @typedoc "The class of a callback, as used by the response table and telemetry."
  @type kind ::
          :event
          | :slash_command
          | :global_shortcut
          | :message_shortcut
          | :block_interaction
          | :view_action
          | :dynamic_menu

  defmodule Event do
    @moduledoc """
    An ordinary Pumble event (`C-1`).

    `messageType` is `PUMBLE_EVENT` or `APP_EVENT`; both classify here, and
    which value carries which event is server behaviour that nothing in the SDK
    decides (`PR-16`). `:message_type` keeps the received value so that a probe
    can answer that question from stored telemetry rather than from a guess.

    `:body` is the decoded event body. On the wire it is a JSON **string**
    inside the envelope and needs a second parse, which the classifier performs.
    Its keys are Pumble's, abbreviated for the five trigger events and spelled
    out for the two lifecycle events (`E-1` to `E-5`, `L-1`, `L-2`).
    """

    alias PumbleAutomation.Pumble.Payload

    @type t :: %__MODULE__{
            message_type: String.t(),
            event_type: String.t(),
            workspace_id: String.t(),
            workspace_user_ids: [String.t()],
            body: map(),
            unknown: Payload.unknown()
          }

    @enforce_keys [:message_type, :event_type, :workspace_id, :body]
    defstruct [
      :message_type,
      :event_type,
      :workspace_id,
      :body,
      workspace_user_ids: [],
      unknown: %{}
    ]
  end

  defmodule SlashCommand do
    @moduledoc """
    A slash command (`C-2`).

    `:slash_command` is the invoked command and `:text` is everything the user
    typed after it. `:thread_root_id` is present only when the command was run
    inside a thread.
    """

    alias PumbleAutomation.Pumble.Payload

    @type t :: %__MODULE__{
            slash_command: String.t(),
            text: String.t(),
            user_id: String.t(),
            channel_id: String.t(),
            thread_root_id: String.t() | nil,
            workspace_id: String.t(),
            trigger_id: String.t(),
            unknown: Payload.unknown()
          }

    @enforce_keys [:slash_command, :user_id, :channel_id, :workspace_id, :trigger_id]
    defstruct [
      :slash_command,
      :user_id,
      :channel_id,
      :thread_root_id,
      :workspace_id,
      :trigger_id,
      text: "",
      unknown: %{}
    ]
  end

  defmodule GlobalShortcut do
    @moduledoc """
    A global shortcut (`C-3`): `messageType` `SHORTCUT` with `type` `GLOBAL`.

    `:shortcut` is the **normalized** manifest name — lowercased with spaces
    replaced by underscores (`M-4`) — not the display name.
    """

    alias PumbleAutomation.Pumble.Payload

    @type t :: %__MODULE__{
            shortcut: String.t(),
            user_id: String.t(),
            channel_id: String.t(),
            thread_root_id: String.t() | nil,
            workspace_id: String.t(),
            trigger_id: String.t(),
            unknown: Payload.unknown()
          }

    @enforce_keys [:shortcut, :user_id, :channel_id, :workspace_id, :trigger_id]
    defstruct [
      :shortcut,
      :user_id,
      :channel_id,
      :thread_root_id,
      :workspace_id,
      :trigger_id,
      unknown: %{}
    ]
  end

  defmodule MessageShortcut do
    @moduledoc """
    A message shortcut (`C-4`): `messageType` `SHORTCUT` with `type` `ON_MESSAGE`.

    `:message_id` is the message the shortcut was run on. It is the only field
    that separates this struct from a global shortcut, and it is required: a
    message shortcut with no message is not a message shortcut.
    """

    alias PumbleAutomation.Pumble.Payload

    @type t :: %__MODULE__{
            shortcut: String.t(),
            message_id: String.t(),
            user_id: String.t(),
            channel_id: String.t(),
            workspace_id: String.t(),
            trigger_id: String.t(),
            unknown: Payload.unknown()
          }

    @enforce_keys [:shortcut, :message_id, :user_id, :channel_id, :workspace_id, :trigger_id]
    defstruct [
      :shortcut,
      :message_id,
      :user_id,
      :channel_id,
      :workspace_id,
      :trigger_id,
      unknown: %{}
    ]
  end

  defmodule BlockInteraction do
    @moduledoc """
    A block interaction (`C-5` to `C-7`).

    The three evidence rows are one struct discriminated by `:source_type`
    (`VIEW`, `MESSAGE`, `EPHEMERAL_MESSAGE`). They differ in which reply helpers
    are available, which is a property of the response and not of the request.

    `:source_id` is the **source object** id — the message id for a `MESSAGE`
    source and the parent view id for a `VIEW` source. It is not a delivery id
    and must never be used as one; see the `I-5` annotation in the evidence
    matrix.

    `:payload` is the block's own opaque string value, carried through unparsed.

    `:loading_timeout` is a client-side spinner budget and has nothing to do
    with the three-second acknowledgement deadline (`X-6`). This application
    emits `loadingTimeout: 0` on the elements it produces, so a nonzero value
    here means the element came from somewhere else.
    """

    alias PumbleAutomation.Pumble.Payload

    @type t :: %__MODULE__{
            workspace_id: String.t(),
            user_id: String.t(),
            channel_id: String.t() | nil,
            source_type: String.t(),
            source_id: String.t(),
            action_type: String.t() | nil,
            on_action: String.t() | nil,
            payload: String.t() | nil,
            view: map() | nil,
            trigger_id: String.t(),
            loading_timeout: integer() | nil,
            unknown: Payload.unknown()
          }

    @enforce_keys [:workspace_id, :user_id, :source_type, :source_id, :trigger_id]
    defstruct [
      :workspace_id,
      :user_id,
      :channel_id,
      :source_type,
      :source_id,
      :action_type,
      :on_action,
      :payload,
      :view,
      :trigger_id,
      :loading_timeout,
      unknown: %{}
    ]
  end

  defmodule ViewAction do
    @moduledoc """
    A view action (`C-8`): a modal was submitted or closed.

    `:view_action_type` is `SUBMIT` or `CLOSE`; no other value is known to
    exist, and a body carrying one is refused rather than guessed at.
    """

    alias PumbleAutomation.Pumble.Payload

    @type t :: %__MODULE__{
            workspace_id: String.t(),
            user_id: String.t(),
            channel_id: String.t() | nil,
            view_action_type: String.t(),
            view: map() | nil,
            trigger_id: String.t(),
            unknown: Payload.unknown()
          }

    @enforce_keys [:workspace_id, :user_id, :view_action_type, :trigger_id]
    defstruct [
      :workspace_id,
      :user_id,
      :channel_id,
      :view_action_type,
      :view,
      :trigger_id,
      unknown: %{}
    ]
  end

  defmodule DynamicMenu do
    @moduledoc """
    A dynamic menu options request (`C-9`).

    This class is synchronous and read-only. It resolves the fixed workflow
    picker registered in the manifest and returns a bounded option list; it
    never creates an execution or records an interaction receipt. It has no
    acknowledgement contract: the reply is the exact options envelope or a
    `nack` when the action, tenant, or result set is absent (`K-4`).
    """

    alias PumbleAutomation.Pumble.Payload

    @type t :: %__MODULE__{
            on_action: String.t(),
            query: String.t() | nil,
            value: String.t() | nil,
            workspace_id: String.t(),
            user_id: String.t(),
            trigger_id: String.t(),
            unknown: Payload.unknown()
          }

    @enforce_keys [:on_action, :workspace_id, :user_id, :trigger_id]
    defstruct [:on_action, :query, :value, :workspace_id, :user_id, :trigger_id, unknown: %{}]
  end

  @doc "Every `messageType` the SDK's `MessageType` enum defines."
  @spec message_types() :: [String.t()]
  def message_types, do: @message_types

  @doc "The two `messageType` values that carry an event (`isPumbleEvent`)."
  @spec event_message_types() :: [String.t()]
  def event_message_types, do: ~w(PUMBLE_EVENT APP_EVENT)

  @doc "The five user-selectable trigger events (`E-1` to `E-5`)."
  @spec trigger_event_types() :: [String.t()]
  def trigger_event_types, do: @trigger_event_types

  @doc "The two lifecycle events (`L-1`, `L-2`). Never user-selectable."
  @spec lifecycle_event_types() :: [String.t()]
  def lifecycle_event_types, do: @lifecycle_event_types

  @doc "Every event name the SDK's `EventMap` types, trigger and lifecycle alike."
  @spec event_types() :: [String.t()]
  def event_types, do: @trigger_event_types ++ @lifecycle_event_types

  @doc "The three block-interaction source types."
  @spec block_interaction_source_types() :: [String.t()]
  def block_interaction_source_types, do: @block_interaction_source_types

  @doc "The two view-action types."
  @spec view_action_types() :: [String.t()]
  def view_action_types, do: @view_action_types

  @doc "The two shortcut types."
  @spec shortcut_types() :: [String.t()]
  def shortcut_types, do: @shortcut_types

  @doc "The cap on the number of unknown fields any one payload records."
  @spec max_unknown_keys() :: pos_integer()
  def max_unknown_keys, do: @max_unknown_keys

  @doc """
  The class of a classified payload.

  Used by the response table and by telemetry, so that neither has to match on
  a struct name.
  """
  @spec kind(t()) :: kind()
  def kind(%Event{}), do: :event
  def kind(%SlashCommand{}), do: :slash_command
  def kind(%GlobalShortcut{}), do: :global_shortcut
  def kind(%MessageShortcut{}), do: :message_shortcut
  def kind(%BlockInteraction{}), do: :block_interaction
  def kind(%ViewAction{}), do: :view_action
  def kind(%DynamicMenu{}), do: :dynamic_menu

  @doc """
  Builds the bounded `:unknown` map for `envelope`, given the keys that were read.

  Keys are sorted before the cap is applied, so the same body always produces
  the same diagnostic map. Values are replaced by a type tag; see the module
  documentation for why.
  """
  @spec unknown_fields(map(), [String.t()]) :: unknown()
  def unknown_fields(envelope, known_keys) when is_map(envelope) and is_list(known_keys) do
    envelope
    |> Map.drop(known_keys)
    |> Enum.filter(fn {key, _value} -> is_binary(key) end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.take(@max_unknown_keys)
    |> Map.new(fn {key, value} -> {key, type_of(value)} end)
  end

  defp type_of(value) when is_binary(value), do: :string
  defp type_of(value) when is_boolean(value), do: :boolean
  defp type_of(value) when is_integer(value), do: :integer
  defp type_of(value) when is_float(value), do: :float
  defp type_of(value) when is_list(value), do: :list
  defp type_of(value) when is_map(value), do: :map
  defp type_of(nil), do: :null
  defp type_of(_value), do: :unknown
end
