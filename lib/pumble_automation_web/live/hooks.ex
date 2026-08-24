defmodule PumbleAutomationWeb.Live.Hooks do
  @moduledoc """
  The LiveView half of session handling.

  `on_mount(:require_scope, ...)` loads the same
  `PumbleAutomation.Scope` the HTTP plugs build, from the same rows, through the
  same checks. Attach it to every `live_session` that serves a protected
  LiveView:

      live_session :authenticated, on_mount: {PumbleAutomationWeb.Live.Hooks, :require_scope} do
        # protected LiveViews
      end

  `on_mount(:maybe_scope, ...)` is the public-page variant. A missing or unusable
  session continues without a scope so onboarding can show a recovery screen.
  It never treats "no session" as distinct from "expired session".

  ## Why the row is read again

  A socket has no cookies, so the session's row id travels in Phoenix's signed
  session. The id is not a credential and is not trusted as one: the hook loads
  the row and re-checks revocation, both expiries, the member, and the
  installation status. That is also what makes revocation reach a LiveView that
  is already open — the next mount, including the reconnect after a lost
  websocket, fails and the socket is redirected to sign-in.

  Mount runs twice, over HTTP and then over the websocket, and both runs go
  through this hook. There is no path on which a socket obtains a scope without
  a database read.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [redirect: 2]

  alias PumbleAutomation.Installations.Sessions
  alias PumbleAutomation.Scope
  alias PumbleAutomationWeb.BrowserSession

  @doc """
  Loads the tenant scope onto the socket.

  `:maybe_scope` continues as a public page when nobody is signed in.
  `:require_scope` redirects to sign-in instead. `{:halt, socket}` stops the
  LiveView from mounting, which is how an expired or revoked session terminates
  the socket rather than rendering a page it would then have to guard.
  """
  @spec on_mount(:maybe_scope | :require_scope, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:maybe_scope, _params, session, socket) do
    case resolve(session) do
      {:ok, resolved} -> {:cont, assign_resolved(socket, resolved)}
      :error -> {:cont, assign_public(socket)}
    end
  end

  def on_mount(:require_scope, _params, session, socket) do
    case resolve(session) do
      {:ok, resolved} -> {:cont, assign_resolved(socket, resolved)}
      :error -> {:halt, redirect(socket, to: BrowserSession.sign_in_path())}
    end
  end

  defp assign_resolved(socket, %{member: member, installation: installation}) do
    scope = Scope.new(member)

    assign(socket,
      scope: scope,
      current_scope: scope,
      current_member: member,
      current_installation: installation
    )
  end

  defp assign_public(socket) do
    assign(socket,
      scope: nil,
      current_scope: nil,
      current_member: nil,
      current_installation: nil
    )
  end

  defp resolve(session) when is_map(session) do
    case Map.get(session, BrowserSession.live_session_key()) do
      id when is_binary(id) -> load(id)
      _absent -> :error
    end
  end

  defp resolve(_session), do: :error

  defp load(id) do
    Sessions.fetch_by_id(id, DateTime.utc_now())
  end
end
