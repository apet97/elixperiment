defmodule PumbleAutomationWeb.SecretLive.Index do
  @moduledoc """
  Write-only secret administration: metadata, rotation, and dependency display.
  """
  use PumbleAutomationWeb, :live_view

  import PumbleAutomationWeb.AdminComponents

  alias PumbleAutomation.Connections
  alias PumbleAutomation.Connections.Secret
  alias PumbleAutomation.Error
  alias PumbleAutomation.Installations.Policy

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.scope

    {:ok,
     socket
     |> assign(:page_title, "Secrets")
     |> assign(:nav_current, :secrets)
     |> assign(:can_read, Policy.can?(scope, :manage_workflows))
     |> assign(:can_write, Policy.can?(scope, :manage_secrets))
     |> assign(:confirm, nil)
     |> assign(:replacing_id, nil)
     |> assign(:form, empty_form())
     |> assign(:replace_form, replace_form())
     |> assign(:usage, %{})
     |> assign(:entries, [])
     |> stream(:secrets, [], dom_id: &"secret-#{&1.id}")}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    socket = reload(socket)

    {:noreply,
     if socket.assigns.live_action == :new and not socket.assigns.can_write do
       socket
       |> put_flash(:error, "You do not have permission to do that.")
       |> push_patch(to: ~p"/secrets")
     else
       socket
     end}
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
      <div id="secret-index">
        <.header>
          Secrets
          <:subtitle>
            Names are visible to editors. Values are write-only and never shown again.
          </:subtitle>
          <:actions>
            <.button
              :if={@can_write}
              id="create-secret-action"
              variant="primary"
              patch={~p"/secrets/new"}
            >
              Add secret
            </.button>
          </:actions>
        </.header>

        <.error_state :if={not @can_read} id="secrets-forbidden" title="Not available">
          You do not have permission to view secrets.
        </.error_state>

        <.empty_state
          :if={@can_read and @entries == [] and @live_action != :new}
          id="secrets-empty"
          title="No secrets yet"
        >
          Store API keys and tokens by name. Workflows reference the name, never the value.
          <:action>
            <.button
              :if={@can_write}
              id="first-secret-action"
              variant="primary"
              patch={~p"/secrets/new"}
            >
              Add a secret
            </.button>
          </:action>
        </.empty_state>

        <.create_form :if={@can_write and @live_action == :new} form={@form} />

        <div :if={@entries != []} id="secret-list" phx-update="stream" class="space-y-4">
          <.secret_card
            :for={{id, secret} <- @streams.secrets}
            id={id}
            secret={secret}
            usage={Map.get(@usage, secret.id, %{workflows: [], connections: []})}
            can_write={@can_write}
            replacing?={@replacing_id == secret.id}
            replace_form={@replace_form}
          />
        </div>

        <.delete_dialog :if={@confirm} confirm={@confirm} />
      </div>
    </Layouts.app>
    """
  end

  attr :form, :any, required: true

  defp create_form(assigns) do
    ~H"""
    <.card id="secret-create-card">
      <:header>New secret</:header>
      <.form
        for={@form}
        id="secret-form"
        phx-submit="create"
        autocomplete="off"
        class="space-y-3"
      >
        <.input field={@form[:name]} type="text" label="Name" placeholder="API_TOKEN" />
        <.input
          field={@form[:kind]}
          type="select"
          label="Kind"
          options={kind_options()}
        />
        <.input field={@form[:description]} type="text" label="Description" />
        <.input
          field={@form[:value]}
          id="secret-value"
          type="password"
          label="Value"
          autocomplete="new-password"
        />
        <div class="flex gap-2">
          <.button id="secret-create-submit" variant="primary">Save secret</.button>
          <.button id="secret-create-cancel" variant="ghost" patch={~p"/secrets"}>Cancel</.button>
        </div>
      </.form>
    </.card>
    """
  end

  attr :id, :string, required: true
  attr :secret, :map, required: true
  attr :usage, :map, required: true
  attr :can_write, :boolean, required: true
  attr :replacing?, :boolean, required: true
  attr :replace_form, :any, required: true

  defp secret_card(assigns) do
    ~H"""
    <article id={@id} class="rounded-lg border border-line bg-raised p-5">
      <div class="flex min-w-0 items-start justify-between gap-4">
        <div class="min-w-0">
          <h2 class="truncate font-mono text-sm font-semibold text-ink">{@secret.name}</h2>
          <p class="mt-1 text-sm text-muted">{@secret.kind}</p>
          <p :if={@secret.description} class="mt-1 text-sm text-ink">{@secret.description}</p>
          <.usage_note
            id={"secret-usage-#{@secret.id}"}
            workflows={@usage.workflows}
            connections={@usage.connections}
          />
        </div>
        <div :if={@can_write} class="flex flex-wrap gap-2">
          <.button
            id={"replace-secret-#{@secret.id}"}
            variant="secondary"
            type="button"
            phx-click="start_replace"
            phx-value-id={@secret.id}
          >
            Replace value
          </.button>
          <.button
            id={"delete-secret-#{@secret.id}"}
            variant="danger"
            type="button"
            phx-click="confirm_delete"
            phx-value-id={@secret.id}
          >
            Delete
          </.button>
        </div>
      </div>

      <.form
        :if={@replacing?}
        for={@replace_form}
        id={"secret-replace-form-#{@secret.id}"}
        phx-submit="replace"
        autocomplete="off"
        class="mt-4 space-y-3"
      >
        <input type="hidden" name="secret_id" value={@secret.id} />
        <.input
          field={@replace_form[:value]}
          id={"secret-replace-value-#{@secret.id}"}
          type="password"
          label="New value"
          autocomplete="new-password"
        />
        <div class="flex gap-2">
          <.button id={"secret-replace-submit-#{@secret.id}"} variant="primary">
            Save new value
          </.button>
          <.button
            id={"secret-replace-cancel-#{@secret.id}"}
            variant="ghost"
            type="button"
            phx-click="cancel_replace"
          >
            Cancel
          </.button>
        </div>
      </.form>
    </article>
    """
  end

  attr :confirm, :map, required: true

  defp delete_dialog(assigns) do
    ~H"""
    <.confirm_shell id="secret-delete-confirm" title="Delete this secret?">
      <p class="text-sm text-muted">
        The value cannot be recovered. Workflows that still name it will refuse to activate.
      </p>
      <div class="mt-4 flex justify-end gap-2">
        <.button id="secret-delete-cancel" variant="ghost" type="button" phx-click="cancel_confirm">
          Cancel
        </.button>
        <.button
          id="secret-delete-submit"
          variant="danger"
          type="button"
          phx-click="delete"
          phx-value-id={@confirm.id}
        >
          Delete secret
        </.button>
      </div>
    </.confirm_shell>
    """
  end

  @impl true
  def handle_event("create", %{"secret" => params}, socket) do
    if socket.assigns.can_write do
      attrs = %{
        name: params["name"],
        value: params["value"],
        kind: params["kind"],
        description: params["description"]
      }

      case Connections.create_secret(socket.assigns.scope, attrs) do
        {:ok, _secret} ->
          {:noreply,
           socket
           |> assign(:form, empty_form())
           |> put_flash(:info, "Secret saved. The value will not be shown again.")
           |> push_patch(to: ~p"/secrets")}

        {:error, %Error{} = error} ->
          {:noreply,
           socket
           |> assign(:form, empty_form(Map.put(params, "value", "")))
           |> put_flash(:error, error.message)}
      end
    else
      {:noreply, deny(socket)}
    end
  end

  def handle_event("start_replace", %{"id" => id}, socket) do
    if socket.assigns.can_write do
      {:noreply,
       socket
       |> assign(replacing_id: id, replace_form: replace_form())
       |> restream_secrets()}
    else
      {:noreply, deny(socket)}
    end
  end

  def handle_event("cancel_replace", _params, socket) do
    {:noreply,
     socket
     |> assign(replacing_id: nil, replace_form: replace_form())
     |> restream_secrets()}
  end

  def handle_event("replace", %{"secret_id" => id, "secret" => params}, socket) do
    cond do
      not socket.assigns.can_write ->
        {:noreply, deny(socket)}

      socket.assigns.replacing_id != id ->
        {:noreply, socket}

      true ->
        case Connections.rotate_secret(socket.assigns.scope, id, params["value"] || "") do
          {:ok, _secret} ->
            {:noreply,
             socket
             |> assign(:replacing_id, nil)
             |> assign(:replace_form, replace_form())
             |> put_flash(:info, "Secret value replaced. The new value will not be shown again.")
             |> reload()}

          {:error, %Error{} = error} ->
            {:noreply,
             socket
             |> assign(:replace_form, replace_form())
             |> put_flash(:error, error.message)
             |> restream_secrets()}
        end
    end
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    if socket.assigns.can_write do
      {:noreply, assign(socket, :confirm, %{id: id})}
    else
      {:noreply, deny(socket)}
    end
  end

  def handle_event("cancel_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm, nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    cond do
      not socket.assigns.can_write ->
        {:noreply, deny(socket)}

      not match?(%{id: ^id}, socket.assigns.confirm) ->
        {:noreply, socket}

      true ->
        case Connections.delete_secret(socket.assigns.scope, id) do
          {:ok, _secret} ->
            {:noreply,
             socket
             |> assign(:confirm, nil)
             |> put_flash(:info, "Secret deleted.")
             |> reload()}

          {:error, %Error{} = error} ->
            {:noreply, socket |> assign(:confirm, nil) |> put_flash(:error, error.message)}
        end
    end
  end

  defp reload(socket) do
    scope = socket.assigns.scope

    case Connections.list_secrets(scope) do
      {:ok, secrets} ->
        usage =
          case Connections.usage_index(scope) do
            {:ok, index} -> index.secrets
            {:error, %Error{}} -> %{}
          end

        socket
        |> assign(:entries, secrets)
        |> assign(:usage, usage)
        |> assign(:can_read, true)
        |> stream(:secrets, secrets, reset: true, dom_id: &"secret-#{&1.id}")

      {:error, %Error{class: :permission}} ->
        socket
        |> assign(:entries, [])
        |> assign(:can_read, false)
        |> stream(:secrets, [], reset: true)

      {:error, %Error{} = error} ->
        socket
        |> assign(:entries, [])
        |> put_flash(:error, error.message)
        |> stream(:secrets, [], reset: true)
    end
  end

  defp empty_form(params \\ %{}) do
    params
    |> Map.merge(%{"name" => "", "value" => "", "kind" => "generic", "description" => ""}, fn
      _key, left, _right when is_binary(left) and left != "" -> left
      _key, _left, right -> right
    end)
    |> Map.put("value", "")
    |> to_form(as: :secret)
  end

  defp replace_form do
    to_form(%{"value" => ""}, as: :secret)
  end

  defp restream_secrets(socket) do
    stream(socket, :secrets, socket.assigns.entries, reset: true, dom_id: &"secret-#{&1.id}")
  end

  defp kind_options do
    Enum.map(Secret.kinds(), &{String.replace(&1, "_", " "), &1})
  end

  defp deny(socket) do
    put_flash(socket, :error, "You do not have permission to do that.")
  end
end
