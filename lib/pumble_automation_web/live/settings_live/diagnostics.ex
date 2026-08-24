defmodule PumbleAutomationWeb.SettingsLive.Diagnostics do
  @moduledoc """
  Owner-only privacy-safe diagnostic export for one execution or time window.
  """
  use PumbleAutomationWeb, :live_view

  alias PumbleAutomation.Diagnostics.Export
  alias PumbleAutomation.Error
  alias PumbleAutomation.Installations.Policy

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.scope
    can_export = Policy.can?(scope, :destructive_lifecycle)

    {:ok,
     socket
     |> assign(:page_title, "Diagnostic export")
     |> assign(:nav_current, :settings)
     |> assign(:can_export, can_export)
     |> assign(:form, export_form(%{}))
     |> assign(:field_names, [])
     |> assign(:bundle_json, nil)
     |> assign(:digest, nil)
     |> assign(:expires_at, nil)
     |> assign(:artifact_id, nil)
     |> assign(:bytes, nil)}
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
      <div id="diagnostics-index" class="space-y-6">
        <.header>
          Diagnostic export
          <:subtitle>
            A bounded support bundle for this workspace. Secrets, tokens, raw bodies,
            and message text are not included.
          </:subtitle>
          <:actions>
            <.button id="diagnostics-settings-link" variant="secondary" navigate={~p"/settings"}>
              Settings
            </.button>
            <.button
              id="diagnostics-operations-link"
              variant="secondary"
              navigate={~p"/settings/operations"}
            >
              Operations
            </.button>
          </:actions>
        </.header>

        <.error_state :if={not @can_export} id="diagnostics-forbidden" title="Not available">
          Only an owner can export diagnostics.
        </.error_state>

        <.card :if={@can_export} id="diagnostics-export-card">
          <:header>Selection</:header>
          <p class="text-sm text-muted">
            Choose one execution id, or both ends of a time window. The export is hashed
            and the stored file expires automatically.
          </p>
          <.form
            for={@form}
            id="diagnostics-form"
            phx-submit="export"
            class="mt-4 grid gap-3 sm:grid-cols-2"
          >
            <.input
              field={@form[:execution_id]}
              type="text"
              label="Execution id"
              class="sm:col-span-2 w-full rounded-md border border-line bg-raised px-3 py-2 font-mono text-sm text-ink"
            />
            <.input field={@form[:from]} type="datetime-local" label="From (UTC)" />
            <.input field={@form[:until]} type="datetime-local" label="Until (UTC)" />
            <div class="sm:col-span-2">
              <.button id="diagnostics-export" variant="primary" type="submit">
                Export diagnostics
              </.button>
            </div>
          </.form>
        </.card>

        <.card :if={@can_export and @bundle_json} id="diagnostics-preview">
          <:header>Included fields</:header>
          <p :if={@digest} id="diagnostics-digest" class="font-mono text-xs text-ink">
            sha256 {@digest}
          </p>
          <p :if={@expires_at} id="diagnostics-expires" class="mt-1 text-xs text-muted">
            Expires {DateTime.to_iso8601(@expires_at)}
            <span :if={@bytes}>· {@bytes} bytes</span>
          </p>
          <ul id="diagnostics-fields" class="mt-3 flex flex-wrap gap-2 text-xs font-mono text-ink">
            <li :for={name <- @field_names}>{name}</li>
          </ul>
          <pre
            id="diagnostics-json"
            class="pa-break mt-3 max-h-80 overflow-auto rounded-md border border-line bg-surface p-3 font-mono text-xs text-ink"
          >{@bundle_json}</pre>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("export", %{"export" => params}, socket) do
    if socket.assigns.can_export do
      opts = [
        execution_id: blank_to_nil(params["execution_id"]),
        from: blank_to_nil(params["from"]),
        until: blank_to_nil(params["until"])
      ]

      case Export.generate(socket.assigns.scope, opts) do
        {:ok, result} ->
          {:noreply,
           socket
           |> assign(:form, export_form(params))
           |> assign(:field_names, result.field_names)
           |> assign(:bundle_json, Jason.encode!(result.bundle, pretty: true))
           |> assign(:digest, result.digest)
           |> assign(:expires_at, result.expires_at)
           |> assign(:artifact_id, result.artifact_id)
           |> assign(:bytes, result.bytes)
           |> put_flash(:info, "Diagnostics exported. Review the included fields.")}

        {:error, %Error{} = error} ->
          {:noreply,
           socket
           |> assign(:form, export_form(params))
           |> put_flash(:error, error.message)}
      end
    else
      {:noreply, deny(socket)}
    end
  end

  defp export_form(params) when is_map(params) do
    to_form(
      %{
        "execution_id" => Map.get(params, "execution_id", ""),
        "from" => Map.get(params, "from", ""),
        "until" => Map.get(params, "until", "")
      },
      as: :export
    )
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp deny(socket) do
    put_flash(socket, :error, "You do not have permission to do that.")
  end
end
