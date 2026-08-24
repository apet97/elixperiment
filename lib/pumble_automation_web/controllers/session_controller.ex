defmodule PumbleAutomationWeb.SessionController do
  @moduledoc """
  Ending sessions. There is no action here that starts one.

  A session begins at the end of the OAuth round trip, in
  `PumbleAutomationWeb.OauthController`, because that is the only place that has
  proof of who is arriving. This controller only ever takes authority away, which
  is why every action is a `DELETE` behind the browser pipeline's
  `protect_from_forgery`: a cross-site page must not be able to sign someone out,
  and much less revoke a whole workspace's sessions.

  `delete/2` ends this browser's session. `delete_all/2` ends every session of
  the person asking — the "sign out everywhere" a stolen laptop needs — and, for
  an owner, every session in the installation.
  """

  use PumbleAutomationWeb, :controller

  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Installations.Sessions
  alias PumbleAutomationWeb.BrowserSession

  @doc "Revokes the session this request carried and clears the cookie."
  def delete(conn, _params) do
    _revoked = Sessions.revoke(conn.assigns.current_session, DateTime.utc_now())

    conn
    |> BrowserSession.delete()
    |> redirect(to: BrowserSession.sign_in_path())
  end

  @doc """
  Revokes every session of the current member.

  With `scope=installation` an owner revokes every session in the installation.
  Anyone else asking for that gets their own sessions revoked instead of an
  error: they asked to be signed out, and they are.
  """
  def delete_all(conn, params) do
    scope = conn.assigns.scope
    now = DateTime.utc_now()

    if params["scope"] == "installation" and Policy.can?(scope, :manage_members) do
      Sessions.revoke_all_for_installation(scope.installation_id, now)
    else
      Sessions.revoke_all_for_member(scope.member_id, now)
    end

    conn
    |> BrowserSession.delete()
    |> redirect(to: BrowserSession.sign_in_path())
  end
end
