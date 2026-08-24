defmodule PumbleAutomation.Workflows.TriggerBinding do
  @moduledoc """
  What ingress looks up instead of scanning workflows.

  One row says: inside this workspace, a trigger of this class and type, with
  this channel, user, or alias, belongs to this immutable version. That is
  enough to turn an inbound event into a set of versions with one index
  lookup, and no more than that: the trigger's real configuration stays in the
  version's `source_definition`, and this row is rebuilt from it on every
  activation.

  ## Why a projection rather than a query over definitions

  A definition is a document. Matching an event against a document means
  parsing it, which means parsing every active document on every event. The
  columns here are exactly the ones a `WHERE` clause can use, which is the
  whole design: `installation_id, kind, type, channel_id` under a partial index
  on `enabled`.

  ## Disabled never matches

  `matching/2` filters on `enabled` in the database, not in Elixir, and the
  lookup index is itself partial on `enabled`. Deactivation is therefore one
  `UPDATE ... SET enabled = false`, and a disabled row costs nothing at read
  time and still says what used to be true.

  ## The alias belongs to whoever holds it now

  A `manual` binding's `:alias` is unique among the enabled bindings of one
  installation. Two workflows may have owned `deploy` in turn; only one may
  answer to it at a time. Handing it over is disabling one row and enabling
  another, inside one transaction.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Workflows.Definition.PumbleEventConfig
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.Workflow

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(pumble_event manual schedule webhook manual_test)

  # Uninstalled (and its terminal successor) must not produce candidates.
  # Degraded or revoked tenants are still tenant-correct; admission is later.
  @excluded_installation_statuses ~w(uninstalled deleted)

  @type_max 64
  @discriminator_max 128
  @alias_max 64

  @fields ~w(installation_id workflow_version_id kind type channel_id user_id alias
             filter_config enabled)a

  @type t :: %__MODULE__{}

  schema "trigger_bindings" do
    field :installation_id, :binary_id
    field :workflow_version_id, :binary_id
    field :kind, :string
    field :type, :string
    field :channel_id, :string
    field :user_id, :string
    field :alias, :string
    field :filter_config, :map, default: %{}
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Builds an insert or an enable/disable update."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = binding, attrs) do
    binding
    |> cast(attrs, @fields)
    |> validate_required([:installation_id, :workflow_version_id, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:type, min: 1, max: @type_max)
    |> validate_length(:channel_id, min: 1, max: @discriminator_max)
    |> validate_length(:user_id, min: 1, max: @discriminator_max)
    |> validate_length(:alias, min: 1, max: @alias_max)
    |> unique_constraint(
      [:workflow_version_id, :kind, :type, :channel_id, :user_id, :alias],
      name: :trigger_bindings_identity_index
    )
    |> unique_constraint(:alias, name: :trigger_bindings_enabled_alias_index)
    |> check_constraint(:kind, name: :trigger_bindings_kind_check)
    |> foreign_key_constraint(:workflow_version_id)
    |> foreign_key_constraint(:installation_id)
  end

  @doc """
  The query that answers "which versions want this event".

  `opts` names the discriminators the class uses: `:type`, `:channel_id`,
  `:user_id`, `:alias`. An omitted discriminator is not compared, so a binding
  that watches every channel — one whose `channel_id` is `NULL` — matches an
  event in any channel, while a binding naming a channel matches only that one.

  Written as a query rather than as a fetch so a caller may compose a preload
  or a select onto it. The lookup index is `(installation_id, kind, type,
  channel_id) WHERE enabled`. `user_id` and `alias` use `IS NULL OR =`, so
  the planner is not required to pick that index. Ingress uses `candidates/2`,
  which composes this query with live-version and installation checks.
  """
  @spec matching(Ecto.UUID.t(), keyword()) :: Ecto.Query.t()
  def matching(installation_id, opts \\ []) do
    kind = Keyword.fetch!(opts, :kind)

    base =
      from b in __MODULE__,
        where: b.installation_id == ^installation_id and b.kind == ^kind and b.enabled

    opts
    |> Keyword.take([:type, :channel_id, :user_id, :alias])
    |> Enum.reduce(base, &add_discriminator/2)
  end

  @doc """
  Indexed candidates for one inbound trigger: live, enabled, tenant-scoped.

  Builds on `matching/2` (or `by_alias/2` for a manual alias) and then keeps
  only rows whose version is the workflow's `active_version_id` and whose
  installation is still installed. The result is ordered by version id, then
  binding id, so one snapshot always yields the same sequence.

  The SELECT list is the binding row. Workflow JSON and version documents are
  not loaded; remaining typed filters run in Elixir after this query.
  """
  @spec candidates(Ecto.UUID.t(), keyword()) :: Ecto.Query.t()
  def candidates(installation_id, opts) do
    installation_id
    |> indexed_bindings(opts)
    |> restrict_to_live_versions()
  end

  # `nil` means "any", so a selective binding matches its own value and a
  # binding that left the column empty matches everything.
  defp add_discriminator({field, value}, query) do
    from b in query, where: is_nil(field(b, ^field)) or field(b, ^field) == ^value
  end

  @doc """
  The binding a manual alias currently resolves to, if any.

  Exactly one enabled binding per installation may hold an alias, which the
  partial unique index enforces, so this returns a query yielding at most one
  row.
  """
  @spec by_alias(Ecto.UUID.t(), String.t()) :: Ecto.Query.t()
  def by_alias(installation_id, alias_name) when is_binary(alias_name) do
    from b in __MODULE__,
      where:
        b.installation_id == ^installation_id and b.enabled and b.alias == ^alias_name and
          b.kind == "manual"
  end

  defp indexed_bindings(installation_id, opts) do
    kind = Keyword.fetch!(opts, :kind)

    case {kind, Keyword.get(opts, :alias)} do
      {"manual", alias_name} when is_binary(alias_name) and alias_name != "" ->
        by_alias(installation_id, alias_name)

      _ ->
        matching(installation_id, opts)
    end
  end

  defp restrict_to_live_versions(query) do
    from b in query,
      join: i in Installation,
      on: i.id == b.installation_id,
      join: w in Workflow,
      on: w.installation_id == b.installation_id and w.active_version_id == b.workflow_version_id,
      where: i.status not in ^@excluded_installation_statuses and w.status == "active",
      order_by: [asc: b.workflow_version_id, asc: b.id],
      select: b
  end

  @doc """
  Builds the binding attributes a trigger projects to.

  One place turns a trigger into rows, so what activation writes and what
  ingress reads cannot drift. A `pumble_event` trigger naming three channels
  projects to three rows; a trigger naming none projects to one row with no
  channel, which matches everywhere.
  """
  @spec project(Trigger.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: [map()]
  def project(%Trigger{} = trigger, installation_id, workflow_version_id) do
    common = %{installation_id: installation_id, workflow_version_id: workflow_version_id}

    trigger
    |> bindings()
    |> Enum.map(&Map.merge(common, &1))
  end

  @doc """
  What distinguishes each row a trigger projects to, without the identifiers.

  Compiling happens before there is a version to belong to, so the compiler
  records what is true of the trigger itself and activation adds the rest
  through `project/3`. Both come from here, so there is still one description
  of what a trigger binds to.
  """
  @spec discriminators(Trigger.t()) :: [map()]
  def discriminators(%Trigger{} = trigger), do: bindings(trigger)

  # `:type` is the wire event name, not the internal atom, because the string
  # ingress compares against is the one Pumble sends.
  defp bindings(%Trigger{type: :pumble_event, config: config}) do
    event = wire_event(config.event)
    filter = %{"keyword" => config.keyword, "ignore_bot_messages" => config.ignore_bot_messages}

    case config.channel_ids do
      [] ->
        [%{kind: "pumble_event", type: event, channel_id: nil, filter_config: filter}]

      channels ->
        Enum.map(
          channels,
          &%{kind: "pumble_event", type: event, channel_id: &1, filter_config: filter}
        )
    end
  end

  # One row, not one per entry point. The alias is unique among an
  # installation's enabled bindings, so three rows sharing an alias would
  # collide with each other. Which entry points are open is a filter, not a
  # discriminator: the lookup is by alias either way.
  defp bindings(%Trigger{type: :manual, config: config}) do
    [
      %{
        kind: "manual",
        type: "manual",
        alias: config.manual_alias,
        filter_config: %{
          "slash_command" => config.slash_command,
          "global_shortcut" => config.global_shortcut,
          "message_shortcut" => config.message_shortcut
        }
      }
    ]
  end

  defp bindings(%Trigger{type: :schedule, config: config}) do
    [
      %{
        kind: "schedule",
        type: config.schedule_type && Atom.to_string(config.schedule_type)
      }
    ]
  end

  defp bindings(%Trigger{type: type}), do: [%{kind: Atom.to_string(type)}]

  defp wire_event(nil), do: nil

  defp wire_event(event) do
    PumbleEventConfig.events()
    |> Enum.find(fn {_wire, atom} -> atom == event end)
    |> elem(0)
  end
end
