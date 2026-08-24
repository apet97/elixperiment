defmodule PumbleAutomationWeb.AppComponents do
  @moduledoc """
  Authenticated application chrome: identity, navigation, connection, sign-out.
  """
  use Phoenix.Component

  use PumbleAutomationWeb, :verified_routes

  import PumbleAutomationWeb.CoreComponents

  alias Phoenix.LiveView.JS
  alias PumbleAutomation.Installations.Installation
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomation.Scope

  attr :current_scope, :any, default: nil
  attr :current_installation, :any, default: nil
  attr :current_member, :any, default: nil
  attr :nav_current, :atom, default: :home

  def sidebar(assigns) do
    ~H"""
    <aside
      id="app-shell-sidebar"
      aria-label="Workspace"
      class="grid grid-cols-2 gap-x-4 gap-y-3 border-b border-line bg-surface px-4 py-4 lg:block lg:border-b-0 lg:border-r lg:px-5 lg:py-6"
    >
      <div class="flex items-center gap-3">
        <span class="pa-rail-dot" aria-hidden="true"></span>
        <.link
          navigate={~p"/"}
          id="product-home-link"
          class="text-sm font-semibold tracking-tight text-ink"
        >
          Workflow Automation
        </.link>
      </div>

      <.identity_block
        :if={@current_installation && @current_member}
        installation={@current_installation}
        member={@current_member}
        scope={@current_scope}
      />

      <.app_nav :if={@current_scope} scope={@current_scope} nav_current={@nav_current} />
    </aside>
    """
  end

  attr :current_scope, :any, default: nil
  attr :current_installation, :any, default: nil
  attr :current_member, :any, default: nil

  def topbar(assigns) do
    ~H"""
    <header
      id="app-shell-topbar"
      class="flex flex-wrap items-center justify-between gap-3 border-b border-line bg-raised px-4 py-3 sm:px-6"
    >
      <div class="flex min-w-0 items-center gap-3">
        <.connection_status :if={@current_installation} installation={@current_installation} />
        <.role_badge :if={@current_scope} scope={@current_scope} />
      </div>
      <div class="flex items-center gap-2">
        <.theme_toggle />
        <.sign_out_link :if={@current_scope} />
      </div>
    </header>
    """
  end

  attr :scope, :any, required: true
  attr :nav_current, :atom, required: true

  def app_nav(assigns) do
    assigns = assign(assigns, :items, nav_items(assigns.scope, assigns.nav_current))

    ~H"""
    <nav
      id="app-shell-nav"
      class="pa-rail col-span-2 grid grid-cols-2 gap-1 border-t border-line pt-3 sm:grid-cols-4 lg:mt-6 lg:block lg:space-y-1 lg:border-t-0 lg:pt-0"
      aria-label="Primary"
    >
      <div :for={item <- @items} class="relative lg:pl-6">
        <.link
          :if={item.path}
          navigate={item.path}
          id={item.id}
          class={nav_class(item.current?)}
          aria-current={item.current? && "page"}
        >
          <span
            class="pa-rail-dot absolute top-2.5 left-0 hidden lg:block"
            aria-hidden="true"
          ></span>
          {item.label}
        </.link>
        <span
          :if={!item.path}
          id={item.id}
          class={nav_class(false)}
        >
          <span
            class="pa-rail-dot absolute top-2.5 left-0 hidden lg:block"
            aria-hidden="true"
          ></span>
          {item.label}
        </span>
      </div>
    </nav>
    """
  end

  defp identity_block(assigns) do
    ~H"""
    <div id="workspace-identity" class="min-w-0 space-y-1 text-right lg:mt-6 lg:text-left">
      <p class="text-xs font-medium uppercase tracking-wide text-muted">Workspace</p>
      <p class="truncate text-sm font-semibold text-ink">{workspace_label(@installation)}</p>
      <p id="member-identity" class="truncate text-xs text-muted">{member_label(@member)}</p>
    </div>
    """
  end

  defp connection_status(assigns) do
    {tone, label} = connection_copy(assigns.installation)

    assigns = assign(assigns, tone: tone, label: label)

    ~H"""
    <.status_badge id="connection-status" tone={@tone} label={@label} />
    """
  end

  defp role_badge(assigns) do
    ~H"""
    <.status_badge id="role-badge" tone="neutral" label={role_label(@scope.role)} />
    """
  end

  def theme_toggle(assigns) do
    ~H"""
    <div
      id="theme-toggle"
      class="inline-flex rounded-full border border-line bg-surface p-0.5"
      role="group"
      aria-label="Color theme"
    >
      <button
        type="button"
        id="theme-system"
        class="rounded-full p-2 text-muted hover:text-ink"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="Use system theme"
        aria-pressed="false"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4" />
      </button>
      <button
        type="button"
        id="theme-light"
        class="rounded-full p-2 text-muted hover:text-ink"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Use light theme"
        aria-pressed="false"
      >
        <.icon name="hero-sun-micro" class="size-4" />
      </button>
      <button
        type="button"
        id="theme-dark"
        class="rounded-full p-2 text-muted hover:text-ink"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Use dark theme"
        aria-pressed="false"
      >
        <.icon name="hero-moon-micro" class="size-4" />
      </button>
    </div>
    """
  end

  defp sign_out_link(assigns) do
    ~H"""
    <.link
      href={~p"/session/sign-out"}
      method="delete"
      id="sign-out"
      class="inline-flex items-center rounded-md px-3 py-2 text-sm font-semibold text-ink hover:bg-surface"
    >
      Sign out
    </.link>
    """
  end

  defp nav_items(%Scope{} = scope, current) do
    [
      %{id: "nav-home", label: "Home", cap: nil, path: ~p"/", current: :home},
      %{
        id: "nav-workflows",
        label: "Workflows",
        cap: :read_workflows,
        path: ~p"/workflows",
        current: :workflows
      },
      %{
        id: "nav-executions",
        label: "Executions",
        cap: :read_executions,
        path: ~p"/executions",
        current: :executions
      },
      %{
        id: "nav-connections",
        label: "Connections",
        cap: :manage_credentials,
        path: ~p"/connections",
        current: :connections
      },
      %{
        id: "nav-secrets",
        label: "Secrets",
        cap: :manage_secrets,
        path: ~p"/secrets",
        current: :secrets
      },
      %{
        id: "nav-members",
        label: "Members",
        cap: :manage_members,
        path: ~p"/members",
        current: :members
      },
      %{id: "nav-audit", label: "Audit", cap: :read_workflows, path: ~p"/audit", current: :audit},
      %{id: "nav-settings", label: "Settings", cap: nil, path: ~p"/settings", current: :settings}
    ]
    |> Enum.filter(&visible?(&1, scope))
    |> Enum.map(fn item ->
      item
      |> Map.put(:current?, item.current == current)
      |> Map.drop([:cap, :current])
    end)
  end

  defp visible?(%{cap: nil}, %Scope{}), do: true
  defp visible?(%{cap: cap}, %Scope{} = scope), do: Policy.can?(scope, cap)

  defp nav_class(true),
    do: "relative block rounded-md px-2 py-1.5 text-sm font-semibold text-signal"

  defp nav_class(false),
    do: "relative block rounded-md px-2 py-1.5 text-sm text-muted hover:bg-raised hover:text-ink"

  defp workspace_label(%Installation{workspace_name_snapshot: name})
       when is_binary(name) and name != "",
       do: name

  defp workspace_label(%Installation{pumble_workspace_id: id}), do: id

  defp member_label(%WorkspaceMember{profile_snapshot: snapshot} = member) do
    case snapshot_name(snapshot) do
      nil -> member.pumble_user_id
      name -> name
    end
  end

  defp snapshot_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp snapshot_name(%{"display_name" => name}) when is_binary(name) and name != "", do: name
  defp snapshot_name(_snapshot), do: nil

  defp role_label("owner"), do: "Owner"
  defp role_label("editor"), do: "Editor"
  defp role_label("viewer"), do: "Viewer"
  defp role_label(other) when is_binary(other), do: other

  defp connection_copy(%Installation{status: "active"}), do: {"ok", "Connected"}
  defp connection_copy(%Installation{status: "degraded"}), do: {"warn", "Limited connection"}
  defp connection_copy(%Installation{status: "revoked"}), do: {"danger", "Disconnected"}
  defp connection_copy(%Installation{status: status}), do: {"neutral", status}
end
