defmodule PumbleAutomationWeb.SessionControllerTest do
  @moduledoc """
  Signing out, and the CSRF protection around it.

  Sign-out is a mutation, so the tests check the two things a mutation route
  owes: that it takes effect in the database, and that a request without the
  browser pipeline's CSRF token cannot reach it at all.
  """

  use PumbleAutomationWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias PumbleAutomation.Installations.Sessions
  alias PumbleAutomation.Installations.UserSession
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomationWeb.BrowserSession

  describe "DELETE /session/sign-out" do
    test "revokes this session, clears the cookie, and returns to sign-in", %{conn: conn} do
      %{session_token: token, session: session} = InstallationsFixtures.install()

      conn = conn |> sign_in(token) |> delete_with_csrf(~p"/session/sign-out")

      assert redirected_to(conn) == BrowserSession.sign_in_path()
      assert Repo.get!(UserSession, session.id).revoked_at
      assert %{max_age: 0} = conn.resp_cookies[BrowserSession.cookie()]
    end

    test "the revoked session is refused on the next request", %{conn: conn} do
      %{session_token: token} = InstallationsFixtures.install()

      conn |> sign_in(token) |> delete_with_csrf(~p"/session/sign-out")

      assert Sessions.fetch(token, DateTime.utc_now()) == :error
    end

    test "a request without a session redirects to sign-in instead", %{conn: conn} do
      conn = delete_with_csrf(conn, ~p"/session/sign-out")

      assert redirected_to(conn) == BrowserSession.sign_in_path()
    end

    # `Phoenix.ConnTest.build_conn/0` sets `:plug_skip_csrf_protection`, so a
    # test that wants to see the real check has to put the protection back.
    test "protect_from_forgery applies: no CSRF token, no sign-out", %{conn: conn} do
      %{session_token: token, session: session} = InstallationsFixtures.install()

      conn =
        conn
        |> sign_in(token)
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> Plug.Test.init_test_session(%{})

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        delete(conn, ~p"/session/sign-out")
      end

      refute Repo.get!(UserSession, session.id).revoked_at
    end
  end

  describe "DELETE /session/all" do
    test "revokes every session this member holds", %{conn: conn} do
      %{session_token: token, member: member} = InstallationsFixtures.install()
      {:ok, other} = Sessions.issue(Repo, member)

      conn |> sign_in(token) |> delete_with_csrf(~p"/session/all")

      assert Repo.get!(UserSession, other.session.id).revoked_at
    end

    test "an owner may revoke every session in the installation", %{conn: conn} do
      %{session_token: token, installation: installation} = InstallationsFixtures.install()

      stranger =
        InstallationsFixtures.install(
          workspace: InstallationsFixtures.unique_workspace(),
          user: "pumble-user-2"
        )

      conn |> sign_in(token) |> delete_with_csrf(~p"/session/all?scope=installation")

      assert revoked_count(installation.id) > 0
      refute Repo.get!(UserSession, stranger.session.id).revoked_at
    end

    test "a viewer asking for the installation only signs itself out", %{conn: conn} do
      %{session_token: token, member: member} = InstallationsFixtures.install(role: "viewer")
      {:ok, own_other} = Sessions.issue(Repo, member)
      stranger = InstallationsFixtures.install(user: "pumble-user-3")

      conn |> sign_in(token) |> delete_with_csrf(~p"/session/all?scope=installation")

      assert Repo.get!(UserSession, own_other.session.id).revoked_at
      refute Repo.get!(UserSession, stranger.session.id).revoked_at
    end
  end

  defp sign_in(conn, token) do
    Plug.Test.put_req_cookie(conn, BrowserSession.cookie(), token)
  end

  # `Phoenix.ConnTest.build_conn/0` already sets `:plug_skip_csrf_protection`, so
  # these requests stand for a browser that submitted the token the page carried.
  # The test above is the one that removes the skip and checks the real refusal.
  defp delete_with_csrf(conn, path) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> delete(path)
  end

  defp revoked_count(installation_id) do
    Repo.aggregate(
      from(s in UserSession,
        where: s.workspace_member_id in subquery(Sessions.member_ids(installation_id)),
        where: not is_nil(s.revoked_at)
      ),
      :count
    )
  end
end
