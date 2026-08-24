defmodule PumbleAutomationWeb.AuditLive.Index do
  @moduledoc """
  Append-only audit history with safe metadata, filters, and cursor pagination.
  """
  use PumbleAutomationWeb, :live_view

  import PumbleAutomationWeb.AdminComponents

  alias PumbleAutomation.Audit
  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Error
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Operations

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.scope

    {:ok,
     socket
     |> assign(:page_title, "Audit")
     |> assign(:nav_current, :audit)
     |> assign(:can_read, Policy.can?(scope, :read_workflows))
     |> assign(:can_support, Policy.can?(scope, :destructive_lifecycle))
     |> assign(:support_form, support_form(""))
     |> assign(:diagnostics, nil)
     |> assign(:diagnostics_json, nil)
     |> assign(:diagnostics_fields, [])
     |> assign(:confirm, nil)
     |> assign(:entries, [])
     |> stream(:events, [], dom_id: &"audit-#{&1.id}")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_list(socket, params)}
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
      <div id="audit-index">
        <.header>
          Audit
          <:subtitle>
            Security-relevant events for this workspace. Records cannot be edited.
          </:subtitle>
        </.header>

        <.error_state :if={not @can_read} id="audit-forbidden" title="Not available">
          You do not have permission to view audit history.
        </.error_state>

        <.filter_bar :if={@can_read} form={@filter_form} />

        <.support_panel
          :if={@can_support}
          form={@support_form}
          diagnostics_fields={@diagnostics_fields}
          diagnostics_json={@diagnostics_json}
          confirm={@confirm}
        />

        <.empty_state
          :if={@can_read and @entries == [] and not @filtered?}
          id="audit-empty"
          title="No audit events yet"
        >
          Installs, role changes, secrets, activations, and operator actions appear here.
        </.empty_state>

        <.empty_state
          :if={@can_read and @entries == [] and @filtered?}
          id="audit-no-matches"
          title="No events match"
        >
          Try a different action, actor, resource, or time range.
        </.empty_state>

        <div :if={@entries != []} id="audit-list" phx-update="stream" class="space-y-3">
          <.event_card :for={{id, event} <- @streams.events} id={id} event={event} />
        </div>

        <nav
          :if={@next_cursor || @cursor}
          id="audit-pagination"
          class="mt-6 flex flex-wrap items-center justify-between gap-2"
          aria-label="Pagination"
        >
          <.button
            :if={@cursor}
            id="audit-pagination-newest"
            variant="secondary"
            patch={page_path(@filters, nil)}
          >
            Newest
          </.button>
          <span id="audit-pagination-status" class="text-sm text-muted">Newest first</span>
          <.button
            :if={@next_cursor}
            id="audit-pagination-next"
            variant="secondary"
            patch={page_path(@filters, @next_cursor)}
          >
            Older
          </.button>
        </nav>
      </div>
    </Layouts.app>
    """
  end

  attr :form, :any, required: true

  defp filter_bar(assigns) do
    ~H"""
    <.form
      for={@form}
      id="audit-filter-form"
      phx-change="filter"
      phx-submit="filter"
      class="mb-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4"
    >
      <.input field={@form[:action]} type="text" label="Action" placeholder="secret.created" />
      <.input field={@form[:actor_id]} type="text" label="Actor" />
      <.input field={@form[:resource_type]} type="text" label="Resource" placeholder="secret" />
      <.input field={@form[:from]} type="datetime-local" label="From" />
    </.form>
    """
  end

  attr :form, :any, required: true
  attr :diagnostics_fields, :list, required: true
  attr :diagnostics_json, :any, default: nil
  attr :confirm, :any, default: nil

  defp support_panel(assigns) do
    ~H"""
    <.card id="audit-support" class="mb-6">
      <:header>Protected support</:header>
      <p class="text-sm text-muted">
        Owner-only repairs for this workspace. There is no SQL console and no global admin.
        Unsafe jobs are refused with an instruction instead of being retried.
      </p>

      <.form
        for={@form}
        id="audit-requeue-form"
        phx-submit="requeue"
        class="mt-4 flex flex-wrap items-end gap-3"
      >
        <.input field={@form[:job_id]} type="text" label="Discarded job id" />
        <.button id="audit-requeue" variant="secondary" type="submit">Requeue safe job</.button>
      </.form>

      <div class="mt-4 flex flex-wrap gap-2">
        <.button id="audit-reconcile" variant="secondary" type="button" phx-click="reconcile">
          Run reconciliation
        </.button>
        <.button id="audit-export" variant="secondary" type="button" phx-click="export_diagnostics">
          Export diagnostics
        </.button>
        <.button id="audit-delete-tenant" variant="danger" type="button" phx-click="confirm_delete">
          Delete workspace data
        </.button>
      </div>

      <div :if={@diagnostics_json} id="audit-diagnostics" class="mt-4">
        <p class="text-xs uppercase tracking-wide text-muted">Included fields</p>
        <ul id="audit-diagnostics-fields" class="mt-1 flex flex-wrap gap-2 text-xs font-mono text-ink">
          <li :for={name <- @diagnostics_fields}>{name}</li>
        </ul>
        <pre
          id="audit-diagnostics-json"
          class="pa-break mt-3 max-h-80 overflow-auto rounded-md border border-line bg-surface p-3 font-mono text-xs text-ink"
        >{@diagnostics_json}</pre>
      </div>
    </.card>

    <.confirm_shell
      :if={@confirm == :delete}
      id="audit-delete-confirm"
      title="Delete this workspace data?"
    >
      <p class="text-sm text-muted">
        Credentials become unusable immediately. Remaining workflow data is kept for the
        retention window, then erased. This cannot be undone from the application.
      </p>
      <div class="mt-4 flex justify-end gap-2">
        <.button id="audit-delete-cancel" variant="ghost" type="button" phx-click="cancel_confirm">
          Cancel
        </.button>
        <.button id="audit-delete-submit" variant="danger" type="button" phx-click="delete_tenant">
          Delete workspace data
        </.button>
      </div>
    </.confirm_shell>
    """
  end

  attr :id, :string, required: true
  attr :event, :map, required: true

  defp event_card(assigns) do
    ~H"""
    <article
      id={@id}
      data-action={@event.action}
      class="rounded-lg border border-line bg-raised px-4 py-3"
    >
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <p class="font-mono text-sm font-semibold text-ink">{@event.action}</p>
        <time class="text-xs text-muted">{DateTime.to_iso8601(@event.inserted_at)}</time>
      </div>
      <p class="mt-1 text-xs text-muted">
        {@event.actor_type}
        <span :if={@event.actor_id}>· {@event.actor_id}</span>
        <span :if={@event.resource_type}>· {@event.resource_type}</span>
      </p>
      <dl
        :if={metadata_pairs(@event) != []}
        id={"audit-metadata-#{@event.id}"}
        class="mt-2 grid gap-1 sm:grid-cols-2"
      >
        <div :for={{key, value} <- metadata_pairs(@event)}>
          <dt class="text-xs uppercase tracking-wide text-muted">{key}</dt>
          <dd class="pa-break font-mono text-xs text-ink">{value}</dd>
        </div>
      </dl>
    </article>
    """
  end

  @impl true
  def handle_event("filter", %{"filter" => params}, socket) do
    {:noreply, push_patch(socket, to: page_path(normalize_filters(params), nil))}
  end

  def handle_event("requeue", %{"support" => params}, socket) do
    job_id = params |> Map.get("job_id", "") |> to_string() |> String.trim()

    if socket.assigns.can_support do
      case Operations.requeue_safe_job(socket.assigns.scope, job_id) do
        {:ok, _job} ->
          {:noreply,
           socket
           |> assign(:support_form, support_form(""))
           |> put_flash(:info, "The job was requeued.")
           |> reload_events()}

        {:error, %Error{} = error} ->
          {:noreply, put_flash(socket, :error, error.message)}
      end
    else
      {:noreply, deny(socket)}
    end
  end

  def handle_event("reconcile", _params, socket) do
    if socket.assigns.can_support do
      case Operations.run_reconciliation(socket.assigns.scope) do
        {:ok, result} ->
          {:noreply,
           socket
           |> put_flash(:info, "Reconciliation finished (#{result.count} repairs).")
           |> reload_events()}

        {:error, %Error{} = error} ->
          {:noreply, put_flash(socket, :error, error.message)}
      end
    else
      {:noreply, deny(socket)}
    end
  end

  def handle_event("export_diagnostics", _params, socket) do
    if socket.assigns.can_support do
      case Operations.export_diagnostics(socket.assigns.scope) do
        {:ok, bundle} ->
          {:noreply,
           socket
           |> assign(:diagnostics, bundle)
           |> assign(:diagnostics_fields, bundle_fields(bundle))
           |> assign(:diagnostics_json, Jason.encode!(bundle, pretty: true))
           |> put_flash(:info, "Diagnostics exported. Review the included fields.")
           |> reload_events()}

        {:error, %Error{} = error} ->
          {:noreply, put_flash(socket, :error, error.message)}
      end
    else
      {:noreply, deny(socket)}
    end
  end

  def handle_event("confirm_delete", _params, socket) do
    if socket.assigns.can_support do
      {:noreply, assign(socket, :confirm, :delete)}
    else
      {:noreply, deny(socket)}
    end
  end

  def handle_event("cancel_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm, nil)}
  end

  def handle_event("delete_tenant", _params, socket) do
    cond do
      not socket.assigns.can_support ->
        {:noreply, deny(socket)}

      socket.assigns.confirm != :delete ->
        {:noreply, socket}

      true ->
        case Operations.initiate_tenant_deletion(socket.assigns.scope) do
          {:ok, %{scheduled_at: scheduled_at}} ->
            {:noreply,
             socket
             |> assign(:confirm, nil)
             |> put_flash(:info, deletion_flash(scheduled_at))}

          {:error, %Error{} = error} ->
            {:noreply, socket |> assign(:confirm, nil) |> put_flash(:error, error.message)}
        end
    end
  end

  defp apply_list(socket, params) do
    filters = normalize_filters(params)

    case Audit.list(socket.assigns.scope, list_opts(filters)) do
      {:ok, %{entries: entries, next_cursor: next_cursor}} ->
        socket
        |> assign(:filters, filters)
        |> assign(:cursor, filters.cursor)
        |> assign(:next_cursor, next_cursor)
        |> assign(:filter_form, filter_form(filters))
        |> assign(:filtered?, filtered?(filters))
        |> assign(:entries, entries)
        |> assign(:can_read, true)
        |> stream(:events, entries, reset: true, dom_id: &"audit-#{&1.id}")

      {:error, %Error{class: :permission}} ->
        socket
        |> assign(:filters, filters)
        |> assign(:cursor, nil)
        |> assign(:next_cursor, nil)
        |> assign(:filter_form, filter_form(filters))
        |> assign(:filtered?, false)
        |> assign(:entries, [])
        |> assign(:can_read, false)
        |> stream(:events, [], reset: true)

      {:error, %Error{} = error} ->
        socket
        |> assign(:filters, filters)
        |> assign(:cursor, nil)
        |> assign(:next_cursor, nil)
        |> assign(:filter_form, filter_form(filters))
        |> assign(:filtered?, false)
        |> assign(:entries, [])
        |> put_flash(:error, error.message)
        |> stream(:events, [], reset: true)
    end
  end

  defp list_opts(filters) do
    [
      action: present(filters.action),
      actor_id: present(filters.actor_id),
      resource_type: present(filters.resource_type),
      from: present(filters.from),
      cursor: present(filters.cursor),
      limit: Audit.page_size()
    ]
  end

  defp normalize_filters(params) do
    %{
      action: params |> Map.get("action", "") |> to_string() |> String.trim(),
      actor_id: params |> Map.get("actor_id", "") |> to_string() |> String.trim(),
      resource_type: params |> Map.get("resource_type", "") |> to_string() |> String.trim(),
      from: params |> Map.get("from", "") |> to_string() |> String.trim(),
      cursor: params |> Map.get("cursor", "") |> to_string() |> String.trim()
    }
  end

  defp filter_form(filters) do
    to_form(
      %{
        "action" => filters.action,
        "actor_id" => filters.actor_id,
        "resource_type" => filters.resource_type,
        "from" => filters.from
      },
      as: :filter
    )
  end

  defp filtered?(filters) do
    filters.action != "" or filters.actor_id != "" or filters.resource_type != "" or
      filters.from != ""
  end

  defp page_path(filters, cursor) do
    query =
      filters
      |> Map.put(:cursor, cursor)
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    ~p"/audit?#{query}"
  end

  defp metadata_pairs(%AuditEvent{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Enum.reject(fn {key, _value} -> AuditEvent.denied_key?(to_string(key)) end)
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp metadata_pairs(_event), do: []

  defp stringify(value) when is_binary(value), do: value

  defp stringify(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: to_string(value)

  defp stringify(_value), do: ""

  defp present(""), do: nil
  defp present(value), do: value

  defp support_form(job_id) do
    to_form(%{"job_id" => job_id}, as: :support)
  end

  defp reload_events(socket) do
    apply_list(socket, %{
      "action" => socket.assigns.filters.action,
      "actor_id" => socket.assigns.filters.actor_id,
      "resource_type" => socket.assigns.filters.resource_type,
      "from" => socket.assigns.filters.from,
      "cursor" => socket.assigns.filters.cursor
    })
  end

  defp bundle_fields(bundle) when is_map(bundle) do
    bundle |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
  end

  defp deletion_flash(%DateTime{} = scheduled_at) do
    "Workspace deletion is scheduled for #{DateTime.to_iso8601(scheduled_at)}."
  end

  defp deletion_flash(_scheduled_at), do: "Workspace deletion is scheduled."

  defp deny(socket) do
    put_flash(socket, :error, "You do not have permission to do that.")
  end
end
