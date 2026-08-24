defmodule PumbleAutomationWeb.Plugs.BrowserSessionTest do
  @moduledoc """
  The three session plugs, and the cookie they read.

  The plugs are exercised directly rather than through a route, because what is
  being checked is the pipeline's contract — resolve, then halt, then scope — and
  a route would only prove that one path happens to be wired correctly.

  Every "no session" case asserts the same observable result. That is the point:
  an absent cookie, an expired session, a revoked one, a disabled member, and an
  uninstalled workspace must be indistinguishable to whoever is asking.
  """

  use PumbleAutomation.DataCase, async: true

  import Plug.Test, only: [init_test_session: 2]

  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Sessions
  alias PumbleAutomation.Installations.UserSession
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Scope
  alias PumbleAutomationWeb.BrowserSession
  alias PumbleAutomationWeb.Plugs.FetchSession
  alias PumbleAutomationWeb.Plugs.LoadScope
  alias PumbleAutomationWeb.Plugs.RequireMember

  describe "the session cookie" do
    test "is Secure, HttpOnly, SameSite=Lax, path / and has an explicit max age" do
      conn = BrowserSession.put(signed_in_conn(), "a-token")

      assert %{
               value: "a-token",
               http_only: true,
               secure: true,
               same_site: "Lax",
               path: "/",
               max_age: max_age
             } = conn.resp_cookies[BrowserSession.cookie()]

      assert max_age == Sessions.absolute_seconds()
    end

    test "sign-in renews the Phoenix session, so a fixed one does not survive it" do
      conn =
        signed_in_conn()
        |> Plug.Conn.put_session("planted", "value")
        |> BrowserSession.put("a-token")

      assert Plug.Conn.get_session(conn, "planted") == nil
      assert conn.private.plug_session_info == :renew
    end

    test "deleting it clears the cookie and drops the Phoenix session" do
      conn = BrowserSession.delete(signed_in_conn())

      assert %{max_age: 0, path: "/"} = conn.resp_cookies[BrowserSession.cookie()]
      assert conn.private.plug_session_info == :drop
    end
  end

  describe "FetchSession" do
    test "resolves a usable token to its session, member, and installation" do
      %{session_token: token, member: member, installation: installation} = install()

      conn = fetch(token)

      assert conn.assigns.current_member.id == member.id
      assert conn.assigns.current_installation.id == installation.id
      assert conn.assigns.current_session.id
      refute conn.halted
    end

    test "mirrors the session's row id — never the token — into the Phoenix session" do
      %{session_token: token, session: session} = install()

      conn = fetch(token)

      assert Plug.Conn.get_session(conn, BrowserSession.live_session_key()) == session.id
      refute token in Map.values(Plug.Conn.get_session(conn))
    end

    test "an absent cookie resolves to nobody, without halting" do
      conn = FetchSession.call(signed_in_conn(), [])

      assert conn.assigns.current_member == nil
      assert conn.assigns.current_session == nil
      refute conn.halted
    end

    test "an unknown token resolves to nobody" do
      assert fetch("not-a-token").assigns.current_member == nil
    end

    test "an idle-expired session resolves to nobody and the cookie is cleared" do
      %{session_token: token, session: session} = install()
      expire(session, :idle_expires_at)

      conn = fetch(token)

      assert conn.assigns.current_member == nil
      assert %{max_age: 0} = conn.resp_cookies[BrowserSession.cookie()]
    end

    test "an absolutely expired session resolves to nobody" do
      %{session_token: token, session: session} = install()
      expire(session, :absolute_expires_at)

      assert fetch(token).assigns.current_member == nil
    end

    test "a revoked session resolves to nobody" do
      %{session_token: token, session: session} = install()
      Sessions.revoke(Repo, session, DateTime.utc_now())

      assert fetch(token).assigns.current_member == nil
    end

    test "a disabled member resolves to nobody" do
      %{session_token: token, member: member} = install()

      Repo.update_all(from(m in WorkspaceMember, where: m.id == ^member.id),
        set: [disabled_at: DateTime.utc_now()]
      )

      assert fetch(token).assigns.current_member == nil
    end

    test "an uninstalled workspace resolves to nobody" do
      %{session_token: token, installation: installation} = install()

      installation
      |> Installation.changeset(%{status: "uninstalled", uninstalled_at: DateTime.utc_now()})
      |> Repo.update!()

      assert fetch(token).assigns.current_member == nil
    end

    test "a revoked installation still resolves so the owner can reinstall" do
      %{session_token: token, installation: installation} = install()

      installation
      |> Installation.changeset(%{
        status: "revoked",
        revoked_at: DateTime.utc_now(),
        encrypted_bot_token: nil,
        token_key_version: nil
      })
      |> Repo.update!()

      conn = fetch(token)

      assert conn.assigns.current_member
      assert conn.assigns.current_installation.status == "revoked"
      refute conn.halted
    end

    test "moves the idle expiry forward when the session was last used long ago" do
      %{session_token: token, session: session} = install()
      stale = DateTime.add(DateTime.utc_now(), -Sessions.touch_debounce_seconds() - 60, :second)
      set_last_used(session, stale)

      conn = fetch(token)

      touched = Repo.get!(UserSession, session.id)
      assert DateTime.compare(touched.last_used_at, stale) == :gt
      assert DateTime.compare(touched.idle_expires_at, session.idle_expires_at) == :gt
      assert conn.assigns.current_session.last_used_at == touched.last_used_at
    end

    test "does not write on every request: the touch is debounced" do
      %{session_token: token, session: session} = install()

      _conn = fetch(token)

      untouched = Repo.get!(UserSession, session.id)
      assert untouched.last_used_at == session.last_used_at
    end
  end

  describe "RequireMember" do
    test "lets a request with a member through" do
      %{session_token: token} = install()

      conn = token |> fetch() |> RequireMember.call([])

      refute conn.halted
    end

    test "halts a request without one, redirecting to sign-in" do
      conn = signed_in_conn() |> FetchSession.call([]) |> RequireMember.call([])

      assert conn.halted
      assert conn.status == 302
      assert Plug.Conn.get_resp_header(conn, "location") == [BrowserSession.sign_in_path()]
    end

    test "an expired session is halted exactly like an absent one" do
      %{session_token: token, session: session} = install()
      expire(session, :idle_expires_at)

      conn = token |> fetch() |> RequireMember.call([])

      assert conn.halted
      assert conn.status == 302
      assert Plug.Conn.get_resp_header(conn, "location") == [BrowserSession.sign_in_path()]
    end
  end

  describe "LoadScope" do
    test "builds the scope from the resolved member" do
      %{session_token: token, member: member, installation: installation} =
        install(role: "editor")

      conn = token |> fetch() |> LoadScope.call([])

      assert %Scope{} = scope = conn.assigns.scope
      assert scope.installation_id == installation.id
      assert scope.member_id == member.id
      assert scope.role == "editor"
    end

    test "assigns no scope at all when there is no member" do
      conn = signed_in_conn() |> FetchSession.call([]) |> LoadScope.call([])

      refute Map.has_key?(conn.assigns, :scope)
    end
  end

  defp install(opts \\ []), do: InstallationsFixtures.install(opts)

  defp signed_in_conn do
    :get
    |> Plug.Test.conn("/")
    |> init_test_session(%{})
  end

  defp fetch(token) do
    signed_in_conn()
    |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
    |> FetchSession.call([])
  end

  # The table refuses an idle expiry later than the absolute one, so expiring the
  # absolute limit moves both.
  defp expire(session, :idle_expires_at) do
    past = DateTime.add(DateTime.utc_now(), -60, :second)
    update_session(session, idle_expires_at: past)
  end

  defp expire(session, :absolute_expires_at) do
    past = DateTime.add(DateTime.utc_now(), -60, :second)
    update_session(session, idle_expires_at: past, absolute_expires_at: past)
  end

  defp update_session(session, changes) do
    {1, _rows} =
      Repo.update_all(from(s in UserSession, where: s.id == ^session.id), set: changes)

    :ok
  end

  defp set_last_used(session, at), do: update_session(session, last_used_at: at)
end
