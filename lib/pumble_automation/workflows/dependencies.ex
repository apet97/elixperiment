defmodule PumbleAutomation.Workflows.Dependencies do
  @moduledoc """
  What a compiled workflow needs before it is allowed to run: P6-T04.

  Every compiled step declares what it needs, and `requirements/2` is what the
  compiler asks to write that declaration. `calculate/1` then reads the
  declarations back and adds them up, so the answer for a whole workflow comes
  from the graph itself rather than from a second reading of its configuration.

  `calculate/1` and `check/2` ask nothing of Pumble, the database, or the
  network. `resolve/2` is the one exception, and it is deliberate: whether a
  connection or a secret exists is a fact about a tenant's rows and cannot be
  known from a document. Even then nothing is decrypted; a secret is found by
  name and answered as an identifier.

  ## Evidence, not assumption

  A scope is claimed only as well as it is known. `PumbleAutomation.Pumble.Scopes`
  tags every operation `:verified`, `:inferred`, or `:unverified`, and that tag
  survives into the answer here:

    * `:verified` and `:inferred` name a scope, so a snapshot that lacks it is
      a proven problem and blocks;
    * `:unverified` names no scope at all, so nothing can be proven about it
      and it can only warn, naming the probe that would settle it.

  An installation with no recorded scopes is unknown rather than empty-handed,
  and `Scopes.check/2` already refuses to call that a missing scope. Blocking a
  workflow because nobody has written down what the workspace granted would be
  a guess wearing an error's clothes.
  """

  import Ecto.Query, only: [from: 2]

  alias PumbleAutomation.Connections.Connection
  alias PumbleAutomation.Connections.Secret
  alias PumbleAutomation.Pumble.Scopes
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Workflows.CompiledWorkflow
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Node.PumbleActionConfig
  alias PumbleAutomation.Workflows.ValidationIssue

  # Which Pumble operations one workflow action performs. A direct message is
  # three calls, not one: `Pumble.Client.send_direct_message/3` resolves the
  # direct channel before it posts, so the scopes of that resolution are part
  # of what the step needs.
  @operations %{
    send_message: [:post_message],
    reply_message: [:reply],
    direct_message: [:get_direct_channel, :create_direct_channel, :send_direct_message],
    add_reaction: [:add_reaction],
    remove_reaction: [:remove_reaction]
  }

  # An approval asks in Pumble, so it posts like any other message step.
  @approval_operations [:post_message]

  @known_operations @operations
                    |> Map.values()
                    |> List.flatten()
                    |> Kernel.++(@approval_operations)

  @typedoc "One operation the workflow performs, and how well its scope is known."
  @type evidence :: %{
          operation: atom(),
          scope: String.t() | nil,
          evidence: :verified | :inferred | :unverified,
          probe: String.t() | nil
        }

  @typedoc "The identifiers a workflow's references turned out to name."
  @type resolved :: %{connection_ids: [Ecto.UUID.t()], secret_ids: [Ecto.UUID.t()]}

  @type t :: %__MODULE__{
          required_scopes: [String.t()],
          scope_evidence: [evidence()],
          connection_ids: [String.t()],
          connection_header_requirements: [{String.t(), String.t()}],
          secret_names: [String.t()],
          trigger_binding: %{String.t() => term()}
        }

  defstruct required_scopes: [],
            scope_evidence: [],
            connection_ids: [],
            connection_header_requirements: [],
            secret_names: [],
            trigger_binding: %{}

  @doc """
  What one step needs, for the compiler to record on the step itself.

  `config` is the compiled configuration, so this reads the same shape whether
  it is called while compiling or against a document read back from storage.
  """
  @spec requirements(Node.type(), %{String.t() => term()}) :: %{String.t() => [String.t()]}
  def requirements(type, config) when is_map(config) do
    operations = operations(type, config)

    %{
      "operations" => operations |> Enum.map(&Atom.to_string/1) |> sorted(),
      "scopes" => operations |> Enum.map(&scope/1) |> Enum.reject(&is_nil/1) |> sorted(),
      "connection_ids" => type |> connections(config) |> sorted(),
      "secret_names" => config |> Map.values() |> Enum.flat_map(&secret_names/1) |> sorted()
    }
  end

  @doc """
  Everything `compiled` depends on, added up from each step's configuration.

  Declarations stored on the node are what a worker can show; this function
  reads the configuration itself, so a document that emptied `requires` cannot
  hide a connection or a secret.
  """
  @spec calculate(CompiledWorkflow.t()) :: t()
  def calculate(%CompiledWorkflow{} = compiled) do
    steps =
      compiled
      |> ordered_nodes()
      |> Enum.map(&Map.put(&1, :requires, requirements(&1.type, &1.config)))

    %__MODULE__{
      required_scopes: collect(steps, "scopes"),
      scope_evidence: steps |> collect("operations") |> Enum.map(&evidence/1),
      connection_ids: collect(steps, "connection_ids"),
      connection_header_requirements: connection_header_requirements(steps),
      secret_names: collect(steps, "secret_names"),
      trigger_binding: compiled.trigger_binding
    }
  end

  @doc """
  The scopes a compiled graph is known to need, sorted and deduplicated.

  Only operations whose scope is established appear. An operation nobody has
  proven a scope for contributes nothing, because a name that was guessed is
  worse in a required list than an absence.
  """
  @spec required_scopes(%{String.t() => CompiledWorkflow.compiled_node()}) :: [String.t()]
  def required_scopes(nodes) when is_map(nodes) do
    nodes |> Map.values() |> collect("scopes")
  end

  @doc """
  Compares what the workflow needs with what the installation recorded.

  A proven missing scope is an error and blocks activation. An operation whose
  scope nobody has established is a warning that names its probe, and never a
  block. `granted` is the installation's own snapshot; an empty snapshot means
  nothing was ever recorded, and `Scopes.check/2` treats it as unknown.
  """
  @spec check(t(), [String.t()]) :: [ValidationIssue.t()]
  def check(%__MODULE__{} = dependencies, granted) when is_list(granted) do
    dependencies.scope_evidence
    |> Enum.flat_map(&scope_issues(&1, granted))
    |> Enum.uniq()
    |> ValidationIssue.sort()
  end

  @doc """
  Turns the references a workflow holds into the identifiers of this tenant's
  rows, or says which of them do not exist here.

  A connection or secret belonging to another installation is indistinguishable
  from one that was never created, and that is the point: a workflow cannot
  learn that another workspace has a connection by naming it. A disabled
  connection is refused too, because activating onto a connection nobody may
  call would only fail later, in front of a customer.

  The secrets of the connections a workflow uses are part of what it depends
  on, so they are answered with the rest. No value is read.
  """
  @spec resolve(t(), Ecto.UUID.t()) :: {:ok, resolved()} | {:error, [ValidationIssue.t()]}
  def resolve(%__MODULE__{} = dependencies, installation_id) do
    {connections, connection_issues} = resolve_connections(dependencies, installation_id)
    {secret_ids, secret_issues} = resolve_secrets(dependencies, installation_id)

    case ValidationIssue.sort(connection_issues ++ secret_issues) do
      [] ->
        {:ok,
         %{
           connection_ids: connections |> Enum.map(& &1.id) |> sorted(),
           secret_ids: (secret_ids ++ Enum.flat_map(connections, & &1.secret_ids)) |> sorted()
         }}

      issues ->
        {:error, issues}
    end
  end

  ## Requirements of one step

  defp operations(:pumble_action, config) do
    Map.get(@operations, action(config), [])
  end

  defp operations(:approval, _config), do: @approval_operations
  defp operations(_type, _config), do: []

  # The compiled configuration holds the wire string, and the operation map is
  # keyed by the action it names.
  defp action(config) do
    Enum.find_value(PumbleActionConfig.actions(), fn {string, atom} ->
      if string == Map.get(config, "action"), do: atom
    end)
  end

  defp connections(:http_action, config) do
    case Map.get(config, "connection_id") do
      id when is_binary(id) -> [id]
      _other -> []
    end
  end

  defp connections(_type, _config), do: []

  # A secret is named in a path inside a compiled template, so finding them is
  # reading the segments the compiler already parsed.
  defp secret_names(%{"template" => segments}) when is_list(segments) do
    for %{"path" => %{"root" => "secret", "name" => name}} <- segments, do: name
  end

  defp secret_names(values) when is_list(values), do: Enum.flat_map(values, &secret_names/1)

  defp secret_names(%{} = value) do
    value |> Map.values() |> Enum.flat_map(&secret_names/1)
  end

  defp secret_names(_value), do: []

  ## Adding the steps up

  # Sorted by identifier so two runs over the same graph answer in one order.
  defp ordered_nodes(%CompiledWorkflow{nodes: nodes}) do
    nodes |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
  end

  defp collect(steps, key) do
    steps
    |> Enum.flat_map(fn step ->
      case Map.get(step.requires, key, []) do
        list when is_list(list) -> list
        _other -> []
      end
    end)
    |> sorted()
  end

  defp connection_header_requirements(steps) do
    steps
    |> Enum.flat_map(fn
      %{type: :http_action, config: config} when is_map(config) ->
        case {Map.get(config, "connection_id"), Map.get(config, "idempotency_header")} do
          {connection_id, header} when is_binary(connection_id) and is_binary(header) ->
            [{connection_id, String.downcase(header)}]

          _other ->
            []
        end

      _step ->
        []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp evidence(operation) when is_binary(operation) do
    operation |> known_operation() |> evidence()
  end

  defp evidence(operation) do
    mapping = Scopes.mapping(operation)

    %{
      operation: operation,
      scope: Scopes.scope_of(mapping),
      # The tag is read rather than matched, so an operation a probe later
      # upgrades to `:verified` needs no change here.
      evidence: elem(mapping, 0),
      probe: probe(mapping)
    }
  end

  # An inferred mapping names the probe that would confirm it and an unverified
  # one names the probe that would settle it; a verified mapping needs neither.
  defp probe(mapping) when tuple_size(mapping) == 3, do: elem(mapping, 2)
  defp probe(mapping), do: if(elem(mapping, 0) == :unverified, do: elem(mapping, 1))

  # The vocabulary is closed by `@operations`, so a name is matched against the
  # operations that can be written rather than turned into an atom.
  defp known_operation(string) do
    Enum.find(@known_operations, :unknown, &(Atom.to_string(&1) == string))
  end

  defp scope(operation), do: operation |> Scopes.mapping() |> Scopes.scope_of()

  ## Comparing with what was granted

  defp scope_issues(%{evidence: :unverified} = entry, _granted) do
    [
      ValidationIssue.warning(
        :scope_unverified,
        "/required_scopes",
        "Whether this workflow needs a permission for #{entry.operation} is not established yet (probe #{entry.probe})."
      )
    ]
  end

  defp scope_issues(entry, granted) do
    case Scopes.check(entry.operation, granted) do
      :ok ->
        []

      {:error, _error} ->
        [
          ValidationIssue.error(
            :scope_missing,
            "/required_scopes",
            "This workspace has not granted the #{entry.scope} permission this workflow needs."
          )
        ]
    end
  end

  ## Resolving against the tenant's rows

  defp resolve_connections(%__MODULE__{connection_ids: []}, _installation_id), do: {[], []}

  defp resolve_connections(
         %__MODULE__{
           connection_ids: ids,
           connection_header_requirements: header_requirements
         },
         installation_id
       ) do
    {usable, unusable} =
      ids |> Enum.map(&Ecto.UUID.cast/1) |> Enum.split_with(&match?({:ok, _}, &1))

    wanted = Enum.map(usable, &elem(&1, 1))

    found =
      Repo.all(
        from connection in Connection,
          where: connection.installation_id == ^installation_id and connection.id in ^wanted,
          select: %{
            id: connection.id,
            enabled: connection.enabled,
            secret_ids: connection.referenced_secret_ids,
            headers: connection.headers,
            secret_headers: connection.secret_headers
          }
      )

    enabled = Enum.filter(found, & &1.enabled)

    issues =
      Enum.map(unusable, fn _cast -> missing_connection(nil) end) ++
        Enum.map(wanted -- Enum.map(found, & &1.id), &missing_connection/1) ++
        Enum.map(found -- enabled, &disabled_connection(&1.id)) ++
        connection_header_issues(enabled, header_requirements)

    {enabled, issues}
  end

  defp resolve_secrets(%__MODULE__{secret_names: []}, _installation_id), do: {[], []}

  defp resolve_secrets(%__MODULE__{secret_names: names}, installation_id) do
    # `:value` is never selected, and the schema would not load it if it were.
    found =
      Repo.all(
        from secret in Secret,
          where: secret.installation_id == ^installation_id and secret.name in ^names,
          select: {secret.name, secret.id}
      )

    {Enum.map(found, &elem(&1, 1)),
     Enum.map(names -- Enum.map(found, &elem(&1, 0)), &missing_secret/1)}
  end

  # The identifier goes in the path rather than the message: a pointer names
  # which reference failed without a sentence quoting what somebody typed.
  defp missing_connection(id) do
    ValidationIssue.error(
      :connection_not_found,
      "/connections/#{id}",
      "A connection this workflow uses does not exist in this workspace."
    )
  end

  defp disabled_connection(id) do
    ValidationIssue.error(
      :connection_disabled,
      "/connections/#{id}",
      "A connection this workflow uses is turned off."
    )
  end

  defp connection_header_issues(connections, requirements) do
    Enum.flat_map(requirements, fn {connection_id, header} ->
      case Enum.find(connections, &(&1.id == connection_id)) do
        nil -> []
        connection -> connection_header_issue(connection, connection_id, header)
      end
    end)
  end

  defp connection_header_issue(connection, connection_id, header) do
    if connection_header?(connection, header) do
      [connection_header_conflict(connection_id, header)]
    else
      []
    end
  end

  defp connection_header?(connection, header) do
    literal? =
      Enum.any?(Map.keys(connection.headers || %{}), &(String.downcase(&1) == header))

    secret? =
      Enum.any?(connection.secret_headers || [], fn handle ->
        name = Map.get(handle, "header") || Map.get(handle, :header)
        is_binary(name) and String.downcase(name) == header
      end)

    literal? or secret?
  end

  defp connection_header_conflict(connection_id, header) do
    ValidationIssue.error(
      :connection_header_conflict,
      "/connections/#{connection_id}/headers/#{header}",
      "The connection already sets this workflow-managed idempotency header."
    )
  end

  defp missing_secret(name) do
    ValidationIssue.error(
      :secret_not_found,
      "/secrets/#{name}",
      "A secret this workflow uses does not exist in this workspace."
    )
  end

  defp sorted(values), do: values |> Enum.uniq() |> Enum.sort()
end
