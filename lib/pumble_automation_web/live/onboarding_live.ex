defmodule PumbleAutomationWeb.OnboardingLive do
  @moduledoc """
  The first screen after sign-in, and the recovery screen when nobody is signed in.

  It reports installation and scope status, the caller's capabilities, Pumble
  Home/setup state, and the next action toward a first workflow. It does not
  create workflows; that belongs to the workflow list.
  """
  use PumbleAutomationWeb, :live_view

  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Workflows

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Home")
     |> assign(:nav_current, :home)
     |> assign_onboarding()}
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
      <div id="onboarding-page" data-state={@onboarding_state}>
        <.uninstalled :if={@onboarding_state == "uninstalled"} />
        <.scope_degraded
          :if={@onboarding_state == "scope_degraded"}
          installation={@current_installation}
        />
        <.revoked :if={@onboarding_state == "revoked"} />
        <.installed
          :if={@onboarding_state in ["installed_empty", "installed_active"]}
          onboarding_state={@onboarding_state}
          installation={@current_installation}
          scope={@current_scope}
          workflows={@workflows}
          can_manage_workflows={@can_manage_workflows}
        />
      </div>
    </Layouts.app>
    """
  end

  defp uninstalled(assigns) do
    ~H"""
    <.header>
      Set up Workflow Automation
      <:subtitle>
        Sign in through Pumble to see installation status and create workflows.
      </:subtitle>
    </.header>

    <.banner id="uninstalled-banner" tone="info" title="This workspace is not connected">
      The application is not installed for this browser session. Install it on a Pumble
      workspace, or sign in if it is already installed.
    </.banner>

    <div class="mt-6 flex flex-wrap gap-3">
      <.button id="install-action" variant="primary" href={~p"/oauth/install"}>
        Install with Pumble
      </.button>
      <.button id="sign-in-action" variant="secondary" href={~p"/oauth/install?intent=signin"}>
        Sign in
      </.button>
    </div>
    """
  end

  defp scope_degraded(assigns) do
    ~H"""
    <.header>
      Restore workspace access
      <:subtitle>The installation is connected with reduced capability.</:subtitle>
    </.header>

    <.banner id="scope-degraded-banner" tone="warn" title="Scopes are reduced">
      Some Pumble operations may fail until an owner reinstalls and reviews the
      granted scopes.
    </.banner>

    <.status_and_setup installation={@installation} />

    <div class="mt-6">
      <.button
        id="reinstall-action"
        variant="primary"
        href={~p"/oauth/install?intent=reinstall"}
      >
        Reinstall with Pumble
      </.button>
    </div>
    """
  end

  defp revoked(assigns) do
    ~H"""
    <.header>
      Reconnect the workspace
      <:subtitle>The stored credential is no longer usable.</:subtitle>
    </.header>

    <.banner id="revoked-banner" tone="danger" title="Disconnected">
      Sign-in still works so an owner can reinstall. Workflows will not run until
      the workspace grants access again.
    </.banner>

    <div class="mt-6">
      <.button
        id="reinstall-action"
        variant="primary"
        href={~p"/oauth/install?intent=reinstall"}
      >
        Reinstall with Pumble
      </.button>
    </div>
    """
  end

  defp installed(assigns) do
    ~H"""
    <.header>
      Workspace home
      <:subtitle>Status, capabilities, and the next step toward a running workflow.</:subtitle>
    </.header>

    <.empty_state
      :if={@onboarding_state == "installed_empty"}
      id="workflows-empty"
      title="No workflows yet"
    >
      Create a draft to start routing Pumble events, schedules, and approvals.
      <:action>
        <.button
          :if={@can_manage_workflows}
          id="first-workflow-action"
          variant="primary"
          navigate={~p"/workflows/new"}
        >
          Create a workflow
        </.button>
        <p :if={!@can_manage_workflows} id="first-workflow-viewer-note" class="text-sm text-muted">
          An editor or owner can create the first workflow.
        </p>
      </:action>
    </.empty_state>

    <.banner
      :if={@onboarding_state == "installed_active"}
      id="installed-active-banner"
      tone="ok"
      title="This workspace has workflows"
    >
      Open
      <.link id="open-workflows-action" navigate={~p"/workflows"} class="font-semibold text-signal">
        Workflows
      </.link>
      to create, find, and control drafts. Status and setup for this installation
      are below.
    </.banner>

    <.status_and_setup installation={@installation} />
    <.capabilities_card scope={@scope} />
    <.pumble_setup_card />
    <.workflow_names :if={@workflows != []} workflows={@workflows} />
    """
  end

  defp status_and_setup(assigns) do
    {tone, label} = installation_copy(assigns.installation)

    assigns =
      assigns
      |> assign(tone: tone, label: label)
      |> assign(:requested_bot, requested_scopes(:bot_scopes))
      |> assign(:requested_user, requested_scopes(:user_scopes))

    ~H"""
    <.card id="installation-status-card">
      <:header>Installation status</:header>
      <div id="scope-status" class="space-y-3">
        <.status_badge id="installation-status" tone={@tone} label={@label} />
        <.list>
          <:item title="Granted bot scopes">{scope_text(@installation.bot_scopes)}</:item>
          <:item title="Granted user scopes">{scope_text(@installation.user_scopes)}</:item>
          <:item title="Requested bot scopes">{scope_text(@requested_bot)}</:item>
          <:item title="Requested user scopes">{scope_text(@requested_user)}</:item>
        </.list>
      </div>
    </.card>
    """
  end

  defp capabilities_card(assigns) do
    assigns = assign(assigns, :capabilities, capability_copy(assigns.scope.role))

    ~H"""
    <.card id="supported-capabilities">
      <:header>What you can do</:header>
      <ul class="space-y-2 text-sm text-ink">
        <li :for={item <- @capabilities} class="flex gap-2">
          <.icon name="hero-check" class="mt-0.5 size-4 text-signal" />
          {item}
        </li>
      </ul>
    </.card>
    """
  end

  defp pumble_setup_card(assigns) do
    ~H"""
    <.card id="pumble-setup">
      <:header>Pumble setup</:header>
      <.list>
        <:item title="Slash command">/workflow</:item>
        <:item title="Global shortcut">Run workflow</:item>
        <:item title="Message shortcut">Run workflow on message</:item>
      </.list>
      <div id="pumble-home-state" class="mt-4" data-status="pending_certification">
        <.status_badge id="pumble-home-badge" tone="neutral" label="Home tab not certified" />
        <p class="mt-2 text-sm text-muted">
          Publishing a Pumble Home view is still unproven (PR-07). Setup uses the
          slash command and shortcuts until that mapping is certified.
        </p>
      </div>
    </.card>
    """
  end

  defp workflow_names(assigns) do
    ~H"""
    <.card id="workflow-names">
      <:header>Recent workflows</:header>
      <ul class="space-y-1 text-sm text-ink">
        <li :for={workflow <- @workflows} id={"workflow-name-#{workflow.id}"} class="truncate">
          {workflow.name}
        </li>
      </ul>
    </.card>
    """
  end

  defp assign_onboarding(socket) do
    case socket.assigns.current_installation do
      nil ->
        assign(socket,
          onboarding_state: "uninstalled",
          workflows: [],
          can_manage_workflows: false
        )

      %Installation{} = installation ->
        scope = socket.assigns.scope
        workflows = load_workflows(scope)

        assign(socket,
          onboarding_state: classify(installation, workflows),
          workflows: workflows,
          can_manage_workflows: Policy.can?(scope, :manage_workflows)
        )
    end
  end

  defp load_workflows(scope) do
    case Workflows.list_workflows(scope, limit: 8) do
      {:ok, workflows} -> workflows
      {:error, _error} -> []
    end
  end

  defp classify(%Installation{status: "degraded"}, _workflows), do: "scope_degraded"
  defp classify(%Installation{status: "revoked"}, _workflows), do: "revoked"
  defp classify(%Installation{status: "active"}, []), do: "installed_empty"
  defp classify(%Installation{status: "active"}, _workflows), do: "installed_active"
  defp classify(_installation, _workflows), do: "uninstalled"

  defp installation_copy(%Installation{status: "active"}), do: {"ok", "Installed"}
  defp installation_copy(%Installation{status: "degraded"}), do: {"warn", "Scope reduced"}
  defp installation_copy(%Installation{status: "revoked"}), do: {"danger", "Revoked"}
  defp installation_copy(%Installation{status: status}), do: {"neutral", status}

  defp scope_text([]), do: "Not recorded"
  defp scope_text(scopes) when is_list(scopes), do: Enum.join(scopes, ", ")

  defp requested_scopes(key) do
    :pumble_automation
    |> Application.fetch_env!(:pumble)
    |> Keyword.get(key, [])
  end

  defp capability_copy(role) do
    Policy.capabilities(role)
    |> Enum.map(&capability_label/1)
  end

  defp capability_label(:read_workflows), do: "Read workflows"
  defp capability_label(:read_executions), do: "Read executions"
  defp capability_label(:manage_workflows), do: "Create and edit workflows"
  defp capability_label(:test_workflows), do: "Run workflow tests"
  defp capability_label(:activate_workflows), do: "Activate and deactivate workflows"
  defp capability_label(:retry_execution), do: "Retry executions"
  defp capability_label(:cancel_execution), do: "Cancel executions"
  defp capability_label(:manage_members), do: "Manage members"
  defp capability_label(:manage_credentials), do: "Manage HTTP connections"
  defp capability_label(:manage_secrets), do: "Manage secrets"
  defp capability_label(:destructive_lifecycle), do: "Uninstall and delete workspace data"
  defp capability_label(:resolve_uncertainty), do: "Resolve uncertain executions"
  defp capability_label(other), do: Atom.to_string(other)
end
