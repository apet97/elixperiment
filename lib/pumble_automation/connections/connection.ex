defmodule PumbleAutomation.Connections.Connection do
  @moduledoc """
  One tenant's reusable outbound HTTP configuration.

  A connection says where a request may go and which fixed headers it carries.
  It holds no script, no retry code, no template, and no secret value. The
  connection schema fixes the columns; this module is the only writer of them and
  the only place that decides whether a base URL or a header name is
  acceptable.

  ## One type

  `type` is `"http"` and a check constraint says so. The column exists so a
  second type is an additive change rather than a second table. It is not an
  extension point that a caller may set.

  ## What a header may be called

  Header names are normalized to lowercase and must match the RFC 9110 token
  grammar. Then two lists apply:

    * `blocked_headers/0` — never settable by anyone. `host`,
      `content-length`, `transfer-encoding`, `connection`, `expect`, every
      hop-by-hop name, and every `proxy-*` name. These are framing and routing
      decisions that belong to the transport; a caller that sets them is either
      confused or attempting request smuggling.
    * `authorization` — never a literal header, only a secret-backed one.
      Authorization is exactly the value that must not sit in a row a workflow
      author can read, which is what the secret reference is for.

  A name may not appear in both the literal map and the secret-backed list. The
  merge order would then decide which one wins, and a security rule settled by
  a merge order is not settled.

  ## What a base URL may be

  `https` only, with a host, no userinfo, no path, no query, and no fragment.
  A path lives in `base_path_prefix`, which begins with `/`, never ends with
  one, and never contains a `.` or `..` segment.

  ## The Safe HTTP boundary

  The full outbound URL policy — private address ranges, DNS rebinding,
  redirect handling, the deny list, and the request itself — belongs to Safe HTTP. What is
  enforced here is scheme and shape: the checks that can be made against a
  stored row without resolving a name or opening a socket. `policy_version`
  records which generation of that policy a row was written under, so the
  stricter Safe HTTP policy can find every row that predates it instead of trusting
  that they were all rewritten.

  ## Redaction

  No column holds a secret value, so there is nothing here to redact. What the
  row does hold is secret *ids*, and `PumbleAutomation.Connections` checks that
  every one of them names a secret in the same tenant on every write.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PumbleAutomation.Error

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Framing, routing, and hop-by-hop names. Never settable, by any path.
  @blocked_headers ~w(
    host content-length transfer-encoding connection expect
    keep-alive te trailer trailers upgrade
    proxy-authenticate proxy-authorization proxy-connection
  )

  # Settable, but only as a secret-backed reference.
  @secret_only_headers ~w(authorization)

  @header_name_format ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
  @header_value_format ~r/\A[\x20-\x7E\t]*\z/
  @name_format ~r/\A[A-Za-z0-9][A-Za-z0-9 _.\-]{0,99}\z/
  @path_segment_format ~r/\A[A-Za-z0-9\-._~!$&'()*+,;=:@]+\z/

  @max_headers 20
  @max_header_value 1_024
  @max_origin 255
  @max_path_prefix 255
  @policy_version 1

  @type t :: %__MODULE__{}

  @typedoc "One secret-backed header: which header, and which secret fills it."
  @type secret_header :: %{header: String.t(), secret_id: Ecto.UUID.t()}

  schema "connections" do
    field :installation_id, :binary_id
    field :name, :string
    field :type, :string, default: "http"
    field :base_origin, :string
    field :base_path_prefix, :string
    field :headers, :map, default: %{}
    field :secret_headers, {:array, :map}, default: []
    field :referenced_secret_ids, {:array, Ecto.UUID}, default: []
    field :enabled, :boolean, default: true
    field :policy_version, :integer, default: @policy_version
    field :created_by_member_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Header names no connection may set, under any name or any path."
  @spec blocked_headers() :: [String.t()]
  def blocked_headers, do: @blocked_headers

  @doc "Header names settable only as a secret-backed reference."
  @spec secret_only_headers() :: [String.t()]
  def secret_only_headers, do: @secret_only_headers

  @doc "The outbound policy generation a row written today records."
  @spec policy_version() :: pos_integer()
  def policy_version, do: @policy_version

  @doc "The greatest number of headers one connection may carry, literal and secret backed together."
  @spec max_headers() :: pos_integer()
  def max_headers, do: @max_headers

  @doc "The token grammar a header name must match, so one rule serves every outbound header."
  @spec header_name_format() :: Regex.t()
  def header_name_format, do: @header_name_format

  @doc "The characters a header value may carry."
  @spec header_value_format() :: Regex.t()
  def header_value_format, do: @header_value_format

  @doc "The greatest size of one header value."
  @spec max_header_value() :: pos_integer()
  def max_header_value, do: @max_header_value

  @doc """
  Builds the insertion changeset.

  `installation_id`, `name`, and `base_origin` are required. `type` and
  `policy_version` are set here and ignored when a caller supplies them.
  """
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :installation_id,
      :name,
      :base_origin,
      :base_path_prefix,
      :headers,
      :secret_headers,
      :enabled,
      :created_by_member_id
    ])
    |> put_change(:type, "http")
    |> put_change(:policy_version, @policy_version)
    |> validate_required([:installation_id, :name, :base_origin])
    |> validate_all()
  end

  @doc """
  Builds the update changeset.

  The tenant, the type, and the creator are not castable: a connection that
  could change tenant is not tenant scoped, and a connection that could change
  type would skip the validation rules its new type never had.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = connection, attrs) when is_map(attrs) do
    connection
    |> cast(attrs, [
      :name,
      :base_origin,
      :base_path_prefix,
      :headers,
      :secret_headers,
      :enabled
    ])
    |> validate_required([:name, :base_origin])
    |> validate_all()
  end

  @doc """
  Normalizes and checks a base origin.

  Returns the canonical `"https://host"` or `"https://host:port"` string, or a
  `:validation` error. See the module documentation for the rule and for the
  Safe HTTP boundary.
  """
  @spec normalize_origin(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def normalize_origin(origin) when is_binary(origin) do
    uri = URI.parse(String.trim(origin))

    with :ok <- check_authority(uri),
         :ok <- check_no_path_part(uri),
         :ok <- check_origin_length(origin) do
      {:ok, canonical_origin(uri)}
    end
  end

  def normalize_origin(_origin), do: origin_error(:origin_invalid, "is not a URL")

  @doc """
  Normalizes and checks an optional base path prefix.

  `nil` and `""` both mean "no prefix" and both normalize to `nil`. Anything
  else must begin with `/`, must contain only ordinary path segments, and must
  contain no `.` or `..` segment: a prefix that can climb is not a prefix.
  """
  @spec normalize_path_prefix(term()) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def normalize_path_prefix(prefix) when prefix in [nil, "", "/"], do: {:ok, nil}

  def normalize_path_prefix(prefix) when is_binary(prefix) do
    trimmed = String.trim_trailing(prefix, "/")

    with :ok <- check_prefix_shape(trimmed),
         {:ok, segments} <- path_segments(trimmed) do
      {:ok, "/" <> Enum.join(segments, "/")}
    end
  end

  def normalize_path_prefix(_prefix), do: path_error(:path_invalid, "is not a path")

  @doc """
  Splits a path into validated segments.

  Rejects an empty segment, a `.` or `..` segment, any percent escape, and any
  character outside the unreserved and sub-delimiter sets. Percent escapes are
  rejected rather than decoded, because `%2e%2e` and `%2f` are the two ways a
  decode-then-check implementation lets a traversal through, and a connection
  path has no legitimate need for one. Encoding a value into a path is the Safe HTTP
  request builder's job, after this check has run.
  """
  @spec path_segments(String.t()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def path_segments("/" <> rest), do: path_segments(rest)

  def path_segments(path) when is_binary(path) do
    segments = String.split(path, "/")

    cond do
      Enum.any?(segments, &(&1 in ["", ".", ".."])) ->
        path_error(:path_traversal, "must not contain an empty, '.', or '..' segment")

      String.contains?(path, "%") ->
        path_error(:path_percent_encoded, "must not contain a percent escape")

      Enum.any?(segments, &(not Regex.match?(@path_segment_format, &1))) ->
        path_error(:path_invalid_segment, "contains a character a path segment may not hold")

      true ->
        {:ok, segments}
    end
  end

  @doc """
  Normalizes and checks a map of fixed literal headers.

  Names are lowercased. A blocked name, a secret-only name, a malformed name,
  and a value carrying a control character are all refused.
  """
  @spec normalize_headers(term()) :: {:ok, %{String.t() => String.t()}} | {:error, Error.t()}
  def normalize_headers(headers) when is_map(headers) and not is_struct(headers) do
    Enum.reduce_while(headers, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case normalize_literal_header(name, value) do
        {:ok, {key, val}} -> {:cont, {:ok, Map.put(acc, key, val)}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  def normalize_headers(nil), do: {:ok, %{}}
  def normalize_headers(_headers), do: header_error(:headers_invalid, "must be a map")

  @doc """
  Normalizes and checks the secret-backed header references.

  Each entry becomes `%{"header" => name, "secret_id" => uuid}` with a
  lowercased name. `authorization` is allowed here and only here; every other
  block rule still applies.
  """
  @spec normalize_secret_headers(term()) :: {:ok, [map()]} | {:error, Error.t()}
  def normalize_secret_headers(nil), do: {:ok, []}

  def normalize_secret_headers(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case normalize_secret_header(entry) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  def normalize_secret_headers(_entries) do
    header_error(:secret_headers_invalid, "must be a list of header references")
  end

  defp validate_all(changeset) do
    changeset
    |> validate_format(:name, @name_format)
    |> validate_length(:base_origin, max: @max_origin)
    |> validate_length(:base_path_prefix, max: @max_path_prefix)
    |> apply_normalizer(:base_origin, &normalize_origin/1)
    |> apply_normalizer(:base_path_prefix, &normalize_path_prefix/1)
    |> apply_normalizer(:headers, &normalize_headers/1)
    |> apply_normalizer(:secret_headers, &normalize_secret_headers/1)
    |> validate_no_overlap()
    |> validate_header_count()
    |> put_referenced_secret_ids()
    |> unique_constraint([:installation_id, :name],
      name: :connections_installation_id_name_index
    )
    |> check_constraint(:type, name: :connections_type_check)
    |> check_constraint(:base_origin, name: :connections_base_origin_check)
    |> foreign_key_constraint(:installation_id)
  end

  # Runs one normalizer over one field and writes the canonical value back, so
  # the row that is stored is the one the checks were run against.
  defp apply_normalizer(changeset, field, normalizer) do
    case fetch_field(changeset, field) do
      {_source, value} ->
        case normalizer.(value) do
          {:ok, normalized} ->
            put_change(changeset, field, normalized)

          {:error, %Error{} = error} ->
            add_error(changeset, field, error.message, code: error.code)
        end

      :error ->
        changeset
    end
  end

  defp validate_no_overlap(changeset) do
    literal = changeset |> get_field(:headers) |> Kernel.||(%{}) |> Map.keys() |> MapSet.new()
    referenced = changeset |> secret_header_names() |> MapSet.new()
    overlap = MapSet.intersection(literal, referenced)

    if Enum.empty?(overlap) do
      changeset
    else
      add_error(
        changeset,
        :secret_headers,
        "names a header the literal headers already set: #{Enum.join(overlap, ", ")}"
      )
    end
  end

  defp validate_header_count(changeset) do
    literal = changeset |> get_field(:headers) |> Kernel.||(%{}) |> map_size()
    referenced = changeset |> get_field(:secret_headers) |> Kernel.||([]) |> length()

    if literal + referenced > @max_headers do
      add_error(changeset, :headers, "sets more than #{@max_headers} headers")
    else
      changeset
    end
  end

  defp put_referenced_secret_ids(changeset) do
    ids =
      changeset
      |> get_field(:secret_headers)
      |> Kernel.||([])
      |> Enum.map(&Map.get(&1, "secret_id"))
      |> Enum.uniq()

    put_change(changeset, :referenced_secret_ids, ids)
  end

  defp secret_header_names(changeset) do
    changeset
    |> get_field(:secret_headers)
    |> Kernel.||([])
    |> Enum.map(&Map.get(&1, "header"))
  end

  defp normalize_literal_header(name, value) do
    with {:ok, key} <- normalize_header_name(name, @secret_only_headers),
         {:ok, val} <- normalize_header_value(key, value) do
      {:ok, {key, val}}
    end
  end

  defp normalize_secret_header(entry) when is_map(entry) do
    name = Map.get(entry, :header) || Map.get(entry, "header")
    secret_id = Map.get(entry, :secret_id) || Map.get(entry, "secret_id")

    with {:ok, key} <- normalize_header_name(name, []),
         {:ok, id} <- cast_secret_id(secret_id) do
      {:ok, %{"header" => key, "secret_id" => id}}
    end
  end

  defp normalize_secret_header(_entry) do
    header_error(:secret_header_invalid, "must be a map with a header and a secret id")
  end

  defp normalize_header_name(name, extra_blocked) when is_binary(name) do
    key = name |> String.trim() |> String.downcase()

    cond do
      not Regex.match?(@header_name_format, key) ->
        header_error(:header_name_invalid, "is not a valid header name: #{inspect(name)}")

      key in @blocked_headers or String.starts_with?(key, "proxy-") ->
        header_error(:header_blocked, "sets the reserved header #{key}")

      key in extra_blocked ->
        header_error(
          :header_secret_only,
          "sets #{key}, which is only settable as a secret-backed header"
        )

      true ->
        {:ok, key}
    end
  end

  defp normalize_header_name(_name, _extra_blocked) do
    header_error(:header_name_invalid, "is not a valid header name")
  end

  defp normalize_header_value(key, value) when is_binary(value) do
    cond do
      byte_size(value) > @max_header_value ->
        header_error(:header_value_too_long, "value for #{key} is too long")

      not Regex.match?(@header_value_format, value) ->
        header_error(:header_value_invalid, "value for #{key} carries a control character")

      true ->
        {:ok, value}
    end
  end

  defp normalize_header_value(key, _value) do
    header_error(:header_value_invalid, "value for #{key} must be a string")
  end

  defp cast_secret_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> header_error(:secret_header_invalid, "names no secret")
    end
  end

  defp check_authority(%URI{} = uri) do
    cond do
      uri.scheme != "https" ->
        origin_error(:origin_not_https, "must use https://")

      is_nil(uri.host) or uri.host == "" ->
        origin_error(:origin_without_host, "needs a host")

      not is_nil(uri.userinfo) ->
        origin_error(:origin_with_userinfo, "must not carry a user name")

      true ->
        :ok
    end
  end

  defp check_no_path_part(%URI{} = uri) do
    cond do
      not is_nil(uri.fragment) -> origin_error(:origin_with_fragment, "must not carry a fragment")
      not is_nil(uri.query) -> origin_error(:origin_with_query, "must not carry a query")
      uri.path not in [nil, "", "/"] -> origin_error(:origin_with_path, "must not carry a path")
      true -> :ok
    end
  end

  defp check_origin_length(origin) when byte_size(origin) > @max_origin do
    origin_error(:origin_too_long, "is too long")
  end

  defp check_origin_length(_origin), do: :ok

  defp check_prefix_shape("/" <> _rest), do: :ok
  defp check_prefix_shape(_prefix), do: path_error(:path_not_absolute, "must begin with '/'")

  defp canonical_origin(%URI{host: host, port: port} = uri) do
    if port in [nil, URI.default_port(uri.scheme)] do
      "https://" <> host
    else
      "https://" <> host <> ":" <> Integer.to_string(port)
    end
  end

  defp origin_error(code, message) do
    {:error, Error.new(:validation, code, message: "The base URL " <> message <> ".")}
  end

  defp path_error(code, message) do
    {:error, Error.new(:validation, code, message: "The path " <> message <> ".")}
  end

  defp header_error(code, message) do
    {:error, Error.new(:validation, code, message: "The header set " <> message <> ".")}
  end
end
