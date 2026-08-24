defmodule PumbleAutomation.Installations.Sessions do
  @moduledoc """
  Issue, resolve, rotate, and revoke browser sessions.

  Every browser request that carries the session cookie ends here, and every
  place that ends a session — sign-out, a role change, an unauthorized
  installation, an uninstall — ends it here too. Keeping both directions in one
  module is what makes "revoked means revoked everywhere" checkable by reading
  one file.

  ## The token is returned once

  `issue/3` and `rotate/3` return the plaintext token exactly once, in
  `:token`. Only its digest is stored (`PumbleAutomation.Installations.UserSession`),
  so a lost token cannot be recovered and must be replaced by a new session.

  ## Rotation is insert-then-revoke, never an update

  A rotated session is a new row; the old row is revoked in the same
  transaction. That keeps the old digest permanently unusable, which is the
  property session fixation needs: a token an attacker planted before sign-in
  stops working at sign-in rather than inheriting the new authority.

  ## Two expiries, one of which slides

  `touch/2` moves `:idle_expires_at` forward as the session is used, capped at
  `:absolute_expires_at`, so an active session survives and a forgotten one does
  not. The write is debounced by `touch_debounce_seconds/0` so a burst of
  requests does not become a burst of updates.
  """

  import Ecto.Query, only: [from: 2]

  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.UserSession
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.Repo

  @token_bytes 32

  # Plan Section 11.2 requires both limits and does not fix the numbers. Twelve
  # hours ends a session someone walked away from within a working day; seven
  # days ends one that has simply lived too long.
  @idle_seconds 12 * 60 * 60
  @absolute_seconds 7 * 24 * 60 * 60

  # A session is touched at most this often. Below it the row is left alone: the
  # idle window is twelve hours, so a minute of drift costs nothing and saves a
  # write on every request of a busy page.
  @touch_debounce_seconds 60

  # The statuses whose members may still hold a browser session. P13-T05 keeps
  # `revoked` usable on purpose: unauthorized already deletes the bot token and
  # revokes existing sessions, and an owner must be able to sign in again to see
  # that and reinstall. `uninstalled` and `deleted` do not, because there is
  # nothing left to administer.
  @usable_statuses ~w(active degraded revoked)

  @typedoc "A freshly issued session and the plaintext token, returned once."
  @type issued :: %{session: UserSession.t(), token: String.t()}

  @typedoc "A resolved session with the rows it authorizes against."
  @type resolved :: %{
          session: UserSession.t(),
          member: WorkspaceMember.t(),
          installation: Installation.t()
        }

  @doc "How long a session survives without use, in seconds."
  @spec idle_seconds() :: pos_integer()
  def idle_seconds, do: @idle_seconds

  @doc "How long a session survives however active it is, in seconds."
  @spec absolute_seconds() :: pos_integer()
  def absolute_seconds, do: @absolute_seconds

  @doc "The shortest interval between two `touch/2` writes, in seconds."
  @spec touch_debounce_seconds() :: pos_integer()
  def touch_debounce_seconds, do: @touch_debounce_seconds

  @doc """
  Inserts a session for `member` and returns it with its plaintext token.

  `repo` is explicit so this can run inside a caller's `Ecto.Multi`. Options are
  `:now` and `:user_agent_hash`.
  """
  @spec issue(Ecto.Repo.t(), WorkspaceMember.t(), keyword()) ::
          {:ok, issued()} | {:error, Ecto.Changeset.t()}
  def issue(repo, %WorkspaceMember{} = member, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    token = Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)

    attrs = %{
      workspace_member_id: member.id,
      token_digest: UserSession.digest(token),
      issued_at: now,
      last_used_at: now,
      idle_expires_at: DateTime.add(now, @idle_seconds, :second),
      absolute_expires_at: DateTime.add(now, @absolute_seconds, :second),
      user_agent_hash: Keyword.get(opts, :user_agent_hash)
    }

    case repo.insert(UserSession.changeset(%UserSession{}, attrs)) do
      {:ok, session} -> {:ok, %{session: session, token: token}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Replaces `session` with a new one for the same member.

  Rotate after sign-in, after a role change, and after a sensitive action. The
  old row is revoked in the same transaction as the new one is inserted, so
  there is no instant in which both digests work.
  """
  @spec rotate(Ecto.Repo.t(), UserSession.t(), keyword()) ::
          {:ok, issued()} | {:error, Ecto.Changeset.t() | :member_not_found}
  def rotate(repo, %UserSession{} = session, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    case repo.get(WorkspaceMember, session.workspace_member_id) do
      nil ->
        {:error, :member_not_found}

      %WorkspaceMember{} = member ->
        with {:ok, issued} <- issue(repo, member, opts) do
          _ = revoke(repo, session, now)
          {:ok, issued}
        end
    end
  end

  @doc """
  Resolves a plaintext token to the rows it authorizes against.

  Returns `:error` for an unknown, expired, revoked, disabled, or
  no-longer-installed session. The caller cannot tell those apart, which is
  deliberate: every one of them means "sign in again".
  """
  @spec fetch(String.t(), DateTime.t()) :: {:ok, resolved()} | :error
  def fetch(token, now) when is_binary(token) do
    digest = UserSession.digest(token)

    resolve(from(session in resolved_query(), where: session.token_digest == ^digest), now)
  end

  def fetch(_token, _now), do: :error

  @doc """
  Resolves a session by its row id.

  This is the LiveView path. A socket has no cookies, so `FetchSession` mirrors
  the id — never the token — into Phoenix's signed session, and the mount hook
  re-runs every check here against the database rather than trusting what it was
  handed.
  """
  @spec fetch_by_id(Ecto.UUID.t(), DateTime.t()) :: {:ok, resolved()} | :error
  def fetch_by_id(id, now) when is_binary(id) do
    if valid_uuid?(id) do
      resolve(from(session in resolved_query(), where: session.id == ^id), now)
    else
      :error
    end
  end

  def fetch_by_id(_id, _now), do: :error

  @doc """
  Moves the idle expiry forward, at most once per `touch_debounce_seconds/0`.

  Returns the session as it now stands, so a caller can keep using the struct
  whether or not a write happened.
  """
  @spec touch(UserSession.t(), DateTime.t()) :: UserSession.t()
  def touch(%UserSession{} = session, now) do
    if touch_due?(session, now) do
      idle = earliest(DateTime.add(now, @idle_seconds, :second), session.absolute_expires_at)

      {_count, _rows} =
        Repo.update_all(
          from(s in UserSession, where: s.id == ^session.id),
          set: [last_used_at: now, idle_expires_at: idle, updated_at: now]
        )

      %{session | last_used_at: now, idle_expires_at: idle}
    else
      session
    end
  end

  @doc "Revokes one session. Revoking an already revoked session changes nothing."
  @spec revoke(Ecto.Repo.t(), UserSession.t(), DateTime.t()) :: non_neg_integer()
  def revoke(repo, %UserSession{} = session, now) do
    {count, _rows} =
      repo.update_all(
        from(s in UserSession, where: s.id == ^session.id and is_nil(s.revoked_at)),
        set: [revoked_at: now, updated_at: now]
      )

    count
  end

  @doc "Revokes one session through the application Repo."
  @spec revoke(UserSession.t(), DateTime.t()) :: non_neg_integer()
  def revoke(%UserSession{} = session, now), do: revoke(Repo, session, now)

  @doc "Revokes every unrevoked session of one member and returns how many were revoked."
  @spec revoke_all_for_member(Ecto.Repo.t(), Ecto.UUID.t(), DateTime.t()) :: non_neg_integer()
  def revoke_all_for_member(repo, member_id, now) do
    {count, _rows} =
      repo.update_all(
        from(s in UserSession,
          where: s.workspace_member_id == ^member_id and is_nil(s.revoked_at)
        ),
        set: [revoked_at: now, updated_at: now]
      )

    count
  end

  @doc "Revokes every unrevoked session of one member through the application Repo."
  @spec revoke_all_for_member(Ecto.UUID.t(), DateTime.t()) :: non_neg_integer()
  def revoke_all_for_member(member_id, now), do: revoke_all_for_member(Repo, member_id, now)

  @doc """
  Revokes every unrevoked session of one installation.

  `user_sessions` carries no installation column, so the scope is the set of
  that installation's members. It is still one tenant and only one tenant.
  """
  @spec revoke_all_for_installation(Ecto.Repo.t(), Ecto.UUID.t(), DateTime.t()) ::
          non_neg_integer()
  def revoke_all_for_installation(repo, installation_id, now) do
    {count, _rows} =
      repo.update_all(
        from(s in UserSession,
          where: is_nil(s.revoked_at),
          where: s.workspace_member_id in subquery(member_ids(installation_id))
        ),
        set: [revoked_at: now, updated_at: now]
      )

    count
  end

  @doc "Revokes every unrevoked session of one installation through the application Repo."
  @spec revoke_all_for_installation(Ecto.UUID.t(), DateTime.t()) :: non_neg_integer()
  def revoke_all_for_installation(installation_id, now) do
    revoke_all_for_installation(Repo, installation_id, now)
  end

  @doc """
  Deletes revoked and expired sessions, optionally in one bounded batch.

  Options: `:now` (default utc now), `:batch_size` (omit to delete every match).
  """
  @spec delete_unusable(keyword()) :: {:ok, non_neg_integer()}
  def delete_unusable(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    scope =
      from session in UserSession,
        where:
          not is_nil(session.revoked_at) or session.idle_expires_at < ^now or
            session.absolute_expires_at < ^now

    {:ok, delete_batch(scope, Keyword.get(opts, :batch_size))}
  end

  @doc "Whether any revoked or expired session still exists as of `:now`."
  @spec unusable?(keyword()) :: boolean()
  def unusable?(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    Repo.exists?(
      from session in UserSession,
        where:
          not is_nil(session.revoked_at) or session.idle_expires_at < ^now or
            session.absolute_expires_at < ^now
    )
  end

  @doc "The query selecting the member ids of one installation."
  @spec member_ids(Ecto.UUID.t()) :: Ecto.Query.t()
  def member_ids(installation_id) do
    from member in WorkspaceMember,
      where: member.installation_id == ^installation_id,
      select: member.id
  end

  defp resolved_query do
    from session in UserSession,
      join: member in WorkspaceMember,
      on: member.id == session.workspace_member_id,
      join: installation in Installation,
      on: installation.id == member.installation_id,
      select: {session, member, installation}
  end

  defp resolve(query, now) do
    case Repo.one(query) do
      nil -> :error
      row -> check(row, now)
    end
  end

  defp valid_uuid?(id) do
    match?({:ok, _binary}, Ecto.UUID.dump(id))
  end

  defp check({session, member, installation}, now) do
    if UserSession.usable?(session, now) and is_nil(member.disabled_at) and
         installation.status in @usable_statuses do
      {:ok, %{session: session, member: member, installation: installation}}
    else
      :error
    end
  end

  defp touch_due?(%UserSession{last_used_at: nil}, _now), do: true

  defp touch_due?(%UserSession{last_used_at: last_used}, now) do
    DateTime.diff(now, last_used, :second) >= @touch_debounce_seconds
  end

  defp earliest(left, right) do
    if DateTime.compare(left, right) == :gt, do: right, else: left
  end

  defp delete_batch(scope, nil) do
    {count, _rows} = Repo.delete_all(scope)
    count
  end

  defp delete_batch(scope, batch_size) when is_integer(batch_size) and batch_size > 0 do
    ids = from(row in scope, select: row.id, limit: ^batch_size)
    {count, _rows} = Repo.delete_all(from(row in UserSession, where: row.id in subquery(ids)))
    count
  end
end
