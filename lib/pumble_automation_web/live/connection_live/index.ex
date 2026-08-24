defmodule PumbleAutomationWeb.ConnectionLive.Index do
  @moduledoc """
  HTTP connection administration: CRUD, enabled state, SafeHttp probe, usage.
  """
  use PumbleAutomationWeb, :live_view

  import PumbleAutomationWeb.AdminComponents

  alias PumbleAutomation.Connections
  alias PumbleAutomation.Connections.Connection
  alias PumbleAutomation.Error
  alias PumbleAutomation.Installations.Policy

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.scope

    {:ok,
     socket
     |> assign(:page_title, "Connections")
     |> assign(:nav_current, :connections)
     |> assign(:can_read, Policy.can?(scope, :manage_workflows))
     |> assign(:can_write, Policy.can?(scope, :manage_secrets))
     |> assign(:confirm, nil)
     |> assign(:secrets, [])
     |> assign(:usage, %{})
     |> assign(:outcomes, %{})
     |> assign(:entries, [])
     |> assign(:editing, nil)
     |> assign(:form, to_connection_form(%{}))
     |> assign(:header_rows, empty_header_rows())
     |> assign(:secret_header_rows, empty_secret_header_rows())
     |> stream(:connections, [], dom_id: &"connection-#{&1.id}")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> reload() |> apply_action(socket.assigns.live_action, params)}
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
      <div id="connection-index">
        <.header>
          Connections
          <:subtitle>
            Reusable HTTPS origins, prefixes, and secret-backed headers. Tests use SafeHttp.
          </:subtitle>
          <:actions>
            <.button
              :if={@can_write}
              id="create-connection-action"
              variant="primary"
              patch={~p"/connections/new"}
            >
              Add connection
            </.button>
          </:actions>
        </.header>

        <.error_state :if={not @can_read} id="connections-forbidden" title="Not available">
          You do not have permission to view connections.
        </.error_state>

        <.empty_state
          :if={@can_read and @entries == [] and @live_action == :index}
          id="connections-empty"
          title="No connections yet"
        >
          An HTTP connection names an origin and optional secret headers for workflow requests.
          <:action>
            <.button
              :if={@can_write}
              id="first-connection-action"
              variant="primary"
              patch={~p"/connections/new"}
            >
              Add a connection
            </.button>
          </:action>
        </.empty_state>

        <.connection_form
          :if={@can_write and @live_action in [:new, :edit]}
          form={@form}
          header_rows={@header_rows}
          secret_header_rows={@secret_header_rows}
          secrets={@secrets}
          live_action={@live_action}
        />

        <div :if={@entries != []} id="connection-list" phx-update="stream" class="space-y-4">
          <.connection_card
            :for={{id, connection} <- @streams.connections}
            id={id}
            connection={connection}
            usage={Map.get(@usage, connection.id, %{workflows: []})}
            outcome={Map.get(@outcomes, connection.id)}
            can_write={@can_write}
          />
        </div>

        <.confirm_dialog :if={@confirm} confirm={@confirm} />
      </div>
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :header_rows, :list, required: true
  attr :secret_header_rows, :list, required: true
  attr :secrets, :list, required: true
  attr :live_action, :atom, required: true

  defp connection_form(assigns) do
    ~H"""
    <.card id="connection-form-card">
      <:header>{if @live_action == :edit, do: "Edit connection", else: "New connection"}</:header>
      <.form for={@form} id="connection-form" phx-submit="save" class="space-y-3">
        <.input field={@form[:name]} type="text" label="Name" />
        <.input
          field={@form[:base_origin]}
          type="text"
          label="Base origin"
          placeholder="https://api.example.com"
        />
        <.input
          field={@form[:base_path_prefix]}
          type="text"
          label="Path prefix"
          placeholder="/v1"
        />
        <.input field={@form[:enabled]} type="checkbox" label="Enabled" />

        <fieldset id="connection-headers" class="space-y-2">
          <legend class="text-sm font-medium text-ink">Literal headers</legend>
          <p class="text-xs text-muted">
            Blocked names include host, content-length, and hop-by-hop headers.
            Authorization must be a secret-backed header.
          </p>
          <div :for={{row, index} <- Enum.with_index(@header_rows)} class="grid gap-2 sm:grid-cols-2">
            <.input
              id={"connection-header-name-#{index}"}
              name={"connection[headers][#{index}][name]"}
              value={row["name"]}
              type="text"
              label="Header"
            />
            <.input
              id={"connection-header-value-#{index}"}
              name={"connection[headers][#{index}][value]"}
              value={row["value"]}
              type="text"
              label="Value"
            />
          </div>
          <.button
            id="connection-add-header"
            variant="ghost"
            type="button"
            phx-click="add_header"
          >
            Add header
          </.button>
        </fieldset>

        <fieldset id="connection-secret-headers" class="space-y-2">
          <legend class="text-sm font-medium text-ink">Secret headers</legend>
          <div
            :for={{row, index} <- Enum.with_index(@secret_header_rows)}
            class="grid gap-2 sm:grid-cols-2"
          >
            <.input
              id={"connection-secret-header-name-#{index}"}
              name={"connection[secret_headers][#{index}][header]"}
              value={row["header"]}
              type="text"
              label="Header"
            />
            <.input
              id={"connection-secret-header-secret-#{index}"}
              name={"connection[secret_headers][#{index}][secret_id]"}
              value={row["secret_id"]}
              type="select"
              label="Secret"
              prompt="Select a secret"
              options={secret_options(@secrets)}
            />
          </div>
          <.button
            id="connection-add-secret-header"
            variant="ghost"
            type="button"
            phx-click="add_secret_header"
          >
            Add secret header
          </.button>
        </fieldset>

        <div class="flex gap-2">
          <.button id="connection-save" variant="primary">Save connection</.button>
          <.button id="connection-cancel" variant="ghost" patch={~p"/connections"}>Cancel</.button>
        </div>
      </.form>
    </.card>
    """
  end

  attr :id, :string, required: true
  attr :connection, :map, required: true
  attr :usage, :map, required: true
  attr :outcome, :any, default: nil
  attr :can_write, :boolean, required: true

  defp connection_card(assigns) do
    ~H"""
    <article id={@id} class="rounded-lg border border-line bg-raised p-5">
      <div class="flex min-w-0 items-start justify-between gap-4">
        <div class="min-w-0">
          <h2 class="truncate text-sm font-semibold text-ink">{@connection.name}</h2>
          <p class="mt-1 font-mono text-xs text-muted">{@connection.base_origin}</p>
          <p :if={@connection.base_path_prefix} class="font-mono text-xs text-muted">
            {@connection.base_path_prefix}
          </p>
          <.status_badge
            id={"connection-enabled-#{@connection.id}"}
            tone={if @connection.enabled, do: "ok", else: "neutral"}
            label={if @connection.enabled, do: "Enabled", else: "Disabled"}
          />
          <.usage_note id={"connection-usage-#{@connection.id}"} workflows={@usage.workflows} />
          <p
            :if={@outcome}
            id={"connection-last-outcome-#{@connection.id}"}
            class="mt-2 text-sm text-ink"
          >
            Last test: {@outcome.outcome}
          </p>
        </div>
        <div :if={@can_write} class="flex flex-wrap gap-2">
          <.button
            id={"edit-connection-#{@connection.id}"}
            variant="secondary"
            patch={~p"/connections/#{@connection.id}/edit"}
          >
            Edit
          </.button>
          <.button
            id={"test-connection-#{@connection.id}"}
            variant="secondary"
            type="button"
            phx-click="confirm_test"
            phx-value-id={@connection.id}
          >
            Test
          </.button>
          <.button
            id={"delete-connection-#{@connection.id}"}
            variant="danger"
            type="button"
            phx-click="confirm_delete"
            phx-value-id={@connection.id}
          >
            Delete
          </.button>
        </div>
      </div>
    </article>
    """
  end

  attr :confirm, :map, required: true

  defp confirm_dialog(%{confirm: %{kind: :delete}} = assigns) do
    ~H"""
    <.confirm_shell id="connection-delete-confirm" title="Delete this connection?">
      <p class="text-sm text-muted">Active workflows that name it will refuse to keep running it.</p>
      <div class="mt-4 flex justify-end gap-2">
        <.button
          id="connection-delete-cancel"
          variant="ghost"
          type="button"
          phx-click="cancel_confirm"
        >
          Cancel
        </.button>
        <.button
          id="connection-delete-submit"
          variant="danger"
          type="button"
          phx-click="delete"
          phx-value-id={@confirm.id}
        >
          Delete connection
        </.button>
      </div>
    </.confirm_shell>
    """
  end

  defp confirm_dialog(%{confirm: %{kind: :test}} = assigns) do
    ~H"""
    <.confirm_shell id="connection-test-confirm" title="Send a test request?">
      <p class="text-sm text-muted">
        A GET is sent through SafeHttp to the stored origin. Private, loopback, and
        metadata addresses are blocked. The response body is not stored.
      </p>
      <div class="mt-4 flex justify-end gap-2">
        <.button id="connection-test-cancel" variant="ghost" type="button" phx-click="cancel_confirm">
          Cancel
        </.button>
        <.button
          id="connection-test-submit"
          variant="primary"
          type="button"
          phx-click="test"
          phx-value-id={@confirm.id}
        >
          Send test
        </.button>
      </div>
    </.confirm_shell>
    """
  end

  @impl true
  def handle_event("add_header", _params, socket) do
    if socket.assigns.can_write do
      {:noreply, assign(socket, :header_rows, socket.assigns.header_rows ++ empty_header_rows())}
    else
      {:noreply, socket}
    end
  end

  def handle_event("add_secret_header", _params, socket) do
    if socket.assigns.can_write do
      rows = socket.assigns.secret_header_rows ++ empty_secret_header_rows()
      {:noreply, assign(socket, :secret_header_rows, rows)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save", %{"connection" => params}, socket) do
    if socket.assigns.can_write do
      attrs = connection_attrs(params)

      result =
        case socket.assigns.editing do
          nil -> Connections.create_connection(socket.assigns.scope, attrs)
          id -> Connections.update_connection(socket.assigns.scope, id, attrs)
        end

      case result do
        {:ok, _connection} ->
          {:noreply,
           socket
           |> put_flash(:info, "Connection saved.")
           |> push_patch(to: ~p"/connections")}

        {:error, %Error{} = error} ->
          {:noreply,
           socket
           |> assign(:form, to_connection_form(params))
           |> assign(:header_rows, header_rows_from(params))
           |> assign(:secret_header_rows, secret_header_rows_from(params))
           |> put_flash(:error, error.message)}
      end
    else
      {:noreply, deny(socket)}
    end
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    if socket.assigns.can_write do
      {:noreply, assign(socket, :confirm, %{kind: :delete, id: id})}
    else
      {:noreply, deny(socket)}
    end
  end

  def handle_event("confirm_test", %{"id" => id}, socket) do
    if socket.assigns.can_write do
      {:noreply, assign(socket, :confirm, %{kind: :test, id: id})}
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

      not match?(%{kind: :delete, id: ^id}, socket.assigns.confirm) ->
        {:noreply, socket}

      true ->
        case Connections.delete_connection(socket.assigns.scope, id) do
          {:ok, _connection} ->
            {:noreply,
             socket
             |> assign(:confirm, nil)
             |> put_flash(:info, "Connection deleted.")
             |> reload()}

          {:error, %Error{} = error} ->
            {:noreply, socket |> assign(:confirm, nil) |> put_flash(:error, error.message)}
        end
    end
  end

  def handle_event("test", %{"id" => id}, socket) do
    cond do
      not socket.assigns.can_write ->
        {:noreply, deny(socket)}

      not match?(%{kind: :test, id: ^id}, socket.assigns.confirm) ->
        {:noreply, socket}

      true ->
        finish_test(socket, Connections.test_connection(socket.assigns.scope, id))
    end
  end

  defp finish_test(socket, {:ok, outcome}) do
    {:noreply,
     socket
     |> assign(:confirm, nil)
     |> put_flash(test_flash_kind(outcome.result), outcome.outcome)
     |> reload()}
  end

  defp finish_test(socket, {:error, %Error{} = error}) do
    {:noreply, socket |> assign(:confirm, nil) |> put_flash(:error, error.message)}
  end

  defp test_flash_kind("ok"), do: :info
  defp test_flash_kind(_result), do: :error

  defp apply_action(socket, :new, _params) do
    if socket.assigns.can_write do
      socket
      |> assign(:editing, nil)
      |> assign(:form, to_connection_form(%{"enabled" => "true"}))
      |> assign(:header_rows, empty_header_rows())
      |> assign(:secret_header_rows, empty_secret_header_rows())
    else
      socket
      |> deny()
      |> push_patch(to: ~p"/connections")
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Connections.get_connection(socket.assigns.scope, id) do
      {:ok, connection} ->
        if socket.assigns.can_write do
          socket
          |> assign(:editing, connection.id)
          |> assign(:form, to_connection_form(form_params(connection)))
          |> assign(:header_rows, headers_to_rows(connection.headers))
          |> assign(:secret_header_rows, secret_headers_to_rows(connection.secret_headers))
        else
          deny(socket)
        end

      {:error, %Error{} = error} ->
        socket
        |> put_flash(:error, error.message)
        |> push_patch(to: ~p"/connections")
    end
  end

  defp apply_action(socket, _action, _params), do: socket

  defp reload(socket) do
    case Connections.list_connections(socket.assigns.scope) do
      {:ok, connections} -> assign_listed(socket, connections)
      {:error, %Error{class: :permission}} -> assign_forbidden(socket)
      {:error, %Error{} = error} -> assign_list_error(socket, error)
    end
  end

  defp assign_listed(socket, connections) do
    scope = socket.assigns.scope

    socket
    |> assign(:entries, connections)
    |> assign(:usage, unwrap_usage(scope))
    |> assign(:outcomes, unwrap_outcomes(scope))
    |> assign(:secrets, unwrap_secrets(scope))
    |> assign(:can_read, true)
    |> stream(:connections, connections, reset: true, dom_id: &"connection-#{&1.id}")
  end

  defp assign_forbidden(socket) do
    socket
    |> assign(:entries, [])
    |> assign(:can_read, false)
    |> stream(:connections, [], reset: true)
  end

  defp assign_list_error(socket, %Error{} = error) do
    socket
    |> assign(:entries, [])
    |> put_flash(:error, error.message)
    |> stream(:connections, [], reset: true)
  end

  defp unwrap_usage(scope) do
    case Connections.usage_index(scope) do
      {:ok, index} -> index.connections
      {:error, %Error{}} -> %{}
    end
  end

  defp unwrap_outcomes(scope) do
    case Connections.last_test_outcomes(scope) do
      {:ok, map} -> map
      {:error, %Error{}} -> %{}
    end
  end

  defp unwrap_secrets(scope) do
    case Connections.list_secrets(scope) do
      {:ok, list} -> list
      {:error, %Error{}} -> []
    end
  end

  defp connection_attrs(params) do
    %{
      name: params["name"],
      base_origin: params["base_origin"],
      base_path_prefix: params["base_path_prefix"],
      enabled: params["enabled"],
      headers: parse_headers(params["headers"]),
      secret_headers: parse_secret_headers(params["secret_headers"])
    }
  end

  defp parse_headers(rows) when is_map(rows) do
    rows
    |> Enum.sort_by(fn {key, _row} -> key end)
    |> Enum.reduce(%{}, fn {_key, row}, acc ->
      name = row |> Map.get("name", "") |> to_string() |> String.trim()
      value = row |> Map.get("value", "") |> to_string()

      if name == "" do
        acc
      else
        Map.put(acc, name, value)
      end
    end)
  end

  defp parse_headers(_rows), do: %{}

  defp parse_secret_headers(rows) when is_map(rows) do
    rows
    |> Enum.sort_by(fn {key, _row} -> key end)
    |> Enum.flat_map(fn {_key, row} ->
      header = row |> Map.get("header", "") |> to_string() |> String.trim()
      secret_id = row |> Map.get("secret_id", "") |> to_string()

      if header == "" or secret_id == "" do
        []
      else
        [%{"header" => header, "secret_id" => secret_id}]
      end
    end)
  end

  defp parse_secret_headers(_rows), do: []

  defp form_params(%Connection{} = connection) do
    %{
      "name" => connection.name,
      "base_origin" => connection.base_origin,
      "base_path_prefix" => connection.base_path_prefix || "",
      "enabled" => connection.enabled
    }
  end

  defp to_connection_form(params) when is_map(params) do
    to_form(params, as: :connection)
  end

  defp headers_to_rows(headers) when is_map(headers) do
    rows =
      headers
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {name, value} -> %{"name" => name, "value" => value} end)

    if rows == [], do: empty_header_rows(), else: rows
  end

  defp secret_headers_to_rows(entries) when is_list(entries) do
    rows =
      Enum.map(entries, fn entry ->
        %{"header" => Map.get(entry, "header"), "secret_id" => Map.get(entry, "secret_id")}
      end)

    if rows == [], do: empty_secret_header_rows(), else: rows
  end

  defp header_rows_from(%{"headers" => rows}) when is_map(rows) do
    rows
    |> Enum.sort_by(fn {key, _row} -> key end)
    |> Enum.map(fn {_key, row} ->
      %{"name" => Map.get(row, "name", ""), "value" => Map.get(row, "value", "")}
    end)
    |> case do
      [] -> empty_header_rows()
      list -> list
    end
  end

  defp header_rows_from(_params), do: empty_header_rows()

  defp secret_header_rows_from(%{"secret_headers" => rows}) when is_map(rows) do
    rows
    |> Enum.sort_by(fn {key, _row} -> key end)
    |> Enum.map(fn {_key, row} ->
      %{"header" => Map.get(row, "header", ""), "secret_id" => Map.get(row, "secret_id", "")}
    end)
    |> case do
      [] -> empty_secret_header_rows()
      list -> list
    end
  end

  defp secret_header_rows_from(_params), do: empty_secret_header_rows()

  defp empty_header_rows, do: [%{"name" => "", "value" => ""}]
  defp empty_secret_header_rows, do: [%{"header" => "", "secret_id" => ""}]

  defp secret_options(secrets) do
    Enum.map(secrets, fn secret -> {secret.name, secret.id} end)
  end

  defp deny(socket) do
    put_flash(socket, :error, "You do not have permission to do that.")
  end
end
