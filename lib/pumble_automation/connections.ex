defmodule PumbleAutomation.Connections do
  @moduledoc """
  The only supported way to read or change a secret or an HTTP connection.

  Every public function takes a `PumbleAutomation.Scope` first, and there is no
  arity that omits it. Both halves of this context describe the same thing —
  what a workflow is allowed to send outward, and with which credential — so
  they share one module, one tenancy rule, and one dependency rule.

  ## The value is never returned

  There is no function here that returns a secret's plaintext, and no option
  that makes one. `PumbleAutomation.Connections.Secret` declares its `:value`
  field `load_in_query: false`, so the column is not even fetched by the
  queries this module writes, and every returned struct additionally has its
  `:value` set to `nil` — including the one that comes straight back from the
  insert that created it.

  The single reader is `PumbleAutomation.Connections.SecretResolver`, which is
  a separate module, is documented as executor-only, and takes an installation
  id rather than a scope because it runs where there is no member.

  ## Which role may do what

    * `editor` reads metadata: `list_secrets/1`, `get_secret/2`,
      `list_connections/1`, `get_connection/2`. An editor builds the workflow
      that names a secret, so an editor has to be able to see that the name
      exists. A `viewer` cannot: enumerating the credentials a workspace holds
      is not part of reading a workflow.
    * `owner` writes: creating, rotating, updating, and deleting either kind.
      Plan Section 11.3 gives secrets to the owner, and the product contract
      names "secrets and external HTTP connections" as one capability, so both
      are gated on `:manage_secrets` rather than inventing a second permission
      that the contract does not describe.

  ## Another workspace's identifier does not exist

  Every read and every write answers
  `PumbleAutomation.Installations.Policy.not_found/0` for an identifier from
  another workspace — the identical error a random UUID gets. That covers the
  secret ids inside a connection's header references too: a connection cannot
  be written that names a secret from another tenant, and the refusal does not
  say whether that secret exists.

  ## Deletion is refused while something references it

  Plan Section 14.5's failure behaviour allows either refusing the delete or
  degrading the workflows that referenced it. This context refuses, and names
  the referencing workflows and connections in the error, because an explicit
  refusal an owner can act on is better than a silent degradation an execution
  discovers at run time.

  "Referenced" means named by the version a workflow is *actively running* —
  its `active_version_id` — or, for a secret, named by any connection in the
  same tenant. Historical versions are not counted: refusing forever because
  some superseded draft once mentioned a secret would make every credential
  undeletable.

  ## Auditing

  Creating, rotating, updating, and deleting each write an audit row through
  `PumbleAutomation.Audit.Writer.append/3` inside the same transaction, so a
  change that cannot be recorded does not happen. The metadata carries the
  name and the kind. It never carries the value, the fingerprint, or a header.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Audit.Writer
  alias PumbleAutomation.Connections.Connection
  alias PumbleAutomation.Connections.ResolvedConnection
  alias PumbleAutomation.Connections.Resolver
  alias PumbleAutomation.Connections.SafeHttp
  alias PumbleAutomation.Connections.Secret
  alias PumbleAutomation.Connections.SecretResolver
  alias PumbleAutomation.Connections.UrlPolicy
  alias PumbleAutomation.Error
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Installations.Service
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomation.Workflows.WorkflowVersion

  # Seeing that a credential exists is editor work; changing one is owner work.
  # See the module documentation.
  @read_capability :manage_workflows
  @write_capability :manage_secrets

  @doc """
  Lists the scope's secrets as metadata, newest first.

  Never returns a value. The select is explicit so that adding a column to the
  schema cannot silently add it to this list.
  """
  @spec list_secrets(Scope.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_secrets(%Scope{} = scope) do
    with :ok <- Policy.authorize(scope, @read_capability) do
      query =
        from secret in Secret,
          where: secret.installation_id == ^scope.installation_id,
          order_by: [asc: secret.name],
          select: %{
            id: secret.id,
            name: secret.name,
            kind: secret.kind,
            description: secret.description,
            key_version: secret.key_version,
            last_rotated_at: secret.last_rotated_at,
            last_used_at: secret.last_used_at,
            inserted_at: secret.inserted_at
          }

      {:ok, Repo.all(query)}
    end
  end

  @doc "One of the scope's secrets, as metadata. The struct's `:value` is `nil`."
  @spec get_secret(Scope.t(), Ecto.UUID.t()) :: {:ok, Secret.t()} | {:error, Error.t()}
  def get_secret(%Scope{} = scope, id) do
    with :ok <- Policy.authorize(scope, @read_capability) do
      fetch_secret(scope, id)
    end
  end

  @doc """
  Creates a secret and audits it in the same transaction.

  `attrs` carries `:name`, `:value`, and optionally `:kind` and
  `:description`. The tenant and the author come from the scope. The returned
  struct carries no value.
  """
  @spec create_secret(Scope.t(), map()) :: {:ok, Secret.t()} | {:error, Error.t()}
  def create_secret(%Scope{} = scope, attrs) when is_map(attrs) do
    with :ok <- Policy.authorize(scope, @write_capability) do
      changeset =
        Secret.create_changeset(%{
          installation_id: scope.installation_id,
          name: value_of(attrs, :name),
          value: value_of(attrs, :value),
          kind: value_of(attrs, :kind),
          description: value_of(attrs, :description),
          created_by_member_id: scope.member_id
        })

      Multi.new()
      |> Service.as_multi()
      |> Multi.insert(:secret, changeset)
      |> audit_secret(scope, "secret.created")
      |> commit(:secret)
      |> scrub()
    end
  end

  @doc """
  Replaces a secret's value and audits the rotation in the same transaction.

  Only the value moves; see `PumbleAutomation.Connections.Secret.rotate_changeset/2`.
  Rotating to the value the secret already holds is a `:validation` error, not
  a silent success.
  """
  @spec rotate_secret(Scope.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, Secret.t()} | {:error, Error.t()}
  def rotate_secret(%Scope{} = scope, id, value) do
    with {:ok, secret} <- fetch_secret(scope, id),
         :ok <- Policy.authorize(scope, @write_capability) do
      Multi.new()
      |> Service.as_multi()
      |> Multi.update(:secret, Secret.rotate_changeset(secret, value))
      |> audit_secret(scope, "secret.rotated")
      |> commit(:secret)
      |> scrub()
    end
  end

  @doc """
  Deletes a secret, if nothing references it.

  Refused with a `:conflict` naming the referencing workflows and connections
  while any of them still names it. See the module documentation for what
  "references" means.
  """
  @spec delete_secret(Scope.t(), Ecto.UUID.t()) :: {:ok, Secret.t()} | {:error, Error.t()}
  def delete_secret(%Scope{} = scope, id) do
    with {:ok, secret} <- fetch_secret(scope, id),
         :ok <- Policy.authorize(scope, @write_capability),
         :ok <- refute_secret_referenced(scope, secret) do
      Multi.new()
      |> Service.as_multi()
      |> Multi.delete(:secret, secret)
      |> audit_secret(scope, "secret.deleted")
      |> commit(:secret)
      |> scrub()
    end
  end

  @doc "Lists the scope's connections, by name."
  @spec list_connections(Scope.t()) :: {:ok, [Connection.t()]} | {:error, Error.t()}
  def list_connections(%Scope{} = scope) do
    with :ok <- Policy.authorize(scope, @read_capability) do
      query =
        from connection in Connection,
          where: connection.installation_id == ^scope.installation_id,
          order_by: [asc: connection.name]

      {:ok, Repo.all(query)}
    end
  end

  @doc "One of the scope's connections."
  @spec get_connection(Scope.t(), Ecto.UUID.t()) ::
          {:ok, Connection.t()} | {:error, Error.t()}
  def get_connection(%Scope{} = scope, id) do
    with :ok <- Policy.authorize(scope, @read_capability) do
      fetch_connection(scope, id)
    end
  end

  @doc """
  Creates a connection and audits it in the same transaction.

  `attrs` carries `:name` and `:base_origin`, and optionally
  `:base_path_prefix`, `:headers`, `:secret_headers`, and `:enabled`. Every
  secret named by `:secret_headers` must be a secret of this tenant.
  """
  @spec create_connection(Scope.t(), map()) :: {:ok, Connection.t()} | {:error, Error.t()}
  def create_connection(%Scope{} = scope, attrs) when is_map(attrs) do
    with :ok <- Policy.authorize(scope, @write_capability) do
      changeset =
        Connection.create_changeset(%{
          installation_id: scope.installation_id,
          name: value_of(attrs, :name),
          base_origin: value_of(attrs, :base_origin),
          base_path_prefix: value_of(attrs, :base_path_prefix),
          headers: value_of(attrs, :headers) || %{},
          secret_headers: value_of(attrs, :secret_headers) || [],
          enabled: enabled_of(attrs),
          created_by_member_id: scope.member_id
        })

      write_connection(scope, changeset, "connection.created", &Multi.insert/3)
    end
  end

  @doc """
  Updates a connection and audits it in the same transaction.

  The tenant, the type, and the creator are not changeable. Everything else is
  revalidated from scratch, so an update can never leave a row that the create
  rules would have refused.
  """
  @spec update_connection(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, Connection.t()} | {:error, Error.t()}
  def update_connection(%Scope{} = scope, id, attrs) when is_map(attrs) do
    with {:ok, connection} <- fetch_connection(scope, id),
         :ok <- Policy.authorize(scope, @write_capability) do
      changeset = Connection.update_changeset(connection, string_keys(attrs))
      write_connection(scope, changeset, "connection.updated", &Multi.update/3)
    end
  end

  @doc """
  Deletes a connection, if no actively running workflow version references it.
  """
  @spec delete_connection(Scope.t(), Ecto.UUID.t()) ::
          {:ok, Connection.t()} | {:error, Error.t()}
  def delete_connection(%Scope{} = scope, id) do
    with {:ok, connection} <- fetch_connection(scope, id),
         :ok <- Policy.authorize(scope, @write_capability),
         :ok <- refute_connection_referenced(scope, connection) do
      Multi.new()
      |> Service.as_multi()
      |> Multi.delete(:connection, connection)
      |> audit_connection(scope, "connection.deleted")
      |> commit(:connection)
    end
  end

  @doc """
  Sends a GET probe through a connection using SafeHttp.

  Authorizes the owner, resolves the stored origin and headers, then pins the
  destination with `UrlPolicy` and opens the socket with `SafeHttp`. There is
  no second HTTP stack. The returned map names a safe result, optional status,
  and a short outcome sentence. It never includes a body, a header value, or a
  secret.

  Options are forwarded to URL policy and the transport so a test can inject
  DNS and a connector. Production callers pass none.
  """
  @spec test_connection(Scope.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def test_connection(%Scope{} = scope, id, opts \\ []) do
    with {:ok, connection} <- fetch_connection(scope, id),
         :ok <- Policy.authorize(scope, @write_capability),
         {:ok, resolved} <- Resolver.build(connection),
         {:ok, outcome} <- probe(resolved, opts) do
      :ok = record_test(scope, connection, outcome)
      {:ok, outcome}
    end
  end

  @doc """
  Workflow and connection names that currently reference each secret or connection.

  One pair of queries for the whole tenant, so a list page does not look up
  each row. Historical versions are ignored, matching delete refusal.
  """
  @spec usage_index(Scope.t()) :: {:ok, map()} | {:error, Error.t()}
  def usage_index(%Scope{} = scope) do
    with :ok <- Policy.authorize(scope, @read_capability) do
      {:ok,
       %{
         secrets: secret_usage_index(scope),
         connections: connection_usage_index(scope)
       }}
    end
  end

  @doc """
  The latest safe `connection.tested` audit row for each connection in the tenant.
  """
  @spec last_test_outcomes(Scope.t()) :: {:ok, %{String.t() => map()}} | {:error, Error.t()}
  def last_test_outcomes(%Scope{} = scope) do
    with :ok <- Policy.authorize(scope, @read_capability) do
      query =
        from event in AuditEvent,
          where: event.installation_id == ^scope.installation_id,
          where: event.action == "connection.tested",
          distinct: event.resource_id,
          order_by: [asc: event.resource_id, desc: event.inserted_at],
          select: %{
            resource_id: event.resource_id,
            metadata: event.metadata,
            inserted_at: event.inserted_at
          }

      {:ok, Map.new(Repo.all(query), &test_outcome/1)}
    end
  end

  defp probe(%ResolvedConnection{} = resolved, opts) do
    policy_opts = Keyword.take(opts, [:resolver, :allow_http, :now, :ttl_ms])
    transport_opts = Keyword.take(opts, [:connect, :transport_opts, :timeout_ms, :now])

    with {:ok, url} <- Resolver.build_url(resolved, nil),
         {:ok, path} <- Resolver.narrow_path(resolved, nil),
         {:ok, target} <- UrlPolicy.approve(url, policy_opts),
         {:ok, headers} <- probe_headers(resolved) do
      request = %{method: :get, path: path, headers: headers, body: nil}
      finish_probe(SafeHttp.request(target, request, transport_opts))
    else
      {:error, %Error{} = error} -> probe_error(error)
    end
  end

  defp probe_headers(%ResolvedConnection{} = resolved) do
    literals = Enum.map(resolved.headers, fn {name, value} -> {name, value} end)

    Enum.reduce_while(resolved.secret_headers, {:ok, literals}, fn handle, {:ok, acc} ->
      case SecretResolver.resolve_for_action(resolved.installation_id, handle.secret_id) do
        {:ok, value} -> {:cont, {:ok, [{handle.header, value} | acc]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp finish_probe({:ok, response}) do
    status = response.status
    result = if status in 200..399, do: "ok", else: "failed"

    {:ok,
     %{
       result: result,
       http_status: status,
       outcome: "HTTP #{status}",
       tested_at: DateTime.utc_now()
     }}
  end

  defp finish_probe({:error, %Error{} = error}), do: probe_error(error)

  defp probe_error(%Error{code: :target_blocked} = error) do
    {:ok, probe_outcome("blocked", error.message)}
  end

  defp probe_error(%Error{class: class} = error)
       when class in [:validation, :dependency, :timeout] do
    {:ok, probe_outcome("failed", error.message)}
  end

  defp probe_error(%Error{} = error), do: {:error, error}

  defp probe_outcome(result, message) do
    %{
      result: result,
      http_status: nil,
      outcome: message,
      tested_at: DateTime.utc_now()
    }
  end

  defp record_test(%Scope{} = scope, %Connection{} = connection, outcome) do
    metadata = %{
      "result" => outcome.result,
      "outcome" => clip(outcome.outcome, 200),
      "actor_role" => scope.role,
      "resource_name" => connection.name
    }

    metadata =
      if is_integer(outcome.http_status) do
        Map.put(metadata, "http_status", outcome.http_status)
      else
        metadata
      end

    _ =
      Writer.append_best_effort(%{
        installation_id: scope.installation_id,
        actor_type: "user",
        actor_id: scope.member_id,
        action: "connection.tested",
        resource_type: "connection",
        resource_id: connection.id,
        metadata: metadata
      })

    :ok
  end

  defp clip(text, max) when is_binary(text) and byte_size(text) > max do
    binary_part(text, 0, max)
  end

  defp clip(text, _max) when is_binary(text), do: text
  defp clip(_text, _max), do: ""

  defp test_outcome(row) do
    metadata = row.metadata || %{}

    {row.resource_id,
     %{
       result: Map.get(metadata, "result"),
       http_status: Map.get(metadata, "http_status"),
       outcome: Map.get(metadata, "outcome"),
       tested_at: row.inserted_at
     }}
  end

  defp secret_usage_index(%Scope{} = scope) do
    workflows = invert_names(active_id_names(scope, :referenced_secret_ids))
    connections = invert_names(connection_secret_names(scope))
    ids = Map.keys(workflows) ++ Map.keys(connections)

    Map.new(Enum.uniq(ids), fn id ->
      {id,
       %{
         workflows: Enum.sort(Map.get(workflows, id, [])),
         connections: Enum.sort(Map.get(connections, id, []))
       }}
    end)
  end

  defp connection_usage_index(%Scope{} = scope) do
    Map.new(invert_names(active_id_names(scope, :referenced_connection_ids)), fn {id, names} ->
      {id, %{workflows: Enum.sort(names)}}
    end)
  end

  defp active_id_names(%Scope{} = scope, field) do
    query =
      from workflow in Workflow,
        join: version in WorkflowVersion,
        on: version.id == workflow.active_version_id,
        where: workflow.installation_id == ^scope.installation_id,
        select: {field(version, ^field), workflow.name}

    Repo.all(query)
  end

  defp connection_secret_names(%Scope{} = scope) do
    query =
      from connection in Connection,
        where: connection.installation_id == ^scope.installation_id,
        select: {connection.referenced_secret_ids, connection.name}

    Repo.all(query)
  end

  defp invert_names(rows) do
    Enum.reduce(rows, %{}, fn {ids, name}, acc ->
      Enum.reduce(ids || [], acc, fn id, acc ->
        Map.update(acc, id, [name], fn names -> Enum.uniq([name | names]) end)
      end)
    end)
  end

  defp write_connection(scope, changeset, action, step_fun) do
    with :ok <- check_secret_references(scope, changeset) do
      Multi.new()
      |> Service.as_multi()
      |> step_fun.(:connection, changeset)
      |> audit_connection(scope, action)
      |> commit(:connection)
    end
  end

  # Every secret a connection names has to be one of this tenant's secrets. A
  # missing id and another tenant's id produce the same error, so a connection
  # cannot be used to probe another workspace.
  defp check_secret_references(%Scope{} = scope, changeset) do
    ids = Ecto.Changeset.get_field(changeset, :referenced_secret_ids) || []

    if changeset.valid? and ids != [] do
      query =
        from secret in Secret,
          where: secret.installation_id == ^scope.installation_id and secret.id in ^ids,
          select: secret.id

      case Enum.sort(ids) -- Enum.sort(Repo.all(query)) do
        [] -> :ok
        _missing -> {:error, Policy.not_found()}
      end
    else
      :ok
    end
  end

  defp refute_secret_referenced(%Scope{} = scope, %Secret{} = secret) do
    workflows = active_workflow_names(scope, :referenced_secret_ids, secret.id)
    connections = connection_names_using(scope, secret.id)

    if workflows == [] and connections == [] do
      :ok
    else
      {:error,
       Error.new(:conflict, :secret_in_use,
         message: "That secret is still used by #{used_by(workflows, connections)}.",
         details: %{workflows: workflows, connections: connections}
       )}
    end
  end

  defp refute_connection_referenced(%Scope{} = scope, %Connection{} = connection) do
    case active_workflow_names(scope, :referenced_connection_ids, connection.id) do
      [] ->
        :ok

      workflows ->
        {:error,
         Error.new(:conflict, :connection_in_use,
           message: "That connection is still used by #{used_by(workflows, [])}.",
           details: %{workflows: workflows}
         )}
    end
  end

  # Only the version a workflow is actually running counts. See the module
  # documentation for why history does not.
  defp active_workflow_names(%Scope{} = scope, field, id) do
    query =
      from workflow in Workflow,
        join: version in WorkflowVersion,
        on: version.id == workflow.active_version_id,
        where: workflow.installation_id == ^scope.installation_id,
        where: fragment("? = ANY(?)", type(^id, Ecto.UUID), field(version, ^field)),
        order_by: [asc: workflow.name],
        select: workflow.name

    Repo.all(query)
  end

  defp connection_names_using(%Scope{} = scope, secret_id) do
    query =
      from connection in Connection,
        where: connection.installation_id == ^scope.installation_id,
        where:
          fragment("? = ANY(?)", type(^secret_id, Ecto.UUID), connection.referenced_secret_ids),
        order_by: [asc: connection.name],
        select: connection.name

    Repo.all(query)
  end

  defp used_by(workflows, connections) do
    [workflow_phrase(workflows), connection_phrase(connections)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" and ")
  end

  defp workflow_phrase([]), do: nil
  defp workflow_phrase(names), do: "workflow " <> Enum.join(names, ", ")

  defp connection_phrase([]), do: nil
  defp connection_phrase(names), do: "connection " <> Enum.join(names, ", ")

  defp fetch_secret(%Scope{} = scope, id) do
    fetch(scope, Secret, id)
  end

  defp fetch_connection(%Scope{} = scope, id) do
    fetch(scope, Connection, id)
  end

  defp fetch(%Scope{} = scope, schema, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> one(scope, schema, uuid)
      :error -> {:error, Policy.not_found()}
    end
  end

  defp one(%Scope{} = scope, schema, uuid) do
    query =
      from row in schema,
        where: row.id == ^uuid and row.installation_id == ^scope.installation_id

    case Repo.one(query) do
      nil -> Scope.refuse_unknown(schema, uuid, scope.installation_id, :connections)
      row -> {:ok, row}
    end
  end

  defp audit_secret(multi, %Scope{} = scope, action) do
    Writer.append(multi, :audit, fn %{secret: secret} ->
      %{
        installation_id: scope.installation_id,
        actor_type: "user",
        actor_id: scope.member_id,
        action: action,
        resource_type: "secret",
        resource_id: secret.id,
        metadata: %{
          "resource_name" => secret.name,
          "target_kind" => secret.kind,
          "actor_role" => scope.role
        }
      }
    end)
  end

  defp audit_connection(multi, %Scope{} = scope, action) do
    Writer.append(multi, :audit, fn %{connection: connection} ->
      %{
        installation_id: scope.installation_id,
        actor_type: "user",
        actor_id: scope.member_id,
        action: action,
        resource_type: "connection",
        resource_id: connection.id,
        metadata: %{
          "resource_name" => connection.name,
          "target_kind" => connection.type,
          "actor_role" => scope.role,
          "count" => length(connection.referenced_secret_ids)
        }
      }
    end)
  end

  defp commit(multi, step) do
    case Repo.transaction(multi) do
      {:ok, changes} ->
        {:ok, Map.fetch!(changes, step)}

      {:error, _step, %Ecto.Changeset{} = changeset, _done} ->
        {:error, changeset_error(changeset)}

      {:error, _step, reason, _done} ->
        {:error,
         Error.new(:internal, :connections_write_failed,
           message: "The change could not be applied.",
           cause: reason
         )}
    end
  end

  # Keeps a plaintext value from reaching a caller through the struct an insert
  # or an update hands back. See the module documentation.
  defp scrub({:ok, %Secret{} = secret}), do: {:ok, %{secret | value: nil}}
  defp scrub({:error, %Error{}} = error), do: error

  defp changeset_error(%Ecto.Changeset{data: %Secret{}} = changeset) do
    if unique_name?(changeset) do
      Error.new(:conflict, :secret_name_taken,
        message: "Another secret in this workspace already uses that name."
      )
    else
      Error.new(:validation, first_code(changeset, :invalid_secret),
        message: "The secret is not valid.",
        details: %{fields: field_names(changeset)}
      )
    end
  end

  defp changeset_error(%Ecto.Changeset{data: %Connection{}} = changeset) do
    if unique_name?(changeset) do
      Error.new(:conflict, :connection_name_taken,
        message: "Another connection in this workspace already uses that name."
      )
    else
      Error.new(:validation, first_code(changeset, :invalid_connection),
        message: "The connection is not valid.",
        details: %{fields: field_names(changeset)}
      )
    end
  end

  defp changeset_error(%Ecto.Changeset{} = changeset) do
    Error.new(:internal, :audit_write_failed,
      message: "The change could not be recorded and was not applied.",
      details: %{fields: field_names(changeset)}
    )
  end

  # The header and URL rules build a typed error and carry its code into the
  # changeset, so the caller sees the specific reason rather than "invalid".
  defp first_code(%Ecto.Changeset{errors: errors}, fallback) do
    Enum.find_value(errors, fallback, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :code)
    end)
  end

  defp unique_name?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :unique
    end)
  end

  defp field_names(%Ecto.Changeset{errors: errors}) do
    Enum.map(errors, fn {field, _error} -> field end)
  end

  defp value_of(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  # `value_of/2` cannot be used here: `false` is a legitimate value and would
  # be lost by the `||` that resolves the two key styles.
  defp enabled_of(attrs) do
    case Map.get(attrs, :enabled, Map.get(attrs, "enabled", true)) do
      nil -> true
      enabled -> enabled
    end
  end

  # `Connection.update_changeset/2` casts, so it needs one key style. A caller
  # that passed atoms and a caller that passed strings must reach the same
  # changeset, and `cast/3` refuses a map that mixes the two.
  defp string_keys(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end
end
