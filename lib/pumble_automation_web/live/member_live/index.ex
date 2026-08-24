defmodule PumbleAutomationWeb.MemberLive.Index do
  @moduledoc """
  Workspace members, local roles, and last-owner protection.
  """
  use PumbleAutomationWeb, :live_view

  import PumbleAutomationWeb.AdminComponents

  alias PumbleAutomation.Error
  alias PumbleAutomation.Installations.Members
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Installations.WorkspaceMember
  alias PumbleAutomationWeb.BrowserSession

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.scope

    {:ok,
     socket
     |> assign(:page_title, "Members")
     |> assign(:nav_current, :members)
     |> assign(:can_manage, Policy.can?(scope, :manage_members))
     |> assign(:confirm, nil)
     |> assign(:owner_count, 0)
     |> assign(:entries, [])
     |> stream(:members, [], dom_id: &"member-#{&1.id}")}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, reload(socket)}
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
      <div id="member-index">
        <.header>
          Members
          <:subtitle>
            Local roles for this application. Pumble workspace admins are not owners here
            unless they installed the app or an owner assigned the role.
          </:subtitle>
        </.header>

        <.error_state :if={not @can_manage} id="members-forbidden" title="Not available">
          Only an owner can manage members.
        </.error_state>

        <.card :if={@can_manage} id="member-signin-guidance">
          <:header>Invite and sign-in</:header>
          <p class="text-sm text-muted">
            There is no email invite. A teammate signs in through Pumble. The first installer
            is the owner; later sign-ins join as viewers until an owner changes the role.
          </p>
          <div class="mt-3">
            <.button id="member-signin-link" variant="secondary" href={BrowserSession.sign_in_path()}>
              Open sign-in
            </.button>
          </div>
        </.card>

        <div :if={@entries != []} id="member-list" phx-update="stream" class="mt-4 space-y-4">
          <.member_card
            :for={{id, member} <- @streams.members}
            id={id}
            member={member}
            can_manage={@can_manage}
            last_owner?={last_owner?(member, @owner_count)}
          />
        </div>

        <.role_dialog :if={@confirm} confirm={@confirm} />
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :member, :map, required: true
  attr :can_manage, :boolean, required: true
  attr :last_owner?, :boolean, required: true

  defp member_card(assigns) do
    ~H"""
    <article id={@id} class="rounded-lg border border-line bg-raised p-5">
      <div class="flex min-w-0 flex-wrap items-start justify-between gap-4">
        <div class="min-w-0">
          <h2 class="truncate text-sm font-semibold text-ink">{member_name(@member)}</h2>
          <p id={"member-pumble-id-#{@member.id}"} class="mt-1 font-mono text-xs text-muted">
            {@member.pumble_user_id}
          </p>
          <.status_badge
            id={"member-role-#{@member.id}"}
            tone="neutral"
            label={role_label(@member.role)}
          />
        </div>
        <form
          :if={@can_manage}
          id={"member-role-form-#{@member.id}"}
          phx-change="prompt_role"
          class="sm:w-48"
        >
          <input type="hidden" name="member_id" value={@member.id} />
          <.input
            id={"member-role-select-#{@member.id}"}
            name="role"
            type="select"
            label="Role"
            value={@member.role}
            options={role_options()}
            disabled={@last_owner?}
          />
          <p :if={@last_owner?} id={"member-last-owner-#{@member.id}"} class="text-xs text-muted">
            At least one owner must remain.
          </p>
        </form>
      </div>
    </article>
    """
  end

  attr :confirm, :map, required: true

  defp role_dialog(assigns) do
    ~H"""
    <.confirm_shell id="member-role-confirm" title="Change this member's role?">
      <p class="text-sm text-muted">
        Their current sessions will end. They must sign in again to pick up the new role.
      </p>
      <div class="mt-4 flex justify-end gap-2">
        <.button id="member-role-cancel" variant="ghost" type="button" phx-click="cancel_confirm">
          Cancel
        </.button>
        <.button
          id="member-role-submit"
          variant="primary"
          type="button"
          phx-click="change_role"
          phx-value-id={@confirm.id}
          phx-value-role={@confirm.role}
        >
          Change role
        </.button>
      </div>
    </.confirm_shell>
    """
  end

  @impl true
  def handle_event("prompt_role", %{"member_id" => id, "role" => role}, socket) do
    if socket.assigns.can_manage do
      member = Enum.find(socket.assigns.entries, &(&1.id == id))

      cond do
        is_nil(member) ->
          {:noreply, put_flash(socket, :error, "That resource does not exist.")}

        member.role == role ->
          {:noreply, socket}

        last_owner?(member, socket.assigns.owner_count) and role != "owner" ->
          {:noreply, put_flash(socket, :error, "At least one owner must remain.")}

        true ->
          {:noreply, assign(socket, :confirm, %{id: id, role: role})}
      end
    else
      {:noreply, deny(socket)}
    end
  end

  def handle_event("cancel_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm, nil)}
  end

  def handle_event("change_role", %{"id" => id, "role" => role}, socket) do
    cond do
      not socket.assigns.can_manage ->
        {:noreply, deny(socket)}

      not match?(%{id: ^id, role: ^role}, socket.assigns.confirm) ->
        {:noreply, socket}

      true ->
        case Members.update_role(socket.assigns.scope, id, role) do
          {:ok, _member} ->
            {:noreply,
             socket
             |> assign(:confirm, nil)
             |> put_flash(:info, "Role updated. Their sessions have ended.")
             |> reload()}

          {:error, %Error{} = error} ->
            {:noreply, socket |> assign(:confirm, nil) |> put_flash(:error, error.message)}
        end
    end
  end

  defp reload(socket) do
    scope = socket.assigns.scope

    case Members.list(scope) do
      {:ok, members} ->
        owner_count = Enum.count(members, &(&1.role == "owner" and is_nil(&1.disabled_at)))

        socket
        |> assign(:entries, members)
        |> assign(:owner_count, owner_count)
        |> assign(:can_manage, true)
        |> stream(:members, members, reset: true, dom_id: &"member-#{&1.id}")

      {:error, %Error{class: :permission}} ->
        socket
        |> assign(:entries, [])
        |> assign(:can_manage, false)
        |> stream(:members, [], reset: true)

      {:error, %Error{} = error} ->
        socket
        |> assign(:entries, [])
        |> put_flash(:error, error.message)
        |> stream(:members, [], reset: true)
    end
  end

  defp last_owner?(%WorkspaceMember{role: "owner"}, 1), do: true
  defp last_owner?(_member, _count), do: false

  defp member_name(%WorkspaceMember{profile_snapshot: snapshot} = member) do
    case snapshot do
      %{"name" => name} when is_binary(name) and name != "" -> name
      %{"display_name" => name} when is_binary(name) and name != "" -> name
      _other -> member.pumble_user_id
    end
  end

  defp role_label("owner"), do: "Owner"
  defp role_label("editor"), do: "Editor"
  defp role_label("viewer"), do: "Viewer"
  defp role_label(other), do: other

  defp role_options do
    Enum.map(WorkspaceMember.roles(), &{role_label(&1), &1})
  end

  defp deny(socket) do
    put_flash(socket, :error, "You do not have permission to do that.")
  end
end
