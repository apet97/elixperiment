defmodule PumbleAutomationWeb.ConnectionLive.IndexTest do
  @moduledoc """
  Connection CRUD, enabled state, SafeHttp probe, and tenant isolation.
  """

  use PumbleAutomationWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PumbleAutomation.Connections
  alias PumbleAutomation.ConnectionsFixtures
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Scope
  alias PumbleAutomationWeb.BrowserSession

  @planted "planted-connection-secret-never-shown"

  describe "auth and roles" do
    test "a visitor is sent to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/connections")
      assert to == BrowserSession.sign_in_path()
    end

    test "an owner creates, disables, and deletes a connection", %{conn: conn} do
      %{session_token: token, member: member} = InstallationsFixtures.install()
      scope = Scope.new(member)

      {:ok, view, _html} = live(log_in(conn, token), ~p"/connections/new")
      assert has_element?(view, "#connection-form")

      view
      |> form("#connection-form",
        connection: %{
          name: "Tickets",
          base_origin: "https://api.example.test",
          base_path_prefix: "/v1",
          enabled: "true"
        }
      )
      |> render_submit()

      assert {:ok, [connection]} = Connections.list_connections(scope)
      assert connection.name == "Tickets"
      assert connection.enabled
      assert has_element?(view, "#connection-#{connection.id}")
      assert has_element?(view, ~s(#connection-enabled-#{connection.id}))

      {:ok, view, _html} = live(log_in(conn, token), ~p"/connections/#{connection.id}/edit")

      view
      |> form("#connection-form",
        connection: %{
          name: "Tickets",
          base_origin: "https://api.example.test",
          base_path_prefix: "/v1",
          enabled: false
        }
      )
      |> render_submit()

      assert {:ok, [updated]} = Connections.list_connections(scope)
      refute updated.enabled

      view |> element("#delete-connection-#{connection.id}") |> render_click()
      assert has_element?(view, "#connection-delete-confirm")
      view |> element("#connection-delete-submit") |> render_click()
      refute has_element?(view, "#connection-#{connection.id}")
    end

    test "an editor sees connections without write controls", %{conn: conn} do
      %{session_token: token, member: member} = InstallationsFixtures.install()
      connection = ConnectionsFixtures.connection(Scope.new(member), %{name: "Shared HTTP"})
      InstallationsFixtures.set_role(member, "editor")

      {:ok, view, _html} = live(log_in(conn, token), ~p"/connections")

      assert has_element?(view, "#connection-#{connection.id}")
      refute has_element?(view, "#create-connection-action")
      refute has_element?(view, "#test-connection-#{connection.id}")
      refute has_element?(view, "#delete-connection-#{connection.id}")
    end

    test "a viewer cannot enumerate connections", %{conn: conn} do
      %{session_token: token, member: member} = InstallationsFixtures.install()
      connection = ConnectionsFixtures.connection(Scope.new(member), %{name: "Hidden HTTP"})
      InstallationsFixtures.set_role(member, "viewer")

      {:ok, view, html} = live(log_in(conn, token), ~p"/connections")

      assert has_element?(view, "#connections-forbidden")
      refute has_element?(view, "#connection-#{connection.id}")
      refute html =~ "Hidden HTTP"
    end
  end

  describe "safe test request" do
    test "a loopback origin is blocked and never leaks a body or secret", %{conn: conn} do
      %{session_token: token, member: member} = InstallationsFixtures.install()
      scope = Scope.new(member)
      secret = ConnectionsFixtures.secret(scope, %{name: "PROBE_TOKEN", value: @planted})

      connection =
        ConnectionsFixtures.connection(scope, %{
          name: "Loopback",
          base_origin: "https://127.0.0.1",
          base_path_prefix: nil,
          secret_headers: [%{header: "authorization", secret_id: secret.id}]
        })

      {:ok, view, html} = live(log_in(conn, token), ~p"/connections")

      refute html =~ @planted
      assert has_element?(view, "#test-connection-#{connection.id}")

      view |> element("#test-connection-#{connection.id}") |> render_click()
      assert has_element?(view, "#connection-test-confirm")

      html = view |> element("#connection-test-submit") |> render_click()

      assert html =~ "That address is not allowed."
      refute html =~ @planted
      assert has_element?(view, "#connection-last-outcome-#{connection.id}")
    end
  end

  describe "cross-tenant" do
    test "another workspace's connection does not appear", %{conn: conn} do
      %{member: member} = InstallationsFixtures.install()
      connection = ConnectionsFixtures.connection(Scope.new(member), %{name: "Foreign HTTP"})
      %{session_token: token} = InstallationsFixtures.install()

      {:ok, view, html} = live(log_in(conn, token), ~p"/connections")

      refute has_element?(view, "#connection-#{connection.id}")
      refute html =~ "Foreign HTTP"

      assert {:error, {kind, %{to: to, flash: flash}}} =
               live(log_in(conn, token), ~p"/connections/#{connection.id}/edit")

      assert kind in [:live_redirect, :live_patch]
      assert to == ~p"/connections"
      assert flash["error"] == "That resource does not exist."
    end
  end

  defp log_in(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
  end
end
