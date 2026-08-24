defmodule PumbleAutomationWeb.MemberLive.IndexTest do
  @moduledoc """
  Member list, role matrix, last-owner protection, and sign-in guidance.
  """

  use PumbleAutomationWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomationWeb.BrowserSession

  describe "auth and roles" do
    test "a visitor is sent to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/members")
      assert to == BrowserSession.sign_in_path()
    end

    test "an owner sees invite guidance and cannot demote the last owner", %{conn: conn} do
      %{session_token: token, member: member} = InstallationsFixtures.install()

      {:ok, view, html} = live(log_in(conn, token), ~p"/members")

      assert has_element?(view, "#member-signin-guidance")
      assert has_element?(view, "#member-signin-link")
      assert html =~ "There is no email invite"
      assert has_element?(view, "#member-#{member.id}")
      assert has_element?(view, "#member-last-owner-#{member.id}")
      assert has_element?(view, "#member-role-select-#{member.id}[disabled]")

      html = render_click(view, "prompt_role", %{"member_id" => member.id, "role" => "viewer"})
      assert html =~ "At least one owner must remain."
      refute has_element?(view, "#member-role-confirm")

      render_click(view, "change_role", %{"id" => member.id, "role" => "viewer"})
      assert Repo.get!(WorkspaceMember, member.id).role == "owner"
    end

    test "an owner can change another member's role after confirmation", %{conn: conn} do
      %{session_token: token, installation: installation} = InstallationsFixtures.install()

      extra =
        Repo.insert!(
          WorkspaceMember.changeset(%WorkspaceMember{}, %{
            installation_id: installation.id,
            pumble_user_id: "pumble-user-#{System.unique_integer([:positive])}",
            role: "viewer",
            profile_snapshot: %{"name" => "Sam Viewer"}
          })
        )

      {:ok, view, html} = live(log_in(conn, token), ~p"/members")

      assert html =~ "Sam Viewer"
      assert has_element?(view, "#member-#{extra.id}")
      refute has_element?(view, "#member-last-owner-#{extra.id}")

      view
      |> form("#member-role-form-#{extra.id}", %{role: "editor"})
      |> render_change()

      assert has_element?(view, "#member-role-confirm")
      view |> element("#member-role-submit") |> render_click()

      assert Repo.get!(WorkspaceMember, extra.id).role == "editor"
      assert has_element?(view, "#member-role-#{extra.id}")
    end

    test "an editor cannot manage members", %{conn: conn} do
      %{session_token: token, member: member} = InstallationsFixtures.install()
      InstallationsFixtures.set_role(member, "editor")

      {:ok, view, _html} = live(log_in(conn, token), ~p"/members")

      assert has_element?(view, "#members-forbidden")
      refute has_element?(view, "#member-role-form-#{member.id}")
    end

    test "a viewer cannot manage members", %{conn: conn} do
      %{session_token: token, member: member} = InstallationsFixtures.install()
      InstallationsFixtures.set_role(member, "viewer")

      {:ok, view, _html} = live(log_in(conn, token), ~p"/members")

      assert has_element?(view, "#members-forbidden")
    end
  end

  describe "cross-tenant" do
    test "another workspace's member does not appear", %{conn: conn} do
      %{member: stranger} = InstallationsFixtures.install(user: "pumble-user-foreign")
      %{session_token: token} = InstallationsFixtures.install()

      {:ok, view, html} = live(log_in(conn, token), ~p"/members")

      refute has_element?(view, "#member-#{stranger.id}")
      refute html =~ stranger.pumble_user_id
    end
  end

  defp log_in(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
  end
end
