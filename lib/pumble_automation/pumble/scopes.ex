defmodule PumbleAutomation.Pumble.Scopes do
  @moduledoc """
  Which Pumble scope each adapter operation needs, and how well that is known.

  Two facts from `docs/evidence/pumble_source_matrix.md` Section 8 shape this
  module:

    * the scope *vocabulary* is closed. `S-16` records sixteen strings, taken
      from vendor documentation that calls itself "the list of all available
      scopes". A string outside `catalog/0` is not a Pumble scope.
    * the scope *mapping* is not closed. Every row of the matrix's mapping table
      is `INFERRED` or `PROBE REQUIRED`, and `PR-07` is open. Nothing here is
      server-proven.

  ## An unproven mapping is a different type, not a footnote

  A mapping is one of three shapes, and they are distinguishable by pattern
  match so that a caller cannot treat a guess as a fact:

    * `{:verified, scope}` — proven against the live API by a probe.
    * `{:inferred, scope, probe_id}` — the matrix names a scope, the server has
      not confirmed it.
    * `{:unverified, probe_id}` — no scope is known at all.

  There are no `:verified` entries today, and there will be none until `PR-07`
  closes with live evidence.

  ## The gate refuses only what the snapshot proves absent

  `check/2` returns a local permanent error before the network only when the
  operation maps to a named scope *and* the installation's recorded request set
  is non-empty *and* that set does not contain the scope. An empty snapshot
  means "this application never recorded which scopes it requested", which is
  the default (`config/config.exs` requests no scopes), and it is not evidence
  of absence. Presence in this snapshot does not prove that Pumble granted the
  scope; a provider `403` remains authoritative. An `:unverified` mapping never
  gates anything: an unknown mapping must not be able to block a call that
  would have worked.
  """

  alias PumbleAutomation.Pumble.Client.Error

  @probe "PR-07"

  # `S-16`, verbatim from SDK documentation. Used to refuse a typo at the one
  # place scopes are named, so a mapping cannot drift into a string Pumble has
  # never heard of.
  @catalog ~w(
    messages:read messages:write messages:edit messages:delete
    attachments:write user:read status:write reaction:read reaction:write
    channels:list channels:read channels:write users:list workspace:read
    calls:write files:write
  )

  # Operation to scope. Every entry cites its matrix row in the comment beside
  # it; every entry is unproven, which is why every entry carries `PR-07`.
  @mappings %{
    # `S-1`: post, reply, ephemeral, and the send step of a DM.
    post_message: {:inferred, "messages:write", @probe},
    reply: {:inferred, "messages:write", @probe},
    send_direct_message: {:inferred, "messages:write", @probe},
    # `S-4`: the direct-channel create step.
    create_direct_channel: {:inferred, "channels:write", @probe},
    # The direct-channel *lookup* has no row of its own. `S-5` splits channel
    # reads into `channels:read` and `channels:list`, and neither description
    # names a direct-channel lookup, so nothing is claimed here.
    get_direct_channel: {:unverified, @probe},
    # `S-3`: "React to messages" is the only catalog entry a reaction write can
    # use, now that the vocabulary is closed.
    add_reaction: {:inferred, "reaction:write", @probe},
    remove_reaction: {:inferred, "reaction:write", @probe},
    # `S-7`: "Read workspace information".
    get_workspace_info: {:inferred, "workspace:read", @probe},
    # `A-14` is the OAuth identity endpoint, outside `/v1`. No mapping row
    # covers it and no catalog entry names it.
    get_profile: {:unverified, @probe},
    # `S-8`: the closed catalog contains no home-view scope. This is the one
    # mapping the SDK source made *less* certain, not more.
    publish_home_view: {:unverified, @probe}
  }

  @typedoc "How well the scope for an operation is known."
  @type mapping ::
          {:verified, String.t()}
          | {:inferred, String.t(), String.t()}
          | {:unverified, String.t()}

  @doc "The closed scope vocabulary (`S-16`)."
  @spec catalog() :: [String.t()]
  def catalog, do: @catalog

  @doc "Every operation this adapter can perform, in mapping order."
  @spec operations() :: [atom()]
  def operations, do: @mappings |> Map.keys() |> Enum.sort()

  @doc """
  The mapping for `operation`.

  An operation with no entry is `{:unverified, "PR-07"}`, so a new operation
  cannot silently inherit a scope it was never mapped to.
  """
  @spec mapping(atom()) :: mapping()
  def mapping(operation), do: Map.get(@mappings, operation, {:unverified, @probe})

  @doc """
  The scope name for `operation`, or `nil` when none is known.

  Used to annotate a `403`, never to decide one.
  """
  @spec scope(atom()) :: String.t() | nil
  def scope(operation), do: scope_of(mapping(operation))

  @doc "The scope named by a mapping, or `nil` when it names none."
  @spec scope_of(mapping()) :: String.t() | nil
  def scope_of({:verified, name}), do: name
  def scope_of({:inferred, name, _probe}), do: name
  def scope_of({:unverified, _probe}), do: nil

  @doc """
  Whether the recorded request set contains `scope`.

  A blank snapshot proves nothing, so it answers `false` here and is handled as
  "unknown" by `check/2`. A present value proves only what the application
  requested, not what Pumble granted.
  """
  @spec has_scope?([String.t()], String.t()) :: boolean()
  def has_scope?(recorded, scope) when is_list(recorded) and is_binary(scope) do
    scope in recorded
  end

  @doc """
  The pre-network scope gate for `operation` against an installation snapshot.

  Returns `:ok` when the call may be attempted, and `{:error, error}` with class
  `:missing_scope` when the snapshot proves the required scope was not
  requested.
  """
  @spec check(atom(), [String.t()]) :: :ok | {:error, Error.t()}
  def check(operation, recorded) when is_list(recorded) do
    check_mapping(mapping(operation), recorded, operation)
  end

  @doc """
  The gate itself, over an explicit mapping.

  Separated from `check/2` so that the rule can be exercised against each of the
  three mapping shapes, including the `:verified` shape that no operation
  carries yet.
  """
  @spec check_mapping(mapping(), [String.t()], atom()) :: :ok | {:error, Error.t()}
  def check_mapping(mapping, recorded, operation \\ nil)

  def check_mapping({:unverified, _probe}, _recorded, _operation), do: :ok
  def check_mapping(_mapping, [], _operation), do: :ok

  def check_mapping({:verified, scope}, recorded, operation) do
    gate(scope, recorded, operation, nil)
  end

  def check_mapping({:inferred, scope, probe}, recorded, operation) do
    gate(scope, recorded, operation, probe)
  end

  defp gate(scope, recorded, operation, probe) do
    if has_scope?(recorded, scope) do
      :ok
    else
      {:error,
       Error.new(:missing_scope,
         operation: operation,
         body_summary: missing_summary(scope, probe)
       )}
    end
  end

  defp missing_summary(scope, nil), do: "the installation did not request #{scope}"

  defp missing_summary(scope, probe),
    do: "the installation did not request #{scope} (mapping unproven, #{probe})"
end
