defmodule PumbleAutomation.Installations.OauthStates do
  @moduledoc """
  Creation, one-time consumption, and expiry of OAuth state.

  A state is the CSRF control on the consent round trip. `create/2` mints 256
  random bits, hands the token to the browser, and keeps only its SHA-256
  digest. `consume/1` takes the token back and either returns the row exactly
  once or fails. Nothing else may write `:consumed_at`.

  ## One statement, so there is one winner

  `consume/1` is a single `UPDATE ... WHERE state_digest = $1 AND consumed_at IS
  NULL AND expires_at > $2 ... RETURNING *`. The predicate and the write are the
  same statement, so there is no window between deciding a state is usable and
  making it unusable.

  Under two concurrent callbacks PostgreSQL serializes the row: the second
  statement waits for the first to commit, then re-evaluates its predicate
  against the committed row, sees `consumed_at` set, and matches nothing. Exactly
  one caller gets the row. A `SELECT` followed by an `UPDATE` would not have that
  property, and neither would a check performed in application code.

  ## Failing closed, and saying nothing

  Missing, expired, already consumed, and never-existed all return the same
  `:oauth_state_unusable` error. They are one answer on purpose: distinguishing
  them tells a caller whether a token ever existed, which is exactly the fact a
  guesser wants. The caller's job is to fail closed and offer a fresh flow.

  ## Intent is not a callback parameter

  The intent is chosen before the redirect and read back off the consumed row.
  `consume/1` deliberately takes no expected intent: the callback carries only
  `state` and `code`, so any intent it could supply would be a claim from the
  browser. What the flow is allowed to do comes from the row.
  """

  import Ecto.Query, only: [from: 2]

  alias PumbleAutomation.Error
  alias PumbleAutomation.Installations.OauthState
  alias PumbleAutomation.Installations.ReturnPaths
  alias PumbleAutomation.Repo

  @token_bytes 32

  # Long enough for a person to read a consent screen, short
  # enough that a token captured from a browser history is usually already dead.
  @ttl_seconds 600

  @doc """
  Creates one outstanding state and returns the token to send to the browser.

  The token is returned once, here, and is never recoverable from the database.

  Options:

    * `:installation_id` — the installation this flow expects to act on. A hint
      that the callback still verifies; `install` has none.
    * `:return_path_key` — a key from `PumbleAutomation.Installations.ReturnPaths`.
      Validated now rather than at redirect time, so an unknown key never
      becomes a stored row. Defaults to the table's default key.
    * `:request_metadata` — a map of non-identifying facts about the request.
    * `:now` — the reference time, for tests.

  ## Examples

      iex> {:ok, token, state} = PumbleAutomation.Installations.OauthStates.create("install")
      iex> state.intent
      "install"
      iex> PumbleAutomation.Installations.OauthState.digest(token) == state.state_digest
      true

  """
  @spec create(String.t(), keyword()) ::
          {:ok, String.t(), OauthState.t()} | {:error, Error.t()}
  def create(intent, opts \\ []) when is_binary(intent) do
    with :ok <- validate_intent(intent),
         {:ok, return_path_key} <- validate_return_path_key(opts) do
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
      token = Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)

      attrs = %{
        state_digest: OauthState.digest(token),
        intent: intent,
        installation_id: Keyword.get(opts, :installation_id),
        return_path_key: return_path_key,
        expires_at: DateTime.add(now, @ttl_seconds, :second),
        request_metadata: Keyword.get(opts, :request_metadata, %{})
      }

      %OauthState{}
      |> OauthState.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, state} -> {:ok, token, state}
        {:error, changeset} -> {:error, invalid_state(changeset)}
      end
    end
  end

  @doc """
  Consumes a state token, returning its row exactly once.

  Returns `{:error, error}` with code `:oauth_state_unusable` when the token is
  unknown, expired, or already consumed. The caller must not retry: a second
  attempt with the same token is precisely what this refuses.
  """
  @spec consume(term(), keyword()) :: {:ok, OauthState.t()} | {:error, Error.t()}
  def consume(token, opts \\ [])

  def consume(token, opts) when is_binary(token) and byte_size(token) > 0 do
    digest = OauthState.digest(token)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    query =
      from state in OauthState,
        where:
          state.state_digest == ^digest and is_nil(state.consumed_at) and
            state.expires_at > ^now,
        select: state

    case Repo.update_all(query, set: [consumed_at: now, updated_at: now]) do
      {1, [state]} -> confirm_digest(state, digest)
      {0, _rows} -> {:error, unusable()}
    end
  end

  def consume(_token, _opts), do: {:error, unusable()}

  @doc """
  Deletes states that expired before `:before`, and returns how many.

  Callable on its own so that a maintenance job can own the schedule without
  this module knowing one exists. Consumed rows are deleted by the same cutoff:
  a consumed state is inert, and keeping it adds nothing the audit trail does
  not already hold.

  Options:

    * `:before` — the cutoff. Defaults to now. A maintenance job that keeps a
      grace window passes an earlier time.
    * `:batch_size` — when set, one indexed `LIMIT`ed delete. The next call
      continues from whatever is left.
  """
  @spec delete_expired(keyword()) :: {:ok, non_neg_integer()}
  def delete_expired(opts \\ []) do
    before = Keyword.get_lazy(opts, :before, &DateTime.utc_now/0)
    scope = from(state in OauthState, where: state.expires_at < ^before)
    {:ok, delete_batch(OauthState, scope, Keyword.get(opts, :batch_size))}
  end

  @doc "Whether any OAuth state expired before `:before` (default now)."
  @spec expired?(keyword()) :: boolean()
  def expired?(opts \\ []) do
    before = Keyword.get_lazy(opts, :before, &DateTime.utc_now/0)
    Repo.exists?(from state in OauthState, where: state.expires_at < ^before)
  end

  @doc "How long a fresh state stays usable, in seconds."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  # The database already matched the digest, which is a comparison this code did
  # not perform and cannot make variable-time. This second comparison is the one
  # that happens in application code, and it is constant-time as the OAuth
  # security contract requires. A mismatch would mean the row returned is not the row
  # asked for, which is a defect rather than a user error.
  defp confirm_digest(%OauthState{} = state, digest) do
    if :crypto.hash_equals(state.state_digest, digest) do
      {:ok, state}
    else
      {:error,
       Error.new(:internal, :oauth_state_digest_mismatch,
         message: "The authorization could not be completed."
       )}
    end
  end

  defp validate_intent(intent) do
    if intent in OauthState.intents() do
      :ok
    else
      {:error,
       Error.new(:validation, :unknown_oauth_intent,
         message: "The requested authorization is not available.",
         details: %{intent: intent, known_intents: OauthState.intents()}
       )}
    end
  end

  defp validate_return_path_key(opts) do
    case Keyword.get(opts, :return_path_key) do
      nil -> {:ok, ReturnPaths.default_key()}
      key -> if ReturnPaths.known?(key), do: {:ok, key}, else: ReturnPaths.fetch(key)
    end
  end

  defp unusable do
    Error.new(:not_found, :oauth_state_unusable,
      message: "The authorization link is no longer valid. Start again."
    )
  end

  defp invalid_state(changeset) do
    Error.new(:validation, :invalid_oauth_state,
      message: "The authorization could not be started.",
      details: %{fields: Keyword.keys(changeset.errors)}
    )
  end

  defp delete_batch(_schema, scope, nil) do
    {count, _rows} = Repo.delete_all(scope)
    count
  end

  defp delete_batch(schema, scope, batch_size) when is_integer(batch_size) and batch_size > 0 do
    ids = from(row in scope, select: row.id, limit: ^batch_size)
    {count, _rows} = Repo.delete_all(from(row in schema, where: row.id in subquery(ids)))
    count
  end
end
