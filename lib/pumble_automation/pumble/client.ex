defmodule PumbleAutomation.Pumble.Client do
  @moduledoc """
  Every Pumble API call this product makes, as one named function each.

  A client is bound to one installation when it is built and cannot be pointed
  at another: `new/3` is the only constructor, `:installation_id` has no setter,
  and every operation reads the id from the struct it was given rather than from
  an argument. A caller that wants to act for a second workspace builds a second
  client, which forces the tenancy decision into the open.

  The struct holds no token. Credentials are resolved through
  `PumbleAutomation.Installations.Credentials` at request time and live only
  for the duration of that request, so a revocation between two calls is seen by
  the second one.

  ## The whole surface

  | Function | Method and path | Matrix row |
  |---|---|---|
  | `get_profile/1` | `GET /oauth2/me` | `A-14` |
  | `get_workspace_info/1` | `GET /v1/workspace` | `A-13` |
  | `post_message/3` | `POST /v1/channels/{cId}/messages` | `A-1` |
  | `reply/4` | `POST /v1/channels/{cId}/messages/{trId}` | `A-2` |
  | `get_direct_channel/2` | `GET /v1/channels/direct` | `A-4` |
  | `create_direct_channel/2` | `POST /v1/channels/direct` | `A-4` |
  | `send_direct_message/3` | the three calls of `A-4` in order | `A-4` |
  | `add_reaction/4` | `POST /v1/messages/{mId}/reactions` | `A-5` |
  | `remove_reaction/3` | `DELETE /v1/messages/{mId}/reactions` | `A-6` |
  | `publish_home_view/3` | `POST /v1/app/homeView/workspaceUsers/{userId}` | `A-15` |

  Nothing else exists, and there is no generic request function. A workflow node
  reaches Pumble only through one of these ten, and each of them builds its own
  path from validated identifiers, so no caller can name an endpoint.

  ## Every call is refused locally before it is refused remotely

  In order: the credential is resolved (a revoked installation stops here), the
  scope gate runs against the installation's recorded requested-scope snapshot,
  the payload is validated, and only then does a request reach the network.
  That snapshot records configuration intent, not provider-confirmed grants;
  Pumble remains the final authorization boundary.

  ## Retry safety

  `retry_safety/1` declares, per operation, whether repeating a call can
  duplicate an effect. It is consumed by the node retry policy, and by the error
  classifier to decide what a `5xx` or a lost connection means.
  """

  alias PumbleAutomation.Installations.Credentials
  alias PumbleAutomation.Pumble.Blocks
  alias PumbleAutomation.Pumble.Client.Error
  alias PumbleAutomation.Pumble.Client.Transport
  alias PumbleAutomation.Pumble.Scopes

  # Pumble identifiers are opaque strings; every one observed is hexadecimal.
  # The check is deliberately wider than that and still narrow enough that no
  # identifier can carry a path separator, a query string, or a host into a URL.
  @id_pattern ~r/\A[A-Za-z0-9_-]{1,64}\z/

  # `CreateDirectChannelRequest` allows 1 to 8 participants — SDK source
  # `api/v1/types.ts`.
  @max_direct_participants 8

  @typedoc """
  Whether repeating an operation can duplicate an effect.

    * `:read_only` — it writes nothing.
    * `:idempotent_effect` — repeating it converges on the same end state. A
      reaction that is already present stays one reaction.
    * `:not_idempotent` — repeating it can produce a second effect. Pumble
      accepts no idempotency key on writes (`U-3`, `PR-09`), so a duplicated
      message cannot be prevented by the request.
  """
  @type retry_safety :: :read_only | :idempotent_effect | :not_idempotent

  @retry_safety %{
    get_profile: :read_only,
    get_workspace_info: :read_only,
    get_direct_channel: :read_only,
    add_reaction: :idempotent_effect,
    remove_reaction: :idempotent_effect,
    post_message: :not_idempotent,
    reply: :not_idempotent,
    send_direct_message: :not_idempotent,
    create_direct_channel: :not_idempotent,
    publish_home_view: :not_idempotent
  }

  @type t :: %__MODULE__{
          installation_id: Ecto.UUID.t(),
          credential_kind: Credentials.kind(),
          correlation_id: String.t() | nil
        }

  @enforce_keys [:installation_id, :credential_kind]
  defstruct [:installation_id, :credential_kind, :correlation_id]

  @doc """
  Builds a client bound to `installation_id`.

  `kind` chooses the credential: `:bot` by default, because the action contract
  makes the bot token the default author, or
  `{:user, pumble_user_id}` where the effect must be attributed to a person.

  `:correlation_id` travels into telemetry only. It is never sent to Pumble.
  """
  @spec new(Ecto.UUID.t(), Credentials.kind(), keyword()) :: t()
  def new(installation_id, kind \\ :bot, opts \\ []) when is_binary(installation_id) do
    %__MODULE__{
      installation_id: installation_id,
      credential_kind: kind,
      correlation_id: Keyword.get(opts, :correlation_id)
    }
  end

  @doc "Every operation this adapter exposes."
  @spec operations() :: [atom()]
  def operations, do: @retry_safety |> Map.keys() |> Enum.sort()

  @doc """
  Whether repeating `operation` can duplicate an effect.

  An unknown operation answers `:not_idempotent`, because the safe answer to
  "may I repeat this?" for something unrecognized is no.
  """
  @spec retry_safety(atom()) :: retry_safety()
  def retry_safety(operation), do: Map.get(@retry_safety, operation, :not_idempotent)

  @doc """
  Identifies the credential in use: `GET /oauth2/me` (`A-14`).

  The path is not under `/v1`; it is a sibling of `/oauth2/access` on the same
  base URL. `SUPPORTED` in the matrix.
  """
  @spec get_profile(t()) :: {:ok, map()} | {:error, Error.t()}
  def get_profile(%__MODULE__{} = client) do
    call(client, :get_profile, :get, "/oauth2/me")
  end

  @doc """
  Reads the workspace: `GET /v1/workspace` (`A-13`).

  The corpus name `getWorkspace()` is wrong; the operation is
  `getWorkspaceInfo()`. `SUPPORTED` in the matrix.
  """
  @spec get_workspace_info(t()) :: {:ok, map()} | {:error, Error.t()}
  def get_workspace_info(%__MODULE__{} = client) do
    call(client, :get_workspace_info, :get, "/v1/workspace")
  end

  @doc """
  Posts a message to a channel: `POST /v1/channels/{cId}/messages` (`A-1`).

  `content` is either text, which is validated and wrapped, or a body already
  built by `PumbleAutomation.Pumble.Blocks`. `SUPPORTED` in the matrix.
  """
  @spec post_message(t(), String.t(), String.t() | map()) :: {:ok, map()} | {:error, Error.t()}
  def post_message(%__MODULE__{} = client, channel_id, content) do
    with {:ok, channel_id} <- validate_id(channel_id, "channel id"),
         {:ok, body} <- to_message(content) do
      call(client, :post_message, :post, "/v1/channels/#{channel_id}/messages", body: body)
    end
  end

  @doc """
  Replies in a thread: `POST /v1/channels/{cId}/messages/{trId}` (`A-2`).

  The path is the fetch path with `POST`, which is the vendor client's only
  form for a reply. `SUPPORTED` in the matrix.
  """
  @spec reply(t(), String.t(), String.t(), String.t() | map()) ::
          {:ok, map()} | {:error, Error.t()}
  def reply(%__MODULE__{} = client, channel_id, thread_root_id, content) do
    with {:ok, channel_id} <- validate_id(channel_id, "channel id"),
         {:ok, thread_root_id} <- validate_id(thread_root_id, "thread root id"),
         {:ok, body} <- to_message(content) do
      call(client, :reply, :post, "/v1/channels/#{channel_id}/messages/#{thread_root_id}",
        body: body
      )
    end
  end

  @doc """
  Looks up a direct channel: `GET /v1/channels/direct` (`A-4`).

  `participantIds` carries the caller *and* the other participants, deduplicated
  and comma joined, exactly as the vendor client sends it. The caller is the
  credential's own workspace-user id.
  """
  @spec get_direct_channel(t(), [String.t()]) :: {:ok, map()} | {:error, Error.t()}
  def get_direct_channel(%__MODULE__{} = client, user_ids) do
    with {:ok, user_ids} <- validate_ids(user_ids) do
      call(client, :get_direct_channel, :get, "/v1/channels/direct",
        query: fn credential ->
          [participantIds: Enum.join(Enum.uniq([credential.actor_id | user_ids]), ",")]
        end
      )
    end
  end

  @doc """
  Creates a direct channel: `POST /v1/channels/direct` (`A-4`).

  The body carries the *other* participants only, which is the shape the vendor
  client sends: the caller is implied by the credential.
  """
  @spec create_direct_channel(t(), [String.t()]) :: {:ok, map()} | {:error, Error.t()}
  def create_direct_channel(%__MODULE__{} = client, user_ids) do
    with {:ok, user_ids} <- validate_ids(user_ids) do
      call(client, :create_direct_channel, :post, "/v1/channels/direct",
        body: %{"participantIds" => user_ids}
      )
    end
  end

  @doc """
  Direct-messages a user: lookup, then create if needed, then post (`A-4`).

  Three calls at most, in the vendor client's order. A lookup that answers
  "no such channel" is the ordinary first-contact case and leads to a create; a
  lookup that fails for any other reason is returned, because creating a channel
  after an authorization or transport failure would be a guess.
  """
  @spec send_direct_message(t(), String.t(), String.t() | map()) ::
          {:ok, map()} | {:error, Error.t()}
  def send_direct_message(%__MODULE__{} = client, user_id, content) do
    with {:ok, user_id} <- validate_id(user_id, "user id"),
         {:ok, body} <- to_message(content),
         {:ok, channel_id} <- resolve_direct_channel(client, user_id) do
      call(client, :send_direct_message, :post, "/v1/channels/#{channel_id}/messages", body: body)
    end
  end

  @doc """
  Adds a reaction: `POST /v1/messages/{mId}/reactions` (`A-5`).

  The reaction is the request body. `SUPPORTED` in the matrix.
  """
  @spec add_reaction(t(), String.t(), String.t(), integer() | nil) ::
          {:ok, map() | nil} | {:error, Error.t()}
  def add_reaction(%__MODULE__{} = client, message_id, code, skin_tone \\ nil) do
    with {:ok, message_id} <- validate_id(message_id, "message id"),
         {:ok, body} <- Blocks.reaction(code, skin_tone) do
      call(client, :add_reaction, :post, "/v1/messages/#{message_id}/reactions", body: body)
    end
  end

  @doc """
  Removes a reaction: `DELETE /v1/messages/{mId}/reactions` (`A-6`).

  The request carries a JSON body on a `DELETE`. That is confirmed in vendor
  source, which offers no query-parameter form; whether the server also accepts
  one is `PR-17` and is not assumed here.
  """
  @spec remove_reaction(t(), String.t(), String.t()) :: {:ok, map() | nil} | {:error, Error.t()}
  def remove_reaction(%__MODULE__{} = client, message_id, code) do
    with {:ok, message_id} <- validate_id(message_id, "message id"),
         {:ok, body} <- Blocks.reaction(code) do
      call(client, :remove_reaction, :delete, "/v1/messages/#{message_id}/reactions", body: body)
    end
  end

  @doc """
  Publishes the Home view: `POST /v1/app/homeView/workspaceUsers/{userId}`
  (`A-15`).

  The path and method are `SUPPORTED` in the matrix. Its *scope* is not: the
  closed scope catalog contains no home-view entry, so
  `PumbleAutomation.Pumble.Scopes` marks this operation unverified against
  `PR-07` and the gate never blocks it locally.
  """
  @spec publish_home_view(t(), String.t(), [map()]) :: {:ok, map() | nil} | {:error, Error.t()}
  def publish_home_view(%__MODULE__{} = client, workspace_user_id, blocks) do
    with {:ok, user_id} <- validate_id(workspace_user_id, "workspace user id"),
         {:ok, body} <- Blocks.home_view(blocks) do
      call(client, :publish_home_view, :post, "/v1/app/homeView/workspaceUsers/#{user_id}",
        body: body
      )
    end
  end

  # Lookup first, create on a miss. `A-4`'s response is `{channel: {id}}`.
  defp resolve_direct_channel(client, user_id) do
    case get_direct_channel(client, [user_id]) do
      {:ok, response} ->
        case channel_id(response) do
          nil -> create_direct_channel_id(client, user_id)
          id -> {:ok, id}
        end

      {:error, %Error{class: :not_found}} ->
        create_direct_channel_id(client, user_id)

      {:error, error} ->
        {:error, error}
    end
  end

  defp create_direct_channel_id(client, user_id) do
    with {:ok, response} <- create_direct_channel(client, [user_id]) do
      case channel_id(response) do
        nil ->
          {:error,
           Error.new(:remote_permanent,
             operation: :create_direct_channel,
             body_summary: "the direct channel response carried no channel id"
           )}

        id ->
          {:ok, id}
      end
    end
  end

  defp channel_id(%{"channel" => %{"id" => id}}) when is_binary(id) and id != "", do: id
  defp channel_id(_response), do: nil

  # The one path from an operation to the transport. Resolution and the scope
  # gate both run here, so neither can be skipped by adding an operation.
  defp call(client, operation, method, path, opts \\ []) do
    with {:ok, credential} <- resolve(client, operation),
         :ok <- Scopes.check(operation, credential.scopes) do
      Transport.execute(%{
        operation: operation,
        method: method,
        path: path,
        token: credential.token,
        workspace_id: credential.pumble_workspace_id,
        query: query(opts, credential),
        body: Keyword.get(opts, :body),
        correlation_id: client.correlation_id,
        idempotent_effect?: retry_safety(operation) != :not_idempotent,
        scope: Scopes.scope(operation)
      })
    end
  end

  defp query(opts, credential) do
    case Keyword.get(opts, :query) do
      nil -> []
      build when is_function(build, 1) -> build.(credential)
      query when is_list(query) -> query
    end
  end

  defp resolve(client, operation) do
    case Credentials.resolve(client.installation_id, client.credential_kind) do
      {:ok, credential} -> {:ok, credential}
      {:error, error} -> {:error, Error.from_credential_error(error, operation: operation)}
    end
  end

  defp to_message(content) when is_binary(content), do: Blocks.message(content)

  defp to_message(%{"text" => _text} = content) when is_map(content), do: {:ok, content}

  defp to_message(_content) do
    {:error, Error.new(:validation, body_summary: "a message is text or a body built by Blocks")}
  end

  defp validate_id(id, label) when is_binary(id) do
    if Regex.match?(@id_pattern, id) do
      {:ok, id}
    else
      {:error, Error.new(:validation, body_summary: "the #{label} is not a Pumble identifier")}
    end
  end

  defp validate_id(_id, label) do
    {:error, Error.new(:validation, body_summary: "the #{label} is missing")}
  end

  defp validate_ids(ids) when is_list(ids) and ids != [] do
    if length(ids) > @max_direct_participants do
      {:error,
       Error.new(:validation,
         body_summary: "a direct channel holds at most #{@max_direct_participants} participants"
       )}
    else
      ids
      |> Enum.reduce_while({:ok, []}, &validate_next_id/2)
      |> finish_ids()
    end
  end

  defp validate_ids(_ids) do
    {:error, Error.new(:validation, body_summary: "a direct channel needs a participant")}
  end

  defp validate_next_id(id, {:ok, acc}) do
    case validate_id(id, "user id") do
      {:ok, valid} -> {:cont, {:ok, [valid | acc]}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp finish_ids({:ok, reversed}), do: {:ok, Enum.reverse(reversed)}
  defp finish_ids({:error, error}), do: {:error, error}
end
