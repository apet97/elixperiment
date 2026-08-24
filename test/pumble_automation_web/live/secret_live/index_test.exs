defmodule PumbleAutomationWeb.SecretLive.IndexTest do
  @moduledoc """
  Write-only secret administration, roles, and tenant isolation.
  """

  use PumbleAutomationWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PumbleAutomation.Connections
  alias PumbleAutomation.Connections.Secret
  alias PumbleAutomation.ConnectionsFixtures
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope
  alias PumbleAutomationWeb.BrowserSession

  @planted "planted-secret-value-never-shown"

  describe "auth and roles" do
    test "a visitor is sent to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/secrets")
      assert to == BrowserSession.sign_in_path()
    end

    test "an owner creates a secret whose value never returns in the DOM", %{conn: conn} do
      %{session_token: token, member: member} = InstallationsFixtures.install()

      {:ok, view, html} = live(log_in(conn, token), ~p"/secrets/new")

      assert has_element?(view, "#secret-form")
      assert has_element?(view, ~s(#secret-value[type="password"]))
      assert has_element?(view, ~s(#secret-value[autocomplete="new-password"]))
      refute html =~ @planted

      html =
        view
        |> form("#secret-form",
          secret: %{name: "PLANTED_TOKEN", kind: "generic", value: @planted}
        )
        |> render_submit()

      refute html =~ @planted
      assert has_element?(view, "#secret-index")
      refute has_element?(view, "#secret-form")

      assert {:ok, [secret]} = Connections.list_secrets(Scope.new(member))
      assert secret.name == "PLANTED_TOKEN"
      refute Map.has_key?(secret, :value)
      assert Repo.get!(Secret, secret.id).value == nil
      assert has_element?(view, "#secret-#{secret.id}")
    end

    test "replacing a value stays write-only", %{conn: conn} do
      %{session_token: token, member: member} = InstallationsFixtures.install()

      secret =
        ConnectionsFixtures.secret(Scope.new(member), %{name: "ROTATE_ME", value: "old-value"})

      {:ok, view, html} = live(log_in(conn, token), ~p"/secrets")

      refute html =~ "old-value"
      refute html =~ @planted
      assert has_element?(view, "#secret-#{secret.id}")

      view |> element("#replace-secret-#{secret.id}") |> render_click()
      assert has_element?(view, "#secret-replace-form-#{secret.id}")
      assert has_element?(view, ~s(#secret-replace-value-#{secret.id}[type="password"]))

      html =
        view
        |> form("#secret-replace-form-#{secret.id}", secret: %{value: @planted})
        |> render_submit()

      refute html =~ @planted
      refute html =~ "old-value"
      refute has_element?(view, "#secret-replace-form-#{secret.id}")
    end

    test "replace without opening the inline form is ignored", %{conn: conn} do
      %{session_token: token, member: member} = InstallationsFixtures.install()

      secret =
        ConnectionsFixtures.secret(Scope.new(member), %{name: "GATED_ROTATE", value: "before"})

      {:ok, view, _html} = live(log_in(conn, token), ~p"/secrets")

      render_click(view, "replace", %{
        "secret_id" => secret.id,
        "secret" => %{"value" => @planted}
      })

      refute has_element?(view, "#secret-replace-form-#{secret.id}")
      refute render(view) =~ "Secret value replaced"
    end

    test "an editor sees names without write controls", %{conn: conn} do
      %{session_token: token, member: member} = InstallationsFixtures.install()

      secret =
        ConnectionsFixtures.secret(Scope.new(member), %{name: "EDITOR_SEES", value: @planted})

      InstallationsFixtures.set_role(member, "editor")

      {:ok, view, html} = live(log_in(conn, token), ~p"/secrets")

      assert has_element?(view, "#secret-#{secret.id}")
      refute has_element?(view, "#create-secret-action")
      refute has_element?(view, "#delete-secret-#{secret.id}")
      refute html =~ @planted

      html = render_click(view, "create", %{"secret" => %{"name" => "NOPE", "value" => @planted}})
      assert html =~ "You do not have permission to do that."
      refute html =~ @planted
    end

    test "a viewer cannot enumerate secrets", %{conn: conn} do
      %{session_token: token, member: member} = InstallationsFixtures.install()
      secret = ConnectionsFixtures.secret(Scope.new(member), %{name: "HIDDEN", value: @planted})
      InstallationsFixtures.set_role(member, "viewer")

      {:ok, view, html} = live(log_in(conn, token), ~p"/secrets")

      assert has_element?(view, "#secrets-forbidden")
      refute has_element?(view, "#secret-#{secret.id}")
      refute html =~ "HIDDEN"
      refute html =~ @planted
    end
  end

  describe "cross-tenant" do
    test "another workspace's secret does not appear", %{conn: conn} do
      %{member: member} = InstallationsFixtures.install()
      secret = ConnectionsFixtures.secret(Scope.new(member), %{name: "OTHER_TENANT"})
      %{session_token: token} = InstallationsFixtures.install()

      {:ok, view, html} = live(log_in(conn, token), ~p"/secrets")

      refute has_element?(view, "#secret-#{secret.id}")
      refute html =~ "OTHER_TENANT"
    end
  end

  defp log_in(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
  end
end
