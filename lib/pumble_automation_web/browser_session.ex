defmodule PumbleAutomationWeb.BrowserSession do
  @moduledoc """
  The cookie the browser session lives in, and the two places it is written.

  Every attribute is set here and nowhere else, so "is the session cookie
  `Secure`" is one line to read and one test to write rather than a property of
  whichever controller happened to set it last.

  ## The attributes, and why each one

    * `http_only` — script cannot read it, so an injected script cannot exfiltrate
      the session. This is also why the token is never put in `localStorage`.
    * `secure` — it is not sent over plain HTTP, ever.
    * `same_site: "Lax"` — it still arrives on the top-level navigation the OAuth
      redirect is, and does not ride a cross-site subrequest.
    * `path: "/"` — one session for the whole application.
    * `max_age` — an explicit lifetime that matches the row's absolute expiry, so
      a browser stops sending a cookie the database would refuse anyway.

  The token is never placed in a URL, a form field, a header of our own, or the
  Phoenix session. `live_session_key/0` holds the session's **row id**, which is
  what a LiveView mount re-reads the database with; the id authorizes nothing on
  its own, and the hook checks expiry, revocation, and membership again.
  """

  use PumbleAutomationWeb, :verified_routes

  import Plug.Conn

  alias PumbleAutomation.Installations.Sessions

  @cookie "pa_session"
  @live_session_key "browser_session_id"

  @doc "The name of the cookie that carries the browser session token."
  @spec cookie() :: String.t()
  def cookie, do: @cookie

  @doc "The Phoenix session key holding the browser session's row id."
  @spec live_session_key() :: String.t()
  def live_session_key, do: @live_session_key

  @doc "The cookie attributes, exposed so a test can hold the writer to them."
  @spec cookie_options() :: keyword()
  def cookie_options do
    [
      http_only: true,
      secure: true,
      same_site: "Lax",
      path: "/",
      max_age: Sessions.absolute_seconds()
    ]
  end

  @doc """
  Writes the session token to the cookie and renews the Phoenix session.

  `configure_session(renew: true)` followed by `clear_session/1` gives the Phoenix
  session a new identifier and empties what the previous one held, so nothing
  planted before sign-in survives it. The browser session token beside it is new
  by construction: it is a fresh row, never an update of the previous one.
  """
  @spec put(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put(conn, token) when is_binary(token) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_resp_cookie(@cookie, token, cookie_options())
  end

  @doc "Removes the cookie and drops the Phoenix session with it."
  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn) do
    conn
    |> delete_resp_cookie(@cookie, Keyword.take(cookie_options(), [:path, :secure, :same_site]))
    |> configure_session(drop: true)
  end

  @doc """
  Where a browser without a usable session is sent.

  The sign-in intent, not the install intent: someone arriving at a protected
  page has an installation already, and `signin` never grants ownership.
  """
  @spec sign_in_path() :: String.t()
  def sign_in_path, do: ~p"/oauth/install?intent=signin"
end
