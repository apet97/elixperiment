defmodule PumbleAutomationWeb.SettingsLive.Index do
  @moduledoc """
  Installation status, retention, webhook rotation, and uninstall guidance.
  """
  use PumbleAutomationWeb, :live_view

  import PumbleAutomationWeb.AdminComponents
  import PumbleAutomationWeb.CopyComponents

  alias PumbleAutomation.Error
  alias PumbleAutomation.Ingress.Endpoints
  alias PumbleAutomation.Ingress.WebhookEndpoint
  alias PumbleAutomation.Ingress.WebhookService
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Pumble.Manifest
  alias PumbleAutomation.Retention
  alias PumbleAutomationWeb.BrowserSession

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.scope

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:nav_current, :settings)
     |> assign(:can_rotate, Policy.can?(scope, :manage_credentials))
     |> assign(:can_operations, Policy.can?(scope, :destructive_lifecycle))
     |> assign(:confirm, nil)
     |> assign(:revealed, nil)
     |> assign(:endpoints, [])
     |> assign(:manifest, Manifest.build())
     |> reload_endpoints()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_installation={@current_installation}
      current_member={@current_member}
      nav_current={@nav_current}
    >
      <div id="settings-index" class="space-y-6">
        <.header>
          Settings
          <:subtitle>
            Workspace status, retention, inbound webhooks, and uninstall guidance.
          </:subtitle>
        </.header>

        <.installation_card installation={@current_installation} />
        <.operations_card :if={@can_operations} />
        <.diagnostics_card :if={@can_operations} />
        <.retention_card installation={@current_installation} />
        <.webhook_card
          endpoints={@endpoints}
          can_rotate={@can_rotate}
          revealed={@revealed}
        />
        <.uninstall_card />
        <.manifest_card manifest={@manifest} />
        <.help_card />

        <.rotate_dialog :if={@confirm} confirm={@confirm} />
      </div>
    </Layouts.app>
    """
  end

  attr :installation, :any, required: true

  defp installation_card(assigns) do
    ~H"""
    <.card id="settings-installation">
      <:header>Installation</:header>
      <.list>
        <:item title="Workspace">{workspace_label(@installation)}</:item>
        <:item title="Status">{@installation.status}</:item>
        <:item title="Workspace id">{@installation.pumble_workspace_id}</:item>
        <:item title="Recorded bot scope request">{scope_text(@installation.bot_scopes)}</:item>
        <:item title="Recorded user scope request">{scope_text(@installation.user_scopes)}</:item>
      </.list>
      <p id="settings-scope-note" class="mt-3 text-sm text-muted">
        These values record what the application requested at installation. They are not
        provider-confirmed grants.
      </p>
    </.card>
    """
  end

  defp operations_card(assigns) do
    ~H"""
    <.card id="settings-operations">
      <:header>Queue and readiness</:header>
      <p class="text-sm text-muted">
        Owner-only diagnostics for this workspace: queue age, due schedules, stale attempts,
        and whether this node can accept durable work. Public <code>/health/ready</code> stays
        free of tenant data.
      </p>
      <div class="mt-3">
        <.button
          id="settings-operations-link"
          variant="secondary"
          navigate={~p"/settings/operations"}
        >
          Open operations
        </.button>
      </div>
    </.card>
    """
  end

  defp diagnostics_card(assigns) do
    ~H"""
    <.card id="settings-diagnostics">
      <:header>Diagnostic export</:header>
      <p class="text-sm text-muted">
        Owner-only support bundle for one execution or time window. The export is
        hashed, expires quickly, and never includes secrets, tokens, raw bodies, or
        message text.
      </p>
      <div class="mt-3">
        <.button
          id="settings-diagnostics-link"
          variant="secondary"
          navigate={~p"/settings/diagnostics"}
        >
          Export diagnostics
        </.button>
      </div>
    </.card>
    """
  end

  attr :installation, :any, required: true

  defp retention_card(assigns) do
    policy = Retention.policy()
    assigns = assign(assigns, :policy, policy)

    ~H"""
    <.card id="settings-retention">
      <:header>Retention</:header>
      <p class="text-sm text-muted">
        Receipt detail is kept for {@policy.receipts_days} days, execution detail for {@policy.execution_detail_days} days, and audit history for {@policy.audit_days} days.
        Expired sign-in and OAuth state rows are removed promptly. After uninstall, remaining
        workspace data is kept for {@policy.uninstall_grace_days} days so a reinstall can recover
        the tenant, then it is erased. The installation row stays as deleted so audit history
        still names the workspace. There is no legal hold.
      </p>
      <p :if={@installation.deletion_scheduled_at} class="mt-2 text-sm text-ink">
        Deletion scheduled at {DateTime.to_iso8601(@installation.deletion_scheduled_at)}.
      </p>
    </.card>
    """
  end

  attr :endpoints, :list, required: true
  attr :can_rotate, :boolean, required: true
  attr :revealed, :any, default: nil

  defp webhook_card(assigns) do
    ~H"""
    <.card id="settings-webhooks">
      <:header>Inbound webhooks</:header>
      <p class="text-sm text-muted">
        Each endpoint is bound to one workflow version. Credentials remain hidden after they
        are issued. Rotate them only if they are lost or compromised. Previous credentials
        stay valid for {WebhookEndpoint.rotation_overlap_seconds()} seconds.
      </p>

      <.banner
        :if={@revealed}
        id="revealed-webhook-banner"
        tone="warn"
        title="Copy these webhook credentials now"
      >
        They will not be shown again. Store them only in the caller's private secret store.
      </.banner>

      <div :if={@revealed} id="revealed-webhook-token-wrap" class="mt-3 space-y-3">
        <.copy_field
          :if={@revealed[:url]}
          id="revealed-webhook-url"
          label="Endpoint URL"
          value={@revealed.url}
        />
        <.copy_field
          id="revealed-webhook-token"
          label="Bearer token"
          value={@revealed.token}
          type="password"
          autocomplete="off"
        />
        <.copy_field
          :if={@revealed[:signing_secret]}
          id="revealed-webhook-signing-secret"
          label="HMAC signing secret"
          value={@revealed.signing_secret}
          type="password"
          autocomplete="off"
        >
          <:help>
            Send <code>{WebhookService.signature_header()}</code>
            as <code>sha256=&lt;lowercase hex&gt;</code>
            over the exact request-body bytes.
          </:help>
        </.copy_field>
        <.button
          id="dismiss-webhook-token"
          variant="ghost"
          type="button"
          phx-click="dismiss_token"
          class="mt-2"
        >
          I have copied them
        </.button>
      </div>

      <.empty_state :if={@endpoints == []} id="webhooks-empty" title="No webhook endpoints">
        A webhook trigger that has been activated will appear here for credential rotation.
      </.empty_state>

      <div id="webhook-list" class="mt-4 space-y-3">
        <article
          :for={endpoint <- @endpoints}
          id={"webhook-#{endpoint.id}"}
          class="rounded-md border border-line bg-surface px-3 py-3"
        >
          <p class="text-sm font-semibold text-ink">{endpoint.workflow_name}</p>
          <p class="mt-1 break-all font-mono text-xs text-muted">{endpoint.url}</p>
          <p class="mt-1 text-xs text-muted">
            Raw-body HMAC: {if(endpoint.require_signature, do: "required", else: "not required")}
          </p>
          <.button
            :if={@can_rotate}
            id={"rotate-webhook-#{endpoint.id}"}
            variant="secondary"
            type="button"
            phx-click="confirm_rotate"
            phx-value-id={endpoint.id}
            class="mt-2"
          >
            Rotate credentials
          </.button>
        </article>
      </div>
    </.card>
    """
  end

  defp uninstall_card(assigns) do
    ~H"""
    <.card id="settings-uninstall">
      <:header>Uninstall and data deletion</:header>
      <p class="text-sm text-muted">
        Remove the app from the Pumble workspace. Credentials become unusable immediately.
        Workflow data stays for the retention window, then is erased. Reinstalling the same
        workspace during that window restores the tenant instead of creating a second one.
      </p>
    </.card>
    """
  end

  attr :manifest, :any, required: true

  defp manifest_card(assigns) do
    ~H"""
    <.card id="settings-manifest">
      <:header>Manifest</:header>
      <.list>
        <:item title="App">{@manifest.display_name}</:item>
        <:item title="Callback">{@manifest.callback_url}</:item>
        <:item title="Slash command">{@manifest.slash_command.display_name}</:item>
        <:item title="Global shortcut">{@manifest.global_shortcut.display_name}</:item>
        <:item title="Message shortcut">{@manifest.message_shortcut.display_name}</:item>
      </.list>
    </.card>
    """
  end

  defp help_card(assigns) do
    ~H"""
    <.card id="settings-help">
      <:header>Help</:header>
      <div class="flex flex-wrap gap-2">
        <.button id="settings-home-link" variant="secondary" navigate={~p"/"}>Home</.button>
        <.button
          id="settings-signin-link"
          variant="secondary"
          href={BrowserSession.sign_in_path()}
        >
          Sign in
        </.button>
        <.button id="settings-workflows-link" variant="secondary" navigate={~p"/workflows"}>
          Workflows
        </.button>
      </div>
    </.card>
    """
  end

  attr :confirm, :map, required: true

  defp rotate_dialog(assigns) do
    ~H"""
    <.confirm_shell id="webhook-rotate-confirm" title="Rotate these webhook credentials?">
      <p class="text-sm text-muted">
        Callers must switch to the new bearer token and, when enabled, the new HMAC secret.
        Previous credentials remain valid for a short overlap.
      </p>
      <div class="mt-4 flex justify-end gap-2">
        <.button
          id="webhook-rotate-cancel"
          variant="ghost"
          type="button"
          phx-click="cancel_confirm"
        >
          Cancel
        </.button>
        <.button
          id="webhook-rotate-submit"
          variant="primary"
          type="button"
          phx-click="rotate"
          phx-value-id={@confirm.id}
        >
          Rotate credentials
        </.button>
      </div>
    </.confirm_shell>
    """
  end

  @impl true
  def handle_event("confirm_rotate", %{"id" => id}, socket) do
    if socket.assigns.can_rotate do
      {:noreply, assign(socket, :confirm, %{id: id})}
    else
      {:noreply, deny(socket)}
    end
  end

  def handle_event("cancel_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm, nil)}
  end

  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, :revealed, nil)}
  end

  def handle_event("rotate", %{"id" => id}, socket) do
    cond do
      not socket.assigns.can_rotate ->
        {:noreply, deny(socket)}

      not match?(%{id: ^id}, socket.assigns.confirm) ->
        {:noreply, socket}

      true ->
        case Endpoints.rotate(socket.assigns.scope, id) do
          {:ok, %{token: token, signing_secret: signing_secret, endpoint: endpoint}} ->
            {:noreply,
             socket
             |> assign(:confirm, nil)
             |> assign(:revealed, %{
               id: endpoint.id,
               url: Endpoints.public_url(endpoint.public_id),
               token: token,
               signing_secret: signing_secret
             })
             |> put_flash(:info, "Webhook credentials rotated. Copy them now.")
             |> reload_endpoints()}

          {:error, %Error{} = error} ->
            {:noreply, socket |> assign(:confirm, nil) |> put_flash(:error, error.message)}
        end
    end
  end

  defp reload_endpoints(socket) do
    case Endpoints.list(socket.assigns.scope) do
      {:ok, endpoints} -> assign(socket, :endpoints, endpoints)
      {:error, %Error{}} -> assign(socket, :endpoints, [])
    end
  end

  defp workspace_label(%Installation{workspace_name_snapshot: name})
       when is_binary(name) and name != "",
       do: name

  defp workspace_label(%Installation{pumble_workspace_id: id}), do: id

  defp scope_text([]), do: "None recorded"
  defp scope_text(scopes) when is_list(scopes), do: Enum.join(scopes, ", ")

  defp deny(socket) do
    put_flash(socket, :error, "You do not have permission to do that.")
  end
end
