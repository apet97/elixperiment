defmodule PumbleAutomationWeb.AuditLive.IndexTest do
  @moduledoc """
  Append-only audit history, filters, pagination, and tenant isolation.
  """

  use PumbleAutomationWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PumbleAutomation.Audit
  alias PumbleAutomation.Audit.Writer
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomationWeb.BrowserSession

  describe "auth and roles" do
    test "a visitor is sent to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/audit")
      assert to == BrowserSession.sign_in_path()
    end

    test "a viewer can read audit history without edit controls", %{conn: conn} do
      %{session_token: token, member: member} = InstallationsFixtures.install()
      InstallationsFixtures.set_role(member, "viewer")

      {:ok, view, _html} = live(log_in(conn, token), ~p"/audit")

      assert has_element?(view, "#audit-index")
      assert has_element?(view, "#audit-filter-form")
      refute has_element?(view, "#audit-delete")
      refute has_element?(view, "#audit-edit")
    end
  end

  describe "pagination and filters" do
    test "cursor pagination walks older events", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install()

      Enum.each(1..21, fn index ->
        :ok =
          Writer.append_best_effort(%{
            installation_id: installation.id,
            actor_type: "user",
            actor_id: member.id,
            action: "secret.created",
            resource_type: "secret",
            resource_id: Ecto.UUID.generate(),
            metadata: %{
              "resource_name" => "SECRET_#{index}",
              "actor_role" => "owner",
              "target_kind" => "generic"
            }
          })
      end)

      {:ok, view, _html} = live(log_in(conn, token), ~p"/audit")

      view
      |> form("#audit-filter-form", filter: %{action: "secret.created"})
      |> render_change()

      assert has_element?(view, "#audit-pagination")
      assert has_element?(view, "#audit-pagination-next")
      assert visible_action(view, "secret.created") == Audit.page_size()

      view |> element("#audit-pagination-next") |> render_click()
      assert has_element?(view, "#audit-pagination-newest")
      assert visible_action(view, "secret.created") == 1
    end

    test "action filter hides unmatched events", %{conn: conn} do
      %{session_token: token, installation: installation, member: member} =
        InstallationsFixtures.install()

      :ok =
        Writer.append_best_effort(%{
          installation_id: installation.id,
          actor_type: "user",
          actor_id: member.id,
          action: "secret.created",
          resource_type: "secret",
          resource_id: Ecto.UUID.generate(),
          metadata: %{
            "resource_name" => "FILTER_ME",
            "actor_role" => "owner",
            "target_kind" => "generic"
          }
        })

      {:ok, view, _html} = live(log_in(conn, token), ~p"/audit")

      view
      |> form("#audit-filter-form", filter: %{action: "connection.tested"})
      |> render_change()

      html = render(view)
      refute html =~ "FILTER_ME"
      assert has_element?(view, "#audit-no-matches")
    end
  end

  describe "cross-tenant" do
    test "another workspace's events do not appear", %{conn: conn} do
      %{installation: other, member: other_member} = InstallationsFixtures.install()

      :ok =
        Writer.append_best_effort(%{
          installation_id: other.id,
          actor_type: "user",
          actor_id: other_member.id,
          action: "secret.created",
          resource_type: "secret",
          resource_id: Ecto.UUID.generate(),
          metadata: %{
            "resource_name" => "FOREIGN_SECRET",
            "actor_role" => "owner",
            "target_kind" => "generic"
          }
        })

      %{session_token: token} = InstallationsFixtures.install()
      {:ok, view, html} = live(log_in(conn, token), ~p"/audit")

      refute html =~ "FOREIGN_SECRET"
      refute has_element?(view, "#audit-delete")
    end
  end

  describe "support operations" do
    test "an owner sees the support panel; a viewer does not", %{conn: conn} do
      %{session_token: owner_token} = InstallationsFixtures.install()
      {:ok, owner_view, _html} = live(log_in(conn, owner_token), ~p"/audit")

      assert has_element?(owner_view, "#audit-support")
      assert has_element?(owner_view, "#audit-requeue-form")
      assert has_element?(owner_view, "#audit-reconcile")
      assert has_element?(owner_view, "#audit-export")
      assert has_element?(owner_view, "#audit-delete-tenant")
      refute has_element?(owner_view, "#audit-sql")
      refute has_element?(owner_view, "#audit-delete")

      %{session_token: viewer_token, member: member} = InstallationsFixtures.install()
      InstallationsFixtures.set_role(member, "viewer")
      {:ok, viewer_view, _html} = live(log_in(conn, viewer_token), ~p"/audit")

      refute has_element?(viewer_view, "#audit-support")
      refute has_element?(viewer_view, "#audit-delete-tenant")
      refute has_element?(viewer_view, "#audit-delete")
    end

    test "export diagnostics previews field names without secrets", %{conn: conn} do
      %{session_token: token} = InstallationsFixtures.install()
      {:ok, view, _html} = live(log_in(conn, token), ~p"/audit")

      view |> element("#audit-export") |> render_click()

      assert has_element?(view, "#audit-diagnostics")
      assert has_element?(view, "#audit-diagnostics-fields")
      html = render(view)
      assert html =~ "installation"
      refute html =~ "encrypted_bot_token"
    end

    test "run reconciliation succeeds for the owner", %{conn: conn} do
      %{session_token: token} = InstallationsFixtures.install()
      {:ok, view, _html} = live(log_in(conn, token), ~p"/audit")

      html = view |> element("#audit-reconcile") |> render_click()
      assert html =~ "Reconciliation finished"
    end

    test "an unconfirmed tenant delete does not schedule deletion", %{conn: conn} do
      %{session_token: token, installation: installation} = InstallationsFixtures.install()
      {:ok, view, _html} = live(log_in(conn, token), ~p"/audit")

      render_click(view, "delete_tenant", %{})

      refute has_element?(view, "#audit-delete-confirm")
      stored = Repo.get!(Installation, installation.id)
      assert stored.status == "active"
      assert is_nil(stored.deletion_scheduled_at)
    end
  end

  defp visible_action(view, action) do
    html = render(view)
    length(Regex.scan(~r/data-action="#{Regex.escape(action)}"/, html))
  end

  defp log_in(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
  end
end
