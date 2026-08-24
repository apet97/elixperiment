defmodule PumbleAutomationWeb.ExecutionLive.Index do
  @moduledoc """
  Tenant-scoped execution history with workflow, status, and time filters.
  """
  use PumbleAutomationWeb, :live_view

  import PumbleAutomationWeb.ExecutionComponents

  alias PumbleAutomation.Error
  alias PumbleAutomation.Executions.History

  @impl true
  def mount(_params, _session, socket) do
    workflows =
      case History.list_workflow_options(socket.assigns.scope) do
        {:ok, options} -> options
        {:error, %Error{}} -> []
      end

    {:ok,
     socket
     |> assign(:page_title, "Executions")
     |> assign(:nav_current, :executions)
     |> assign(:workflows, workflows)
     |> stream(:executions, [], dom_id: &"execution-#{&1.id}")}
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
      <div id="execution-index">
        <.header>
          Executions
          <:subtitle>Search sanitized run history without opening private payloads.</:subtitle>
        </.header>

        <.filter_bar form={@filter_form} workflows={@workflows} />

        <.empty_state
          :if={@entries == [] and not @filtered?}
          id="executions-empty"
          title="No executions yet"
        >
          Runs appear here after a live workflow starts. Dry-run previews are not stored.
        </.empty_state>

        <.empty_state
          :if={@entries == [] and @filtered?}
          id="executions-no-matches"
          title="No executions match"
        >
          Try a different workflow, status, or time range.
        </.empty_state>

        <div :if={@entries != []} id="execution-list" phx-update="stream" class="space-y-4">
          <.execution_card
            :for={{id, execution} <- @streams.executions}
            id={id}
            execution={execution}
          />
        </div>

        <nav
          :if={@next_cursor || @cursor}
          id="execution-pagination"
          class="mt-6 flex flex-wrap items-center justify-between gap-2"
          aria-label="Pagination"
        >
          <.button
            :if={@cursor}
            id="pagination-newest"
            variant="secondary"
            patch={page_path(@filters, nil)}
          >
            Newest
          </.button>
          <span id="pagination-status" class="text-sm text-muted">Newest first</span>
          <.button
            :if={@next_cursor}
            id="pagination-next"
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

  @impl true
  def handle_event("filter", %{"filter" => params}, socket) do
    {:noreply, push_patch(socket, to: page_path(normalize_filters(params), nil))}
  end

  defp apply_list(socket, params) do
    filters = normalize_filters(params)
    opts = list_opts(filters)

    case History.list_index(socket.assigns.scope, opts) do
      {:ok, %{entries: entries, next_cursor: next_cursor}} ->
        socket
        |> assign(:filters, filters)
        |> assign(:cursor, filters.cursor)
        |> assign(:next_cursor, next_cursor)
        |> assign(:filter_form, filter_form(filters))
        |> assign(:filtered?, filtered?(filters))
        |> assign(:entries, entries)
        |> stream(:executions, entries, reset: true, dom_id: &"execution-#{&1.id}")

      {:error, %Error{} = error} ->
        socket
        |> assign(:filters, filters)
        |> assign(:cursor, nil)
        |> assign(:next_cursor, nil)
        |> assign(:filter_form, filter_form(filters))
        |> assign(:filtered?, false)
        |> assign(:entries, [])
        |> put_flash(:error, error.message)
        |> stream(:executions, [], reset: true)
    end
  end

  defp list_opts(filters) do
    [
      workflow_id: present(filters.workflow_id),
      status: present(filters.status),
      from: present(filters.from),
      until: present(filters.until),
      cursor: present(filters.cursor),
      limit: History.page_size()
    ]
  end

  defp normalize_filters(params) do
    %{
      workflow_id: params |> Map.get("workflow_id", "") |> to_string() |> String.trim(),
      status: params |> Map.get("status", "") |> to_string() |> String.trim(),
      from: params |> Map.get("from", "") |> to_string() |> String.trim(),
      until: params |> Map.get("until", "") |> to_string() |> String.trim(),
      cursor: params |> Map.get("cursor", "") |> to_string() |> String.trim()
    }
  end

  defp filter_form(filters) do
    to_form(
      %{
        "workflow_id" => filters.workflow_id,
        "status" => filters.status,
        "from" => filters.from,
        "until" => filters.until
      },
      as: :filter
    )
  end

  defp filtered?(filters) do
    Enum.any?([filters.workflow_id, filters.status, filters.from, filters.until], &(&1 != ""))
  end

  defp page_path(filters, cursor) do
    params =
      %{}
      |> put_param("workflow_id", present(filters.workflow_id))
      |> put_param("status", present(filters.status))
      |> put_param("from", present(filters.from))
      |> put_param("until", present(filters.until))
      |> put_param("cursor", present(cursor))

    if params == %{}, do: ~p"/executions", else: ~p"/executions?#{params}"
  end

  defp put_param(params, _key, nil), do: params
  defp put_param(params, key, value), do: Map.put(params, key, value)

  defp present(""), do: nil
  defp present(nil), do: nil
  defp present(value), do: value
end
