defmodule PumbleAutomation.Installations.Service do
  @moduledoc """
  Turns a completed OAuth exchange into a tenant, a member, and a session.

  `complete_oauth/3` is plan Section 13's install list as one transaction: upsert
  the installation by Pumble workspace id, store the credentials encrypted, snapshot
  the scopes, upsert the member, assign the first owner when there is none, create the
  browser session, and append the audit event. Either all of that happens or none of it
  does. A partial installation — a tenant with no member, a member with no session, a
  credential swap with no audit row — is the failure mode this shape exists to make
  impossible.

  ## The workspace comes from Pumble, never from the browser

  Every row is keyed on `tokens.pumble_workspace_id`, which came out of the token
  exchange. The state's `:installation_id` is only a hint, and when it disagrees with
  the workspace Pumble named, the flow fails rather than picking one. That check is
  what stops a sign-in link for workspace A from being completed against workspace B.

  ## Intents do different things, and the difference is the point

      intent        credentials   first owner   session
      install       replaced      yes           yes
      reinstall     replaced      yes           yes
      signin        untouched     no            yes
      connect_user  untouched     no            no

  `signin` never grants owner: a sign-in is someone arriving, not someone installing,
  and a workspace whose owner left must recover through an explicit path rather than
  through whoever signs in next. `signin` and `connect_user` also leave the bot
  credentials alone; only an install or a reinstall replaces them. Sign-in on a
  revoked installation is allowed so an owner can open onboarding and reinstall
  (P13-T05). Sign-in on an uninstalled or deleted installation is refused.

  `install` and `reinstall` require a bot token. A grant that carried none cannot run a
  workflow, so it fails here rather than producing a tenant that looks installed and
  is not.

  ## Concurrency

  The transaction takes a PostgreSQL advisory lock keyed on the workspace id before it
  reads anything. Two callbacks racing for the same new workspace therefore run one
  after the other, and the second sees the first's committed rows: one installation,
  one owner. The lock is transaction-scoped, so it is released by commit or rollback
  and never needs unlocking by hand.

  ## Scopes are what we asked for, not what we were told

  The exchange response carries no scope list (`A-16`). The snapshot written here is the
  set this application requested at exchange time, which is the only scope fact that
  exists at this point. Reinstall scope revalidation is deliberately not done here; see
  plan Section 13 and the `PR-07` caveat in the evidence matrix.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias PumbleAutomation.Audit.Writer
  alias PumbleAutomation.Error
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Lifecycle
  alias PumbleAutomation.Installations.OauthState
  alias PumbleAutomation.Installations.Sessions
  alias PumbleAutomation.Installations.UserAuthorization
  alias PumbleAutomation.Installations.UserSession
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.Pumble.OauthClient
  alias PumbleAutomation.Repo

  @intents_replacing_credentials ~w(install reinstall)
  @intents_creating_session ~w(install reinstall signin)

  @typedoc """
  What a completed flow produced.

  `:session_token` is the plaintext session token, returned exactly once because
  only its digest is stored. It is `nil` for `connect_user`, which creates no
  session.
  """
  @type result :: %{
          installation: Installation.t(),
          member: WorkspaceMember.t(),
          authorization: UserAuthorization.t(),
          session: UserSession.t() | nil,
          session_token: String.t() | nil,
          intent: String.t(),
          correlation_id: String.t()
        }

  @doc """
  Completes an OAuth flow in one transaction.

  `state` is a row already consumed by `PumbleAutomation.Installations.OauthStates.consume/1`;
  it supplies the intent and the installation hint. `tokens` is the result of
  `PumbleAutomation.Pumble.OauthClient.exchange_code/1`.

  Options:

    * `:correlation_id` — stitches the audit event to the request. Generated when absent.
    * `:user_agent_hash` — a 32 byte digest stored with the session, never a user agent.
    * `:now` — the reference time, for tests.

  Every failure rolls the whole transaction back, so `{:error, error}` always means no
  row was written.
  """
  @spec complete_oauth(OauthState.t(), OauthClient.tokens(), keyword()) ::
          {:ok, result()} | {:error, Error.t()}
  def complete_oauth(%OauthState{} = state, tokens, opts \\ []) when is_map(tokens) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    correlation_id = Keyword.get_lazy(opts, :correlation_id, &Ecto.UUID.generate/0)

    state
    |> build_multi(tokens, now, correlation_id, opts)
    |> Repo.transaction()
    |> case do
      {:ok, changes} -> {:ok, build_result(changes, state, correlation_id)}
      {:error, step, reason, _changes} -> {:error, to_error(step, reason)}
    end
  end

  @doc """
  Returns its argument, typed as an `Ecto.Multi`.

  This exists for Dialyzer, and only for Dialyzer.

  `Ecto.Multi` keeps its step names in a `MapSet`, whose type is opaque. The
  struct `Ecto.Multi.new/0` returns is a literal, so Dialyzer knows what is
  inside that `MapSet` and reports every `Multi.new() |> Multi.run(...)` chain
  as an opacity violation — in any module, for any callback, including a bare
  three-line example. The finding is a property of the library's type, not of
  this code.

  This repository does not keep a Dialyzer ignore file, so the fix is a real one:
  passing the multi through an exported function whose spec names the return type
  restores the opacity, because the caller then sees the declared type instead of
  the literal. It must be exported — Dialyzer inlines private functions and sees
  through them — which is why a helper this small is public rather than a `defp`.

  Remove it if a future Ecto stops leaking the `MapSet`; the tests will not
  notice either way.
  """
  @spec as_multi(Multi.t()) :: Multi.t()
  def as_multi(multi), do: multi

  @doc """
  Loads the tenant for a Pumble workspace id, regardless of status.

  Lifecycle callbacks must reach revoked and uninstalled rows so a duplicate
  or out-of-order event can converge. Returns `:error` when the workspace is
  unknown; the caller must not create a tenant from that miss.
  """
  @spec fetch_by_workspace_id(String.t()) :: {:ok, Installation.t()} | :error
  def fetch_by_workspace_id(workspace_id) when is_binary(workspace_id) do
    case Repo.get_by(Installation, pumble_workspace_id: workspace_id) do
      %Installation{} = installation -> {:ok, installation}
      nil -> :error
    end
  end

  @doc """
  Applies one signed Pumble lifecycle callback to an existing tenant.

  `opts` must include `source: "pumble_callback"`. Generic webhook and browser
  routes have no such source and are refused without writing. Unknown types
  are refused the same way: they are not uninstall or unauthorized transitions.
  """
  @spec apply_lifecycle(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, Installation.t()} | {:error, Error.t()}
  def apply_lifecycle(installation_id, type, opts \\ [])
      when is_binary(installation_id) and is_binary(type) do
    with :ok <- require_pumble_callback_source(opts) do
      transition_lifecycle(installation_id, type, opts)
    end
  end

  # The steps, in the order their dependencies require: the lock before any read,
  # the installation before anything that points at it, and the audit row last so
  # that it can name what the earlier steps produced.
  @spec build_multi(OauthState.t(), OauthClient.tokens(), DateTime.t(), String.t(), keyword()) ::
          Multi.t()
  defp build_multi(%OauthState{} = state, tokens, now, correlation_id, opts) do
    Multi.new()
    |> as_multi()
    |> Multi.run(:lock, fn repo, _changes -> lock_workspace(repo, tokens) end)
    |> Multi.run(:stale_sessions, fn repo, _changes ->
      revoke_stale_sessions(repo, state, tokens, now)
    end)
    |> Multi.run(:installation, fn repo, _changes ->
      resolve_installation(repo, state, tokens, now)
    end)
    |> Multi.run(:authorization, fn repo, changes ->
      upsert_authorization(repo, changes.installation, tokens, now)
    end)
    |> Multi.run(:member, fn repo, changes ->
      upsert_member(repo, changes.installation, tokens, state.intent, now)
    end)
    |> Multi.run(:session, fn repo, changes ->
      create_session(repo, changes.member, state.intent, now, opts)
    end)
    |> Writer.append(:audit, fn changes ->
      audit_attrs(changes, state, tokens, correlation_id)
    end)
  end

  @doc "How long a new session survives without use, in seconds."
  @spec session_idle_seconds() :: pos_integer()
  defdelegate session_idle_seconds, to: Sessions, as: :idle_seconds

  @doc "How long a new session survives however active it is, in seconds."
  @spec session_absolute_seconds() :: pos_integer()
  defdelegate session_absolute_seconds, to: Sessions, as: :absolute_seconds

  # A reinstall by a different person is a change of who authorized this
  # workspace. Plan Section 11.2 rotates a session on a change of authority, and
  # this is the largest one there is: the sessions that exist were issued under
  # the previous installer's grant, so they end here, before the new grant is
  # written. The session this flow is about to create is inserted later and is
  # therefore untouched.
  defp revoke_stale_sessions(repo, %OauthState{intent: intent}, tokens, now)
       when intent in @intents_replacing_credentials do
    installation = repo.get_by(Installation, pumble_workspace_id: tokens.pumble_workspace_id)

    if installer_changed?(installation, tokens.pumble_user_id) do
      {:ok, Sessions.revoke_all_for_installation(repo, installation.id, now)}
    else
      {:ok, 0}
    end
  end

  defp revoke_stale_sessions(_repo, _state, _tokens, _now), do: {:ok, 0}

  defp installer_changed?(%Installation{installed_by_pumble_user_id: previous}, current)
       when is_binary(previous),
       do: previous != current

  defp installer_changed?(_installation, _current), do: false

  # Serializes everything that follows for this workspace. `phash2` rather than
  # PostgreSQL's undocumented `hashtext`, so the key is computed by code this
  # repository owns and cannot change under a server upgrade. A collision costs
  # two unrelated workspaces a moment of waiting and nothing else.
  defp lock_workspace(repo, tokens) do
    key = :erlang.phash2(tokens.pumble_workspace_id)
    %Postgrex.Result{} = repo.query!("SELECT pg_advisory_xact_lock($1::bigint)", [key])
    {:ok, key}
  end

  defp resolve_installation(repo, %OauthState{intent: intent} = state, tokens, now) do
    existing = repo.get_by(Installation, pumble_workspace_id: tokens.pumble_workspace_id)

    with :ok <- check_hint(state, existing),
         :ok <- check_existing_required(intent, existing),
         :ok <- check_browser_status(intent, existing),
         :ok <- check_bot_token(intent, tokens) do
      write_installation(repo, intent, existing, tokens, now)
    end
  end

  # The state named an installation, so the workspace Pumble just named must be
  # that same installation. This is the cross-workspace check: a sign-in link
  # minted for one workspace cannot be completed against another.
  defp check_hint(%OauthState{installation_id: nil}, _existing), do: :ok

  defp check_hint(%OauthState{installation_id: hint}, %Installation{id: hint}), do: :ok

  defp check_hint(%OauthState{}, _existing) do
    {:error,
     Error.new(:conflict, :oauth_workspace_mismatch,
       message: "The authorization was completed for a different workspace."
     )}
  end

  defp check_existing_required("install", _existing), do: :ok

  defp check_existing_required(_intent, %Installation{}), do: :ok

  defp check_existing_required(_intent, nil) do
    {:error,
     Error.new(:not_found, :installation_not_found,
       message: "This workspace has not installed the application."
     )}
  end

  # Sign-in and connect_user prove identity against an existing tenant. A
  # revoked installation still needs that path so an owner can open onboarding
  # and reinstall (P13-T05). Uninstalled and deleted tenants have nothing left
  # to administer; recovery is `reinstall` / `install`.
  defp check_browser_status(intent, %Installation{status: status})
       when intent in ~w(signin connect_user) and status in ~w(uninstalled deleted) do
    {:error,
     Error.new(:permission, :installation_unusable,
       message: "This workspace is no longer installed. Reinstall to continue."
     )}
  end

  defp check_browser_status(_intent, _existing), do: :ok

  defp check_bot_token(intent, tokens) when intent in @intents_replacing_credentials do
    if is_binary(tokens.bot_token) do
      :ok
    else
      {:error,
       Error.new(:validation, :bot_token_missing,
         message: "Pumble did not return the bot token required for installation."
       )}
    end
  end

  defp check_bot_token(_intent, _tokens), do: :ok

  # `signin` and `connect_user` reach an installation they must not modify.
  defp write_installation(_repo, intent, %Installation{} = existing, _tokens, _now)
       when intent not in @intents_replacing_credentials do
    {:ok, existing}
  end

  defp write_installation(repo, _intent, existing, tokens, now) do
    attrs = %{
      status: "active",
      bot_user_id: tokens.bot_user_id,
      encrypted_bot_token: tokens.bot_token,
      token_key_version: key_version(),
      bot_scopes: requested_scopes(:bot_scopes),
      user_scopes: requested_scopes(:user_scopes),
      installed_by_pumble_user_id: tokens.pumble_user_id,
      authorized_at: now,
      revoked_at: nil
    }

    case existing do
      nil ->
        attrs = Map.put(attrs, :pumble_workspace_id, tokens.pumble_workspace_id)
        repo.insert(Installation.changeset(%Installation{}, attrs))

      %Installation{} = installation ->
        repo.update(Installation.changeset(installation, attrs))
    end
  end

  defp upsert_authorization(repo, installation, tokens, now) do
    attrs = %{
      installation_id: installation.id,
      pumble_user_id: tokens.pumble_user_id,
      encrypted_access_token: tokens.access_token,
      token_key_version: key_version(),
      scopes: requested_scopes(:user_scopes),
      status: "active",
      authorized_at: now,
      revoked_at: nil
    }

    existing =
      repo.get_by(UserAuthorization,
        installation_id: installation.id,
        pumble_user_id: tokens.pumble_user_id
      )

    case existing do
      nil -> repo.insert(UserAuthorization.changeset(%UserAuthorization{}, attrs))
      authorization -> repo.update(UserAuthorization.changeset(authorization, attrs))
    end
  end

  defp upsert_member(repo, installation, tokens, intent, _now) do
    existing =
      repo.get_by(WorkspaceMember,
        installation_id: installation.id,
        pumble_user_id: tokens.pumble_user_id
      )

    attrs = %{
      installation_id: installation.id,
      pumble_user_id: tokens.pumble_user_id,
      role: resolve_role(repo, installation, existing, intent)
    }

    case existing do
      nil -> repo.insert(WorkspaceMember.changeset(%WorkspaceMember{}, attrs))
      member -> repo.update(WorkspaceMember.changeset(member, attrs))
    end
  end

  # Owner is granted only by an install or a reinstall, and only while the
  # installation has no owner at all. The advisory lock makes the "no owner"
  # read and the write that follows it one decision, so two racing installers
  # cannot both see an ownerless installation.
  #
  # An existing member keeps the role it has: an OAuth round trip is not a way to
  # change someone's authority, and this clause never demotes.
  defp resolve_role(repo, installation, existing, intent) do
    cond do
      intent in @intents_replacing_credentials and not owner_exists?(repo, installation) ->
        "owner"

      is_nil(existing) ->
        "viewer"

      true ->
        existing.role
    end
  end

  defp owner_exists?(repo, %Installation{id: installation_id}) do
    repo.exists?(
      from member in WorkspaceMember,
        where:
          member.installation_id == ^installation_id and member.role == "owner" and
            is_nil(member.disabled_at)
    )
  end

  defp create_session(_repo, _member, intent, _now, _opts)
       when intent not in @intents_creating_session do
    {:ok, %{session: nil, token: nil}}
  end

  defp create_session(repo, member, _intent, now, opts) do
    Sessions.issue(repo, member,
      now: now,
      user_agent_hash: Keyword.get(opts, :user_agent_hash)
    )
  end

  # Identifiers go in the actor and resource columns, which exist for them.
  # `:metadata` is an allowlist of non-identifying scalars, so the workspace id
  # and the intent do not belong there; the intent is carried by the action.
  defp audit_attrs(changes, %OauthState{intent: intent}, tokens, correlation_id) do
    %{
      installation_id: changes.installation.id,
      actor_type: "pumble_user",
      actor_id: tokens.pumble_user_id,
      action: "oauth." <> intent <> "_completed",
      resource_type: "installation",
      resource_id: changes.installation.id,
      correlation_id: correlation_id,
      metadata: %{
        result: "ok",
        source: "oauth_callback",
        actor_role: changes.member.role
      }
    }
  end

  defp build_result(changes, %OauthState{intent: intent}, correlation_id) do
    %{
      installation: changes.installation,
      member: changes.member,
      authorization: changes.authorization,
      session: changes.session.session,
      session_token: changes.session.token,
      intent: intent,
      correlation_id: correlation_id
    }
  end

  defp key_version do
    :pumble_automation
    |> Application.fetch_env!(:encryption)
    |> Keyword.fetch!(:key_version)
  end

  defp requested_scopes(key) do
    :pumble_automation
    |> Application.fetch_env!(:pumble)
    |> Keyword.get(key, [])
  end

  defp require_pumble_callback_source(opts) do
    case Keyword.get(opts, :source) do
      "pumble_callback" ->
        :ok

      _other ->
        {:error,
         Error.new(:permission, :lifecycle_source_refused,
           message: "Lifecycle transitions are accepted only from signed Pumble callbacks."
         )}
    end
  end

  defp transition_lifecycle(installation_id, "APP_UNINSTALLED", opts) do
    Lifecycle.uninstall(installation_id, opts)
  end

  defp transition_lifecycle(installation_id, "APP_UNAUTHORIZED", opts) do
    Lifecycle.mark_unauthorized(installation_id, opts)
  end

  defp transition_lifecycle(_installation_id, _type, _opts) do
    {:error,
     Error.new(:validation, :unsupported_lifecycle,
       message: "That callback is not a lifecycle transition."
     )}
  end

  defp to_error(_step, %Error{} = error), do: error

  defp to_error(step, %Ecto.Changeset{} = changeset) do
    Error.new(:validation, :installation_write_rejected,
      message: "The installation could not be completed.",
      details: %{step: step, fields: Keyword.keys(changeset.errors)}
    )
  end

  defp to_error(step, reason) do
    Error.new(:internal, :installation_write_failed,
      message: "The installation could not be completed.",
      details: %{step: step},
      cause: reason
    )
  end
end
