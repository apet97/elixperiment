defmodule PumbleAutomation.Workflows.Definition.PumbleEventConfig do
  @moduledoc """
  A trigger that fires on a user-visible Pumble event.

  Only the five user-selectable events of Section 5.1 of the plan appear here.
  `APP_UNINSTALLED` and `APP_UNAUTHORIZED` are control-plane events and are
  deliberately absent: a workflow may not be attached to them.
  """

  @events %{
    "NEW_MESSAGE" => :new_message,
    "UPDATED_MESSAGE" => :updated_message,
    "REACTION_ADDED" => :reaction_added,
    "CHANNEL_CREATED" => :channel_created,
    "WORKSPACE_USER_JOINED" => :workspace_user_joined
  }

  @type t :: %__MODULE__{
          event: atom() | nil,
          channel_ids: [String.t()],
          keyword: String.t() | nil,
          ignore_bot_messages: boolean()
        }

  defstruct event: nil, channel_ids: [], keyword: nil, ignore_bot_messages: true

  @doc "The declared fields of a Pumble event trigger configuration."
  @spec fields() :: [{atom(), term(), keyword()}]
  def fields do
    [
      {:event, {:enum, @events}, required: true},
      {:channel_ids, {:list, :string}, default: []},
      {:keyword, :string, max_length: 1024},
      {:ignore_bot_messages, :boolean, default: true}
    ]
  end

  @doc "The user-selectable Pumble events."
  @spec events() :: %{String.t() => atom()}
  def events, do: @events
end

defmodule PumbleAutomation.Workflows.Definition.ManualConfig do
  @moduledoc """
  A trigger a person starts from the slash command or one of the shortcuts.

  The manual alias is the name a person types or picks. It is unique per
  installation, which the `workflows` table enforces on its `slug` column, so
  the alias recorded here and the alias the row is addressed by are the same
  string.
  """

  alias PumbleAutomation.Workflows.ManualAlias

  @type t :: %__MODULE__{
          manual_alias: String.t() | nil,
          slash_command: boolean(),
          global_shortcut: boolean(),
          message_shortcut: boolean()
        }

  defstruct manual_alias: nil,
            slash_command: true,
            global_shortcut: false,
            message_shortcut: false

  @doc "The declared fields of a manual trigger configuration."
  @spec fields() :: [{atom(), term(), keyword()}]
  def fields do
    [
      {:manual_alias, :string,
       max_length: ManualAlias.max_length(),
       max_length_message: ManualAlias.message(),
       format: ManualAlias.format(),
       format_message: ManualAlias.message()},
      {:slash_command, :boolean, default: true},
      {:global_shortcut, :boolean, default: false},
      {:message_shortcut, :boolean, default: false}
    ]
  end
end

defmodule PumbleAutomation.Workflows.Definition.ScheduleConfig do
  @moduledoc """
  A trigger that fires on a clock.

  The five schedule types of Section 5.1 of the plan are the whole set. Which
  of the remaining fields a given type needs is a semantic rule and is checked
  later; what is fixed here is that no sixth type exists and that the timezone
  is carried with the schedule rather than assumed.
  """

  @schedule_types %{
    "once" => :once,
    "every_minutes" => :every_minutes,
    "every_hours" => :every_hours,
    "daily" => :daily,
    "weekly" => :weekly
  }

  @type t :: %__MODULE__{
          schedule_type: atom() | nil,
          interval: pos_integer() | nil,
          run_at: String.t() | nil,
          time_of_day: String.t() | nil,
          weekdays: [String.t()],
          timezone: String.t() | nil
        }

  defstruct schedule_type: nil,
            interval: nil,
            run_at: nil,
            time_of_day: nil,
            weekdays: [],
            timezone: nil

  @doc "The declared fields of a schedule trigger configuration."
  @spec fields() :: [{atom(), term(), keyword()}]
  def fields do
    [
      {:schedule_type, {:enum, @schedule_types}, required: true},
      {:interval, :integer, min: 1, max: 8760},
      {:run_at, :string, max_length: 64},
      {:time_of_day, :string, max_length: 8},
      {:weekdays, {:list, :string}, default: []},
      {:timezone, :string, max_length: 64}
    ]
  end

  @doc "The schedule types a trigger may use."
  @spec schedule_types() :: %{String.t() => atom()}
  def schedule_types, do: @schedule_types
end

defmodule PumbleAutomation.Workflows.Definition.WebhookConfig do
  @moduledoc """
  A trigger fired by a request to a workspace-scoped inbound endpoint.

  Neither the endpoint token nor a body HMAC secret is stored here. A
  definition is copied, exported, and shown on screens. Authentication is the
  endpoint bearer token issued at activation, not a field on this document.
  `require_signature` selects whether activation also issues an encrypted,
  shown-once raw-body HMAC credential for that version-bound endpoint.
  """

  @type t :: %__MODULE__{require_signature: boolean()}

  defstruct require_signature: false

  @doc "The declared fields of a webhook trigger configuration."
  @spec fields() :: [{atom(), term(), keyword()}]
  def fields, do: [{:require_signature, :boolean, default: false}]
end

defmodule PumbleAutomation.Workflows.Definition.ManualTestConfig do
  @moduledoc """
  A trigger that exists only for a browser test run.

  It carries no configuration. Whether a test run may cause an external effect
  is an action taken in the user interface, not a field an author can set.
  """

  @type t :: %__MODULE__{}

  defstruct []

  @doc "The declared fields of a manual test trigger configuration."
  @spec fields() :: [{atom(), term(), keyword()}]
  def fields, do: []
end

defmodule PumbleAutomation.Workflows.Definition.Trigger do
  @moduledoc """
  The single entry point of a definition.

  A definition has exactly one trigger. It has a stable identifier of its own,
  so that a trigger binding and an execution can name it the way they name any
  other step, and a type from the closed set in Section 5.1 of the plan.
  """

  alias PumbleAutomation.Workflows.Definition.ManualConfig
  alias PumbleAutomation.Workflows.Definition.ManualTestConfig
  alias PumbleAutomation.Workflows.Definition.PumbleEventConfig
  alias PumbleAutomation.Workflows.Definition.ScheduleConfig
  alias PumbleAutomation.Workflows.Definition.WebhookConfig
  alias PumbleAutomation.Workflows.Node.Config

  @types %{
    "pumble_event" => :pumble_event,
    "manual" => :manual,
    "schedule" => :schedule,
    "webhook" => :webhook,
    "manual_test" => :manual_test
  }

  @config_modules %{
    pumble_event: PumbleEventConfig,
    manual: ManualConfig,
    schedule: ScheduleConfig,
    webhook: WebhookConfig,
    manual_test: ManualTestConfig
  }

  @type type :: :pumble_event | :manual | :schedule | :webhook | :manual_test

  @type config ::
          PumbleEventConfig.t()
          | ManualConfig.t()
          | ScheduleConfig.t()
          | WebhookConfig.t()
          | ManualTestConfig.t()

  @type t :: %__MODULE__{id: String.t(), type: type(), config: config()}

  @enforce_keys [:id, :type, :config]
  defstruct [:id, :type, :config]

  @doc "Builds a trigger of `type`, generating its identifier."
  @spec new(type(), map() | keyword(), keyword()) :: t()
  def new(type, attrs \\ %{}, opts \\ []) when is_map_key(@config_modules, type) do
    %__MODULE__{
      id: Keyword.get_lazy(opts, :id, &Ecto.UUID.generate/0),
      type: type,
      config: struct!(Map.fetch!(@config_modules, type), attrs)
    }
  end

  @doc "The trigger types a definition may use, as a literal wire-to-atom map."
  @spec types() :: %{String.t() => type()}
  def types, do: @types

  @doc "The configuration module a trigger of `type` carries, or `nil` for an unknown type."
  @spec config_module(term()) :: module() | nil
  def config_module(type), do: Map.get(@config_modules, type)

  @doc "Decodes one raw trigger at `path`."
  @spec decode(term(), String.t()) :: {:ok, t()} | {:error, [Config.issue()]}
  def decode(raw, path) when is_map(raw) and not is_struct(raw) do
    with {:ok, type} <- decode_type(raw, path),
         :ok <- Config.ensure_known_keys(raw, ~w(id type config), path),
         {:ok, id} <- decode_id(raw, path),
         {:ok, config} <-
           Config.decode(
             Map.fetch!(@config_modules, type),
             Map.get(raw, "config", %{}),
             Config.join(path, "config")
           ) do
      {:ok, %__MODULE__{id: id, type: type, config: config}}
    end
  end

  def decode(_raw, path), do: {:error, [Config.issue(path, :missing, "is required")]}

  @doc "Encodes a trigger into a plain, string-keyed map."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = trigger) do
    %{
      "id" => trigger.id,
      "type" => @types |> Enum.find(fn {_string, atom} -> atom == trigger.type end) |> elem(0),
      "config" => Config.encode(trigger.config)
    }
  end

  defp decode_type(raw, path) do
    case Map.get(raw, "type") do
      value when is_binary(value) ->
        case Map.fetch(@types, value) do
          {:ok, type} ->
            {:ok, type}

          :error ->
            {:error,
             [
               Config.issue(
                 Config.join(path, "type"),
                 :unknown_trigger_type,
                 "is not a supported trigger type"
               )
             ]}
        end

      _other ->
        {:error, [Config.issue(Config.join(path, "type"), :missing, "is required")]}
    end
  end

  defp decode_id(raw, path) do
    case Map.get(raw, "id") do
      value when is_binary(value) ->
        case Ecto.UUID.cast(value) do
          {:ok, id} ->
            {:ok, id}

          :error ->
            {:error, [Config.issue(Config.join(path, "id"), :invalid_node_id, "must be a UUID")]}
        end

      _other ->
        {:error, [Config.issue(Config.join(path, "id"), :invalid_node_id, "must be a UUID")]}
    end
  end
end

defmodule PumbleAutomation.Workflows.Definition do
  @moduledoc """
  The editable source of one workflow.

  This is the shape of Section 15.1 of the plan and nothing else: a schema
  version, exactly one trigger, and an ordered list of steps. Branches nest
  inside the steps that own them, so the document is a tree and the editable
  representation has no way to express a cycle or a reference to another node.

      %Definition{schema_version: 1, trigger: %Trigger{}, steps: [%Node{}]}

  The compiled graph of Section 15.2 is a different shape produced later. This
  module never builds it, and never needs a database.

  ## Decoding

  `decode/1` is the only door an untrusted document comes through, and it
  closes behind malformed input in three ways:

    * the schema version must be one this module knows, so a document from a
      future release fails as a version problem rather than as a strange field;
    * every string, list, and map is bounded before it is placed in a struct;
    * every discriminator is read through a literal map, so no string from a
      document becomes an atom and the atom table cannot be made to grow.

  Failure returns a `PumbleAutomation.Error` whose `:details` carry an
  `:issues` list. Each issue names a JSON pointer into the document the caller
  sent, so a form can put a message next to the field that caused it.

  ## Limits

  `validate_limits/1` applies the node, depth, and size limits from
  `PumbleAutomation.Workflows.Limits` to a whole definition, and `decode/1`
  runs it before returning. Every editing primitive runs it too, on the
  finished result, which is why no single operation can leave a definition over
  a limit.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Limits
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Node.Config

  @schema_version 1

  @type t :: %__MODULE__{schema_version: pos_integer(), trigger: Trigger.t(), steps: [Node.t()]}

  @enforce_keys [:trigger]
  defstruct schema_version: @schema_version, trigger: nil, steps: []

  @doc "The schema version this module reads and writes."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Builds a definition from a trigger and an ordered list of steps."
  @spec new(Trigger.t(), [Node.t()]) :: t()
  def new(%Trigger{} = trigger, steps \\ []) when is_list(steps) do
    %__MODULE__{schema_version: @schema_version, trigger: trigger, steps: steps}
  end

  @doc """
  Decodes a JSON-decoded map into a definition.

  The input has string keys, because it came from a document. Nothing in this
  path converts one of those keys or values into an atom.
  """
  @spec decode(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode(raw) when is_map(raw) and not is_struct(raw) do
    with :ok <- check_root_size(raw),
         :ok <- Config.ensure_known_keys(raw, ~w(schema_version trigger steps), ""),
         :ok <- check_schema_version(raw),
         {:ok, trigger} <- Trigger.decode(Map.get(raw, "trigger"), "/trigger"),
         {:ok, steps} <- Node.decode_sequence(Map.get(raw, "steps", []), "/steps") do
      definition = %__MODULE__{schema_version: @schema_version, trigger: trigger, steps: steps}

      case validate_limits(definition) do
        :ok -> {:ok, definition}
        {:error, %Error{}} = error -> error
      end
    else
      {:error, %Error{}} = error -> error
      {:error, issues} when is_list(issues) -> {:error, invalid(issues)}
    end
  end

  def decode(_raw) do
    {:error, invalid([Config.issue("", :invalid_type, "must be an object")])}
  end

  @doc "Encodes a definition into a plain, string-keyed map ready for storage."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = definition) do
    %{
      "schema_version" => definition.schema_version,
      "trigger" => Trigger.encode(definition.trigger),
      "steps" => Enum.map(definition.steps, &Node.encode/1)
    }
  end

  @doc "Every node in the definition, in document order."
  @spec nodes(t()) :: [Node.t()]
  def nodes(%__MODULE__{} = definition), do: Enum.flat_map(definition.steps, &Node.flatten/1)

  @doc "The identifier of every node in the definition, in document order."
  @spec node_ids(t()) :: [String.t()]
  def node_ids(%__MODULE__{} = definition), do: Enum.map(nodes(definition), & &1.id)

  @doc "How many nodes the definition contains. The trigger is not a node."
  @spec node_count(t()) :: non_neg_integer()
  def node_count(%__MODULE__{} = definition), do: length(nodes(definition))

  @doc """
  The deepest branch nesting the definition reaches.

  A definition with no steps has depth `0`. A flat list of steps has depth `1`.
  Each level of branch nesting adds one.
  """
  @spec depth(t()) :: non_neg_integer()
  def depth(%__MODULE__{} = definition), do: sequence_depth(definition.steps)

  @doc "The node with `id`, wherever it is nested."
  @spec fetch_node(t(), String.t()) :: {:ok, Node.t()} | :error
  def fetch_node(%__MODULE__{} = definition, id) when is_binary(id) do
    case Enum.find(nodes(definition), &(&1.id == id)) do
      nil -> :error
      node -> {:ok, node}
    end
  end

  @doc """
  Checks a whole definition against every structural limit.

  Node count, branch depth, identifier uniqueness, and serialized size, in that
  order, so the cheapest answer is given first.
  """
  @spec validate_limits(t()) :: :ok | {:error, Error.t()}
  def validate_limits(%__MODULE__{} = definition) do
    with :ok <- Limits.check_nodes(node_count(definition)),
         :ok <- Limits.check_depth(depth(definition)),
         :ok <- Limits.check_unique_ids(node_ids(definition)) do
      Limits.check_size(encode(definition))
    end
  end

  @doc "Builds the `:validation` error that carries decode issues."
  @spec invalid([Config.issue()]) :: Error.t()
  def invalid(issues) when is_list(issues) do
    Error.new(:validation, :invalid_definition,
      message: "The workflow definition is not valid.",
      details: %{issues: Enum.take(issues, 50)}
    )
  end

  # Written as a recursion over integers rather than as a reduce, so that the
  # depth of a definition is an integer to the type checker as well as to the
  # reader: `Enum.reduce/3` returns `any()`, which widens `1 + acc` to a number.
  defp sequence_depth([]), do: 0

  defp sequence_depth([node | rest]) do
    largest(1 + node_branch_depth(node), sequence_depth(rest))
  end

  defp node_branch_depth(%Node{} = node), do: branches_depth(Node.branch_keys(node.type), node)

  defp branches_depth([], _node), do: 0

  defp branches_depth([key | rest], node) do
    largest(sequence_depth(Map.get(node.branches, key, [])), branches_depth(rest, node))
  end

  defp largest(left, right) when is_integer(left) and is_integer(right) and left >= right,
    do: left

  defp largest(_left, right) when is_integer(right), do: right

  defp check_root_size(raw) do
    if map_size(raw) > Limits.max_map_size() do
      {:error, invalid([Config.issue("", :too_many_keys, "has too many fields")])}
    else
      :ok
    end
  end

  defp check_schema_version(raw) do
    case Map.get(raw, "schema_version") do
      @schema_version ->
        :ok

      other ->
        {:error,
         Error.new(:validation, :unsupported_schema_version,
           message: "The workflow definition uses an unsupported schema version.",
           details: %{
             supported: @schema_version,
             received: if(is_integer(other), do: other, else: :not_an_integer)
           }
         )}
    end
  end
end
