defmodule PumbleAutomation.Connections.Resolver do
  @moduledoc """
  Turns a stored connection into something a request may be built from.

  Resolution is where a connection stops being a row and becomes a promise:
  the type is right, the origin still passes the URL rules, the connection is
  enabled, and every header it sets is one it is allowed to set. A row that
  fails any of those is refused here, permanently, rather than at the moment a
  socket is opened.

  ## No plaintext, at any point

  A `PumbleAutomation.Connections.ResolvedConnection` carries secret *handles*.
  Nothing in this module decrypts anything, and nothing in it can: the
  plaintext path is `PumbleAutomation.Connections.SecretResolver`, which the
  Safe HTTP transport calls per header, immediately before writing it.

  ## A node narrows a path, it never escapes one

  `narrow_path/2` is the whole of that rule and it is pure, so Safe HTTP can call it
  without a database and a test can call it with a string. A node's path is
  appended under the connection's prefix, and the result is refused when the
  node's path is absolute against another origin, climbs with `..`, hides a
  climb inside a percent escape, or introduces an empty segment.

  Percent escapes are rejected rather than decoded. `%2e%2e%2f` and `%2f` are
  precisely how a decode-then-check implementation is defeated, and repeating
  the decode until it is stable is a loop with no natural end. A node that
  needs a value inside a path segment gets it from the Safe HTTP request builder,
  which encodes *after* this function has approved the shape.

  ## The Safe HTTP boundary

  Scheme and shape are enforced here. Address policy — private ranges, DNS
  rebinding, redirects, and the deny list — belongs to Safe HTTP and is not simulated here:
  a half-enforced network policy reads like a full one and is worse than an
  absent one. `:policy_version` on the row records which generation of the
  policy approved it.
  """

  import Ecto.Query, only: [from: 2]

  alias PumbleAutomation.Connections.Connection
  alias PumbleAutomation.Connections.ResolvedConnection
  alias PumbleAutomation.Error
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope

  @doc """
  Resolves one of the scope's connections by id.

  Reads with the tenant in the `WHERE` clause, so another workspace's
  connection is not found rather than refused.
  """
  @spec resolve(Scope.t(), Ecto.UUID.t()) ::
          {:ok, ResolvedConnection.t()} | {:error, Error.t()}
  def resolve(%Scope{} = scope, id) do
    resolve_for_action(scope.installation_id, id)
  end

  @doc """
  Resolves a connection inside an execution, where there is no member.

  The authority was decided when the workflow version was activated; the
  tenant is still matched against the row.
  """
  @spec resolve_for_action(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, ResolvedConnection.t()} | {:error, Error.t()}
  def resolve_for_action(installation_id, id) do
    with {:ok, tenant} <- cast_uuid(installation_id),
         {:ok, connection_id} <- cast_uuid(id),
         {:ok, connection} <- fetch(tenant, connection_id) do
      build(connection)
    end
  end

  @doc """
  Validates a stored connection and builds its resolved form.

  Exposed so that activation can hold a connection to the current rules
  without a second read of the row it already has.
  """
  @spec build(Connection.t()) :: {:ok, ResolvedConnection.t()} | {:error, Error.t()}
  def build(%Connection{} = connection) do
    with :ok <- check_type(connection),
         :ok <- check_enabled(connection),
         {:ok, origin} <- Connection.normalize_origin(connection.base_origin),
         {:ok, prefix} <- Connection.normalize_path_prefix(connection.base_path_prefix),
         {:ok, headers} <- Connection.normalize_headers(connection.headers),
         {:ok, handles} <- Connection.normalize_secret_headers(connection.secret_headers) do
      {:ok,
       %ResolvedConnection{
         id: connection.id,
         installation_id: connection.installation_id,
         name: connection.name,
         base_origin: origin,
         base_path_prefix: prefix,
         policy_version: connection.policy_version,
         headers: headers,
         secret_headers: Enum.map(handles, &handle/1)
       }}
    end
  end

  @doc """
  The path a node reaches, under the connection's approved prefix.

  `nil` and `""` both mean "the prefix itself". Anything else is appended to
  the prefix as validated segments. Returns the absolute path, always
  beginning with `/`.

  Refused, as a non-retryable `:validation` error:

    * an absolute URL, or a scheme-relative `//host` path — that is a
      different origin, not a narrowing of this one;
    * a `.` or `..` segment, an empty segment, or a backslash;
    * any percent escape. See the module documentation.
  """
  @spec narrow_path(ResolvedConnection.t() | String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | {:error, Error.t()}
  def narrow_path(connection_or_prefix, node_path)

  def narrow_path(%ResolvedConnection{base_path_prefix: prefix}, node_path) do
    narrow_path(prefix, node_path)
  end

  def narrow_path(prefix, node_path) do
    with {:ok, normalized} <- normalize_prefix(prefix),
         {:ok, segments} <- suffix_segments(node_path) do
      join(normalized, segments)
    end
  end

  @doc """
  The absolute URL a node reaches through `connection`.

  The origin comes from the row and cannot be influenced by the node. The path
  comes from `narrow_path/2`, so a node that tries to escape gets an error
  rather than a URL.
  """
  @spec build_url(ResolvedConnection.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, Error.t()}
  def build_url(%ResolvedConnection{} = connection, node_path) do
    with {:ok, path} <- narrow_path(connection, node_path) do
      {:ok, connection.base_origin <> path}
    end
  end

  @doc """
  The node suffix implied by an already-absolute path under a connection prefix.

  Used when a node rendered a full URL whose origin already matched the
  connection. The path must be the prefix itself or sit under it; a different
  tree is an escape, not a narrowing. Query and fragment must already have
  been stripped.
  """
  @spec suffix_under_prefix(ResolvedConnection.t() | String.t() | nil, String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, Error.t()}
  def suffix_under_prefix(%ResolvedConnection{base_path_prefix: prefix}, path) do
    suffix_under_prefix(prefix, path)
  end

  def suffix_under_prefix(prefix, path) do
    with {:ok, normalized} <- normalize_prefix(prefix),
         {:ok, absolute} <- absolute_path(path) do
      drop_prefix(normalized, absolute)
    end
  end

  @doc """
  Encodes a query map as a stable RFC 3986 query string.

  Keys are sorted so the same map always becomes the same bytes. `nil` and
  `%{}` mean "no query". Values must be strings; spaces and reserved
  characters are percent-encoded. The result never includes a leading `?`.
  """
  @spec encode_query(map() | nil) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def encode_query(query) when query in [nil, %{}], do: {:ok, nil}

  def encode_query(query) when is_map(query) and not is_struct(query) do
    with :ok <- check_query_size(query),
         {:ok, pairs} <- query_pairs(query) do
      {:ok, URI.encode_query(pairs, :rfc3986)}
    end
  end

  def encode_query(_query) do
    {:error, query_error(:query_invalid, "must be a map of text keys and values")}
  end

  @doc """
  Appends an encoded query string (or query map) to a path that begins with `/`.
  """
  @spec with_query(String.t(), map() | String.t() | nil) ::
          {:ok, String.t()} | {:error, Error.t()}
  def with_query(path, query)

  def with_query(path, query) when is_map(query) do
    with {:ok, encoded} <- encode_query(query) do
      with_query(path, encoded)
    end
  end

  def with_query(path, query) when is_binary(path) and query in [nil, ""] do
    path_only(path)
  end

  def with_query(path, query) when is_binary(path) and is_binary(query) do
    with {:ok, path} <- path_only(path) do
      if String.contains?(query, [" ", "\r", "\n", "\t", "#"]) do
        {:error, query_error(:query_invalid, "contains a character a query may not hold")}
      else
        {:ok, path <> "?" <> query}
      end
    end
  end

  def with_query(_path, _query) do
    {:error, path_error(:path_invalid, "is not a path")}
  end

  defp normalize_prefix(prefix) when prefix in [nil, "", "/"], do: {:ok, nil}

  defp normalize_prefix(prefix) when is_binary(prefix) do
    Connection.normalize_path_prefix(prefix)
  end

  defp normalize_prefix(_prefix), do: {:error, path_error(:path_invalid, "is not a path")}

  defp suffix_segments(node_path) when node_path in [nil, ""], do: {:ok, []}

  defp suffix_segments(node_path) when is_binary(node_path) do
    with :ok <- refute_absolute(node_path) do
      Connection.path_segments(node_path)
    end
  end

  defp suffix_segments(_node_path), do: {:error, path_error(:path_invalid, "is not a path")}

  defp join(nil, []), do: {:ok, "/"}
  defp join(nil, segments), do: {:ok, "/" <> Enum.join(segments, "/")}
  defp join(prefix, []), do: {:ok, prefix}

  defp join(prefix, segments) do
    confirm_under(prefix, prefix <> "/" <> Enum.join(segments, "/"))
  end

  # `Connection.path_segments/1` already refuses a backslash and a percent
  # escape. What it cannot see is that the node meant another origin, because
  # "https://evil.test/x" and "//evil.test/x" are both, segment by segment,
  # ordinary paths.
  defp refute_absolute(node_path) do
    cond do
      String.starts_with?(node_path, "//") ->
        {:error, path_error(:path_other_origin, "names another origin")}

      Regex.match?(~r{\A[A-Za-z][A-Za-z0-9+.\-]*:}, node_path) ->
        {:error, path_error(:path_other_origin, "names another origin")}

      String.contains?(node_path, "\\") ->
        {:error, path_error(:path_backslash, "must not contain a backslash")}

      true ->
        :ok
    end
  end

  # The belt to the segment validation's braces. Every rejection above should
  # already have fired; this asserts the invariant the caller actually cares
  # about, which is that the result never leaves the approved prefix.
  defp confirm_under(prefix, path) do
    if path == prefix or String.starts_with?(path, prefix <> "/") do
      {:ok, path}
    else
      {:error, path_error(:path_escapes_prefix, "leaves the connection's approved prefix")}
    end
  end

  defp fetch(installation_id, id) do
    query =
      from connection in Connection,
        where: connection.id == ^id and connection.installation_id == ^installation_id

    case Repo.one(query) do
      nil -> Scope.refuse_unknown(Connection, id, installation_id, :connections)
      connection -> {:ok, connection}
    end
  end

  defp check_type(%Connection{type: "http"}), do: :ok

  defp check_type(%Connection{}) do
    {:error,
     Error.new(:validation, :connection_type_unsupported,
       message: "That connection uses a type this application does not support."
     )}
  end

  defp check_enabled(%Connection{enabled: true}), do: :ok

  defp check_enabled(%Connection{}) do
    {:error,
     Error.new(:conflict, :connection_disabled,
       message: "That connection is disabled.",
       retryable?: false
     )}
  end

  defp handle(%{"header" => header, "secret_id" => secret_id}) do
    %{header: header, secret_id: secret_id}
  end

  defp path_error(code, message) do
    Error.new(:validation, code, message: "The path " <> message <> ".")
  end

  defp query_error(code, message) do
    Error.new(:validation, code, message: "The query " <> message <> ".")
  end

  defp absolute_path(path) when path in [nil, ""], do: {:ok, "/"}

  defp absolute_path(path) when is_binary(path) do
    trimmed = path |> String.trim() |> String.trim_trailing("/")
    trimmed = if trimmed == "", do: "/", else: trimmed

    cond do
      not String.starts_with?(trimmed, "/") ->
        {:error, path_error(:path_invalid, "is not a path")}

      String.contains?(trimmed, ["?", "#", " "]) ->
        {:error, path_error(:path_invalid, "is not a path")}

      true ->
        {:ok, trimmed}
    end
  end

  defp absolute_path(_path), do: {:error, path_error(:path_invalid, "is not a path")}

  defp drop_prefix(nil, "/"), do: {:ok, nil}
  defp drop_prefix(nil, "/" <> rest), do: {:ok, rest}
  defp drop_prefix(prefix, path) when path == prefix, do: {:ok, nil}

  defp drop_prefix(prefix, path) do
    stem = prefix <> "/"

    if String.starts_with?(path, stem) do
      {:ok, String.replace_prefix(path, stem, "")}
    else
      {:error, path_error(:path_escapes_prefix, "leaves the connection's approved prefix")}
    end
  end

  defp path_only(path) when is_binary(path) do
    cond do
      not String.starts_with?(path, "/") ->
        {:error, path_error(:path_invalid, "is not a path")}

      String.contains?(path, ["?", "#"]) ->
        {:error, path_error(:path_invalid, "is not a path")}

      true ->
        {:ok, path}
    end
  end

  defp check_query_size(query) do
    if map_size(query) > Connection.max_headers() * 2 do
      {:error, query_error(:query_invalid, "has too many entries")}
    else
      :ok
    end
  end

  defp query_pairs(query) do
    query
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, acc} ->
      case query_pair(key, value) do
        {:ok, pair} -> {:cont, {:ok, acc ++ [pair]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp query_pair(key, value) when is_binary(key) and is_binary(value) do
    cond do
      key == "" ->
        {:error, query_error(:query_invalid, "must be a map of text keys and values")}

      byte_size(key) > Connection.max_header_value() or
          byte_size(value) > Connection.max_header_value() ->
        {:error, query_error(:query_invalid, "is too large")}

      String.contains?(key, ["\r", "\n", "\t"]) or String.contains?(value, ["\r", "\n", "\t"]) ->
        {:error, query_error(:query_invalid, "contains a character a query may not hold")}

      true ->
        {:ok, {key, value}}
    end
  end

  defp query_pair(_key, _value) do
    {:error, query_error(:query_invalid, "must be a map of text keys and values")}
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, Policy.not_found()}
    end
  end
end
