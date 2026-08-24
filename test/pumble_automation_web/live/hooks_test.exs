defmodule PumbleAutomationWeb.Live.HooksTest do
  @moduledoc """
  The LiveView mount hook, which is the socket's half of session handling.

  The hook is called directly with a bare socket. That is the whole unit: it
  takes the session map a mount receives and answers `:cont` with a scope or
  `:halt` with a redirect, and nothing about that decision needs a rendered
  LiveView to be observed.
  """

  use PumbleAutomation.DataCase, async: true

  alias Phoenix.LiveView.Socket
  alias PumbleAutomation.Installations.Sessions
  alias PumbleAutomation.Installations.UserSession
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Scope
  alias PumbleAutomationWeb.BrowserSession
  alias PumbleAutomationWeb.Live.Hooks

  describe "on_mount(:require_scope, ...)" do
    test "assigns the same scope the HTTP plugs build" do
      %{session: session, member: member, installation: installation} =
        InstallationsFixtures.install(role: "editor")

      assert {:cont, socket} = mount(session_map(session))

      assert %Scope{} = scope = socket.assigns.scope
      assert scope.installation_id == installation.id
      assert scope.member_id == member.id
      assert scope.role == "editor"
      assert socket.assigns.current_scope == scope
      assert socket.assigns.current_member.id == member.id
      assert socket.assigns.current_installation.id == installation.id
    end

    test "halts and redirects to sign-in when the session key is absent" do
      assert {:halt, socket} = mount(%{})
      assert_redirected_to_sign_in(socket)
    end

    test "halts when the id names no session" do
      assert {:halt, socket} = mount(%{BrowserSession.live_session_key() => Ecto.UUID.generate()})
      assert_redirected_to_sign_in(socket)
    end

    test "halts on an id that is not an identifier at all" do
      assert {:halt, socket} = mount(%{BrowserSession.live_session_key() => "../../etc"})
      assert_redirected_to_sign_in(socket)
    end

    test "a revoked session terminates the mount, which is what a reconnect hits" do
      %{session: session} = InstallationsFixtures.install()
      Sessions.revoke(Repo, session, DateTime.utc_now())

      assert {:halt, socket} = mount(session_map(session))
      assert_redirected_to_sign_in(socket)
    end

    test "an expired session terminates the mount" do
      %{session: session} = InstallationsFixtures.install()
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      Repo.update_all(from(s in UserSession, where: s.id == ^session.id),
        set: [idle_expires_at: past]
      )

      assert {:halt, socket} = mount(session_map(session))
      assert_redirected_to_sign_in(socket)
    end

    test "the session token itself is never what the hook reads" do
      %{session: session, session_token: token} = InstallationsFixtures.install()

      assert {:halt, _socket} = mount(%{BrowserSession.live_session_key() => token})
      assert {:cont, _socket} = mount(session_map(session))
    end
  end

  describe "on_mount(:maybe_scope, ...)" do
    test "assigns the same scope as require_scope when a session is present" do
      %{session: session, member: member, installation: installation} =
        InstallationsFixtures.install(role: "viewer")

      assert {:cont, socket} = Hooks.on_mount(:maybe_scope, %{}, session_map(session), %Socket{})
      assert socket.assigns.scope.member_id == member.id
      assert socket.assigns.current_installation.id == installation.id
    end

    test "continues without a scope when nobody is signed in" do
      assert {:cont, socket} = Hooks.on_mount(:maybe_scope, %{}, %{}, %Socket{})
      assert socket.assigns.scope == nil
      assert socket.assigns.current_scope == nil
      assert socket.assigns.current_installation == nil
    end
  end

  defp mount(session), do: Hooks.on_mount(:require_scope, %{}, session, %Socket{})

  defp session_map(session), do: %{BrowserSession.live_session_key() => session.id}

  defp assert_redirected_to_sign_in(socket) do
    assert {:redirect, %{to: to, status: 302}} = socket.redirected
    assert to == BrowserSession.sign_in_path()
  end
end
