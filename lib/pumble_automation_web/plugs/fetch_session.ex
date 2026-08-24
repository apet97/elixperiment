defmodule PumbleAutomationWeb.Plugs.FetchSession do
  @moduledoc """
  Turns the session cookie into the rows it names, or into nothing at all.

  Reads the cookie, hashes it, and loads the session with its member and its
  installation in one query. A session that is expired, revoked, disabled, or
  no longer installed resolves to nothing and the cookie is cleared, so the
  browser stops presenting a credential that will never work again.

  This plug never halts. Deciding what an absent member means belongs to
  `PumbleAutomationWeb.Plugs.RequireMember`, because a public page and a
  protected page want different answers to the same absence.

  Assigns `:current_session`, `:current_member`, and `:current_installation`,
  each `nil` when there is no usable session, and mirrors the session's row id
  into the Phoenix session for
  `PumbleAutomationWeb.Live.Hooks`. The token itself never goes there.
  """

  @behaviour Plug

  import Plug.Conn

  alias PumbleAutomation.Installations.Sessions
  alias PumbleAutomationWeb.BrowserSession

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = fetch_cookies(conn)

    case Map.get(conn.cookies, BrowserSession.cookie()) do
      token when is_binary(token) -> resolve(conn, token)
      _absent -> absent(conn)
    end
  end

  defp resolve(conn, token) do
    now = DateTime.utc_now()

    case Sessions.fetch(token, now) do
      {:ok, resolved} -> present(conn, Sessions.touch(resolved.session, now), resolved)
      :error -> conn |> BrowserSession.delete() |> absent()
    end
  end

  defp present(conn, session, resolved) do
    conn
    |> assign(:current_session, session)
    |> assign(:current_member, resolved.member)
    |> assign(:current_installation, resolved.installation)
    |> put_session(BrowserSession.live_session_key(), session.id)
  end

  defp absent(conn) do
    conn
    |> assign(:current_session, nil)
    |> assign(:current_member, nil)
    |> assign(:current_installation, nil)
  end
end
