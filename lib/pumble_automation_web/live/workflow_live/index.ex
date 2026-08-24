defmodule PumbleAutomationWeb.WorkflowLive.Index do
  @moduledoc """
  Tenant-scoped workflow list, creation, duplication, and lifecycle controls.
  """
  use PumbleAutomationWeb, :live_view

  import PumbleAutomationWeb.WorkflowComponents

  alias PumbleAutomation.Error
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.StarterTemplates

  @page_size 20
  @statuses ~w(draft active inactive archived)

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.scope

    {:ok,
     socket
     |> assign(:page_title, "Workflows")
     |> assign(:nav_current, :workflows)
     |> assign(:confirm, nil)
     |> assign(:templates, StarterTemplates.catalog())
     |> assign(:form, create_form())
     |> assign(:can_manage, Policy.can?(scope, :manage_workflows))
     |> assign(:can_activate, Policy.can?(scope, :activate_workflows))
     |> assign(:can_delete, Policy.can?(scope, :destructive_lifecycle))
     |> assign(:entries, [])
     |> stream(:workflows, [], dom_id: &"workflow-#{&1.id}")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = apply_list(socket, params)

    {:noreply,
     if socket.assigns.live_action == :new and not socket.assigns.can_manage do
       socket
       |> put_flash(:error, "You do not have permission to do that.")
       |> push_patch(to: ~p"/workflows")
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
      <div id="workflow-index">
        <.header>
          Workflows
          <:subtitle>Create, find, and control drafts in this workspace.</:subtitle>
          <:actions>
            <.button
              :if={@can_manage}
              id="create-workflow-action"
              variant="primary"
              patch={~p"/workflows/new"}
            >
              Create workflow
            </.button>
          </:actions>
        </.header>

        <.filter_bar form={@filter_form} />

        <.empty_state
          :if={@total == 0 and not @filtered?}
          id="workflows-empty"
          title="No workflows yet"
        >
          Create a draft to start routing Pumble events, schedules, and approvals.
          <:action>
            <.button
              :if={@can_manage}
              id="first-workflow-action"
              variant="primary"
              patch={~p"/workflows/new"}
            >
              Create a workflow
            </.button>
            <p :if={!@can_manage} id="workflows-viewer-note" class="text-sm text-muted">
              An editor or owner can create the first workflow.
            </p>
          </:action>
        </.empty_state>

        <.empty_state
          :if={@total == 0 and @filtered?}
          id="workflows-no-matches"
          title="No workflows match"
        >
          Try a different search or status filter.
        </.empty_state>

        <div :if={@total > 0} id="workflow-list" phx-update="stream" class="space-y-4">
          <.workflow_card
            :for={{id, workflow} <- @streams.workflows}
            id={id}
            workflow={workflow}
            can_manage={@can_manage}
            can_activate={@can_activate}
            can_delete={@can_delete}
          />
        </div>

        <nav
          :if={@total > @page_size}
          id="workflow-pagination"
          class="mt-6 flex flex-wrap items-center justify-between gap-2"
          aria-label="Pagination"
        >
          <.button
            :if={@page > 1}
            id="pagination-prev"
            variant="secondary"
            patch={page_path(@filter_q, @filter_status, @page - 1)}
          >
            Previous
          </.button>
          <span id="pagination-status" class="text-sm text-muted">
            Page {@page} of {page_count(@total, @page_size)}
          </span>
          <.button
            :if={@page < page_count(@total, @page_size)}
            id="pagination-next"
            variant="secondary"
            patch={page_path(@filter_q, @filter_status, @page + 1)}
          >
            Next
          </.button>
        </nav>
      </div>

      <.create_modal :if={@can_manage and @live_action == :new} form={@form} templates={@templates} />
      <.confirm_dialog :if={@confirm} confirm={@confirm} />
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("filter", %{"filter" => params}, socket) do
    {:noreply, push_patch(socket, to: page_path(params["q"], params["status"], 1))}
  end

  def handle_event("validate", %{"workflow" => params}, socket) do
    case require_cap(socket, :manage_workflows) do
      :ok -> {:noreply, assign(socket, :form, create_form(params))}
      {:error, %Error{} = error} -> {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("create", %{"workflow" => params}, socket) do
    socket = assign(socket, :form, create_form(params))

    with :ok <- require_cap(socket, :manage_workflows),
         {:ok, definition} <- StarterTemplates.fetch(params["template"] || "blank"),
         {:ok, workflow} <-
           Workflows.create_workflow(socket.assigns.scope, %{
             name: params["name"],
             slug: params["slug"],
             description: params["description"],
             definition: definition
           }) do
      {:noreply,
       socket
       |> assign(:form, create_form())
       |> put_flash(:info, "Created #{workflow.name}.")
       |> push_patch(to: ~p"/workflows")}
    else
      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("duplicate", %{"id" => id}, socket) do
    with :ok <- require_cap(socket, :manage_workflows),
         {:ok, copy} <- Workflows.duplicate_workflow(socket.assigns.scope, id) do
      {:noreply,
       socket
       |> put_flash(:info, "Created #{copy.name}.")
       |> reload_list()}
    else
      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("confirm_deactivate", %{"id" => id}, socket) do
    case require_cap(socket, :activate_workflows) do
      :ok -> {:noreply, assign(socket, :confirm, confirm_payload(socket, :deactivate, id))}
      {:error, %Error{} = error} -> {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    case require_cap(socket, :destructive_lifecycle) do
      :ok -> {:noreply, assign(socket, :confirm, confirm_payload(socket, :delete, id))}
      {:error, %Error{} = error} -> {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("cancel_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm, nil)}
  end

  def handle_event("deactivate", %{"id" => id}, socket) do
    with :ok <- require_confirmed(socket, :deactivate, id),
         :ok <- require_cap(socket, :activate_workflows),
         {:ok, _workflow} <- Workflows.deactivate_workflow(socket.assigns.scope, id) do
      {:noreply,
       socket
       |> assign(:confirm, nil)
       |> put_flash(:info, "Workflow deactivated. In-progress runs may continue.")
       |> reload_list()}
    else
      {:error, :unconfirmed} ->
        {:noreply, socket}

      {:error, %Error{} = error} ->
        {:noreply, socket |> assign(:confirm, nil) |> put_flash(:error, error.message)}
    end
  end

  def handle_event("delete_draft", %{"id" => id}, socket) do
    with :ok <- require_confirmed(socket, :delete, id),
         :ok <- require_cap(socket, :destructive_lifecycle),
         {:ok, _workflow} <- Workflows.delete_draft_workflow(socket.assigns.scope, id) do
      {:noreply,
       socket
       |> assign(:confirm, nil)
       |> put_flash(:info, "Draft deleted.")
       |> reload_list()}
    else
      {:error, :unconfirmed} ->
        {:noreply, socket}

      {:error, %Error{} = error} ->
        {:noreply, socket |> assign(:confirm, nil) |> put_flash(:error, error.message)}
    end
  end

  defp require_confirmed(socket, action, id) do
    case socket.assigns.confirm do
      %{action: ^action, workflow: %{id: ^id}} -> :ok
      _other -> {:error, :unconfirmed}
    end
  end

  defp apply_list(socket, params) do
    page = parse_page(Map.get(params, "page"))
    q = params |> Map.get("q", "") |> to_string() |> String.trim()
    status = permitted_status(Map.get(params, "status"))
    opts = list_opts(q, status, page)

    case Workflows.list_workflow_index(socket.assigns.scope, opts) do
      {:ok, %{entries: entries, total: total}} ->
        socket
        |> assign(:page, page)
        |> assign(:page_size, @page_size)
        |> assign(:filter_q, q)
        |> assign(:filter_status, status)
        |> assign(:filter_form, to_form(%{"q" => q, "status" => status || ""}, as: :filter))
        |> assign(:total, total)
        |> assign(:filtered?, q != "" or is_binary(status))
        |> assign(:entries, entries)
        |> stream(:workflows, entries, reset: true, dom_id: &"workflow-#{&1.id}")

      {:error, %Error{} = error} ->
        socket
        |> assign(:page, 1)
        |> assign(:page_size, @page_size)
        |> assign(:filter_q, q)
        |> assign(:filter_status, status)
        |> assign(:filter_form, to_form(%{"q" => q, "status" => status || ""}, as: :filter))
        |> assign(:total, 0)
        |> assign(:filtered?, false)
        |> assign(:entries, [])
        |> put_flash(:error, error.message)
        |> stream(:workflows, [], reset: true)
    end
  end

  defp reload_list(socket) do
    apply_list(socket, %{
      "q" => socket.assigns.filter_q,
      "status" => socket.assigns.filter_status,
      "page" => Integer.to_string(socket.assigns.page)
    })
  end

  defp list_opts(q, status, page) do
    [
      q: q,
      status: status,
      include_archived: status == "archived",
      limit: @page_size,
      offset: (page - 1) * @page_size
    ]
  end

  defp create_form(params \\ %{}) do
    defaults = %{"name" => "", "slug" => "", "description" => "", "template" => "blank"}
    to_form(Map.merge(defaults, stringify_keys(params)), as: :workflow)
  end

  defp stringify_keys(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end

  defp require_cap(socket, capability) do
    Policy.authorize(socket.assigns.scope, capability)
  end

  defp confirm_payload(socket, action, id) do
    case Enum.find(socket.assigns.entries, &(&1.id == id)) do
      nil -> nil
      workflow -> %{action: action, workflow: workflow}
    end
  end

  defp permitted_status(status) when status in @statuses, do: status
  defp permitted_status(_status), do: nil

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page > 0 -> page
      _other -> 1
    end
  end

  defp parse_page(value) when is_integer(value) and value > 0, do: value
  defp parse_page(_value), do: 1

  defp page_count(total, size) when size > 0 do
    max(1, div(total + size - 1, size))
  end

  defp page_path(q, status, page) do
    params =
      %{}
      |> put_param("q", present(q))
      |> put_param("status", status)
      |> put_param("page", page_param(page))

    if params == %{}, do: ~p"/workflows", else: ~p"/workflows?#{params}"
  end

  defp put_param(params, _key, nil), do: params
  defp put_param(params, key, value), do: Map.put(params, key, value)

  defp present(""), do: nil
  defp present(value) when is_binary(value), do: value
  defp present(_value), do: nil

  defp page_param(page) when is_integer(page) and page > 1, do: Integer.to_string(page)
  defp page_param(_page), do: nil
end
