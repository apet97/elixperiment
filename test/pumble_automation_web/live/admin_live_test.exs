defmodule PumbleAutomationWeb.AdminLiveTest do
  @moduledoc """
  Settings: installation, retention, webhook rotation, uninstall guidance.
  """

  use PumbleAutomationWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PumbleAutomation.IngressFixtures

  alias PumbleAutomation.Ingress.WebhookEndpoint
  alias PumbleAutomation.Installations.Lifecycle
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Repo
  alias PumbleAutomationWeb.BrowserSession

  describe "auth and roles" do
    test "a visitor is sent to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/settings")
      assert to == BrowserSession.sign_in_path()
    end

    test "every role can read installation, retention, and uninstall guidance", %{conn: conn} do
      %{session_token: token, member: member, installation: installation} =
        InstallationsFixtures.install()

      InstallationsFixtures.set_role(member, "viewer")

      {:ok, view, html} = live(log_in(conn, token), ~p"/settings")

      assert has_element?(view, "#settings-installation")
      assert has_element?(view, "#settings-retention")
      assert has_element?(view, "#settings-uninstall")
      assert has_element?(view, "#settings-manifest")
      assert has_element?(view, "#settings-help")
      assert has_element?(view, "#webhooks-empty", "credential rotation")
      assert html =~ installation.status
      assert html =~ Integer.to_string(Lifecycle.retention_days())
      assert html =~ "Remove the app from the Pumble workspace"
      refute html =~ "bot-access-token"
      refute html =~ "user-access-token"
      refute has_element?(view, "#rotate-webhook-")
    end
  end

  describe "webhook rotation" do
    test "an owner rotates a token, sees it once, and it is gone after remount", %{conn: conn} do
      %{session_token: token, installation: installation} = InstallationsFixtures.install()
      version = version(installation.id)
      endpoint = webhook_endpoint(version)
      previous = endpoint.token_digest

      {:ok, view, html} = live(log_in(conn, token), ~p"/settings")

      assert has_element?(view, "#webhook-#{endpoint.id}")
      assert html =~ endpoint.public_id
      refute has_element?(view, "#revealed-webhook-token")

      view |> element("#rotate-webhook-#{endpoint.id}") |> render_click()
      assert has_element?(view, "#webhook-rotate-confirm")
      view |> element("#webhook-rotate-submit") |> render_click()

      assert has_element?(view, "#revealed-webhook-token")
      assert has_element?(view, "#revealed-webhook-banner")
      assert has_element?(view, "#dismiss-webhook-token", "I have copied them")

      assert has_element?(
               view,
               ~s(#revealed-webhook-token-copy-control[phx-hook="CopyToClipboard"][phx-update="ignore"])
             )

      assert has_element?(
               view,
               ~s(#revealed-webhook-token-copy[aria-label="Copy Bearer token"])
             )

      updated = Repo.get!(WebhookEndpoint, endpoint.id)
      assert updated.token_digest != previous
      assert updated.previous_token_digest == previous

      {:ok, view, html} = live(log_in(conn, token), ~p"/settings")
      refute has_element?(view, "#revealed-webhook-token")
      refute html =~ Base.encode16(updated.token_digest, case: :lower)
    end

    test "signature credential rotation is encrypted, overlapped, and absent from lists", %{
      conn: conn
    } do
      %{session_token: token, installation: installation} = InstallationsFixtures.install()
      old_secret = WebhookEndpoint.generate_signing_secret()

      endpoint =
        webhook_endpoint(version(installation.id), %{
          require_signature: true,
          signing_secret: old_secret,
          signing_secret_key_version: WebhookEndpoint.signing_secret_key_version()
        })

      {:ok, view, initial_html} = live(log_in(conn, token), ~p"/settings")
      refute initial_html =~ old_secret
      refute has_element?(view, "#revealed-webhook-signing-secret")

      view |> element("#rotate-webhook-#{endpoint.id}") |> render_click()
      view |> element("#webhook-rotate-submit") |> render_click()

      assert has_element?(view, "#revealed-webhook-token")
      assert has_element?(view, "#revealed-webhook-signing-secret")

      updated = Repo.one!(WebhookEndpoint.by_id_for_rotation(installation.id, endpoint.id))
      assert is_binary(updated.signing_secret)
      refute updated.signing_secret == old_secret
      assert updated.previous_signing_secret == old_secret
      assert updated.previous_signing_secret_expires_at
      assert render(view) =~ updated.signing_secret

      assert is_nil(Repo.get!(WebhookEndpoint, endpoint.id).signing_secret)

      {:ok, remounted, html} = live(log_in(conn, token), ~p"/settings")
      refute has_element?(remounted, "#revealed-webhook-signing-secret")
      refute html =~ updated.signing_secret
      refute html =~ old_secret
    end

    test "an editor cannot rotate a webhook token", %{conn: conn} do
      %{session_token: token, member: member, installation: installation} =
        InstallationsFixtures.install()

      endpoint = webhook_endpoint(version(installation.id))
      InstallationsFixtures.set_role(member, "editor")

      {:ok, view, _html} = live(log_in(conn, token), ~p"/settings")

      assert has_element?(view, "#webhook-#{endpoint.id}")
      refute has_element?(view, "#rotate-webhook-#{endpoint.id}")

      html = render_click(view, "rotate", %{"id" => endpoint.id})
      assert html =~ "You do not have permission to do that."
      refute has_element?(view, "#revealed-webhook-token")
    end

    test "an unconfirmed rotate leaves the digest unchanged", %{conn: conn} do
      %{session_token: token, installation: installation} = InstallationsFixtures.install()
      endpoint = webhook_endpoint(version(installation.id))
      previous = endpoint.token_digest

      {:ok, view, _html} = live(log_in(conn, token), ~p"/settings")
      render_click(view, "rotate", %{"id" => endpoint.id})

      refute has_element?(view, "#revealed-webhook-token")
      assert Repo.get!(WebhookEndpoint, endpoint.id).token_digest == previous
    end
  end

  describe "cross-tenant" do
    test "another workspace's webhook does not appear", %{conn: conn} do
      %{installation: other} = InstallationsFixtures.install()
      endpoint = webhook_endpoint(version(other.id))
      %{session_token: token} = InstallationsFixtures.install()

      {:ok, view, html} = live(log_in(conn, token), ~p"/settings")

      refute has_element?(view, "#webhook-#{endpoint.id}")
      refute html =~ endpoint.public_id
    end
  end

  defp log_in(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Test.put_req_cookie(BrowserSession.cookie(), token)
  end
end
