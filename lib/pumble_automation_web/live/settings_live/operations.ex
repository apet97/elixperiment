defmodule PumbleAutomationWeb.SettingsLive.Operations do
  @moduledoc """
  Owner-only queue, schedule, and readiness diagnostics for this workspace.
  """
  use PumbleAutomationWeb, :live_view

  alias PumbleAutomation.Error
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Operations.Health

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.scope
    can_view = Policy.can?(scope, :destructive_lifecycle)

    {:ok,
     socket
     |> assign(:page_title, "Operations")
     |> assign(:nav_current, :settings)
     |> assign(:can_view, can_view)
     |> assign(:report, nil)
     |> load_report()}
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
      <div id="operations-health" class="space-y-6">
        <.header>
          Queue and readiness
          <:subtitle>
            Whether this node can accept durable work, and what is waiting in this workspace.
          </:subtitle>
          <:actions>
            <.button id="operations-settings-link" variant="secondary" navigate={~p"/settings"}>
              Settings
            </.button>
            <.button
              :if={@can_view}
              id="operations-refresh"
              variant="secondary"
              type="button"
              phx-click="refresh"
            >
              Refresh
            </.button>
          </:actions>
        </.header>

        <.error_state :if={not @can_view} id="operations-forbidden" title="Not available">
          Only an owner can view queue and readiness diagnostics.
        </.error_state>

        <%= if @can_view and @report do %>
          <.summary_card report={@report} />
          <.checks_card report={@report} />
          <.samples_card report={@report} />
          <.alerts_card report={@report} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :report, :map, required: true

  defp summary_card(assigns) do
    ~H"""
    <.card id="operations-summary">
      <:header>This node</:header>
      <div class="flex flex-wrap items-center gap-3">
        <.status_badge
          id="operations-overall"
          tone={tone(@report.status)}
          label={"Diagnostics #{status_label(@report.status)}"}
        />
        <.status_badge
          id="operations-ready"
          tone={if(@report.ready?, do: "ok", else: "danger")}
          label={if(@report.ready?, do: "Durable work ready", else: "Durable work not ready")}
        />
      </div>
      <p class="mt-3 text-sm text-muted">
        Public liveness only proves the process is up. Readiness fails when the database,
        schema, or job runtime cannot accept work — not when a single job is late.
      </p>
    </.card>
    """
  end

  attr :report, :map, required: true

  defp checks_card(assigns) do
    ~H"""
    <.card id="operations-checks">
      <:header>Checks</:header>
      <.list>
        <:item :for={check <- @report.checks} title={check_title(check.name)}>
          <span id={"check-#{check.name}"} class="inline-flex flex-wrap items-center gap-2">
            <.status_badge
              id={"check-#{check.name}-status"}
              tone={tone(check.status)}
              label={status_label(check.status)}
            />
            <span :if={check.value} class="font-mono text-xs text-ink">
              {format_value(check)}
            </span>
          </span>
        </:item>
      </.list>
    </.card>
    """
  end

  attr :report, :map, required: true

  defp samples_card(assigns) do
    samples = Enum.flat_map(assigns.report.checks, & &1.samples)
    assigns = assign(assigns, :samples, samples)

    ~H"""
    <.card id="operations-samples">
      <:header>Affected work</:header>
      <p :if={@samples == []} id="operations-samples-empty" class="text-sm text-muted">
        No affected executions in this workspace.
      </p>
      <ul :if={@samples != []} id="operations-sample-list" class="space-y-2 text-sm">
        <li :for={sample <- @samples} id={sample_dom_id(sample)}>
          <.sample_link sample={sample} />
        </li>
      </ul>
    </.card>
    """
  end

  attr :sample, :map, required: true

  defp sample_link(%{sample: %{kind: :execution, id: id}} = assigns) do
    assigns = assign(assigns, :id, id)

    ~H"""
    <.link
      id={"affected-execution-#{@id}"}
      navigate={~p"/executions/#{@id}"}
      class="font-mono text-xs text-signal hover:underline"
    >
      Execution {@id}
    </.link>
    """
  end

  defp sample_link(%{sample: %{kind: :job} = sample} = assigns) do
    assigns = assign(assigns, :sample, sample)

    ~H"""
    <span class="font-mono text-xs text-ink">
      Job {@sample.id}
      <.link
        :if={@sample.execution_id}
        id={"affected-job-execution-#{@sample.execution_id}"}
        navigate={~p"/executions/#{@sample.execution_id}"}
        class="ml-2 text-signal hover:underline"
      >
        Execution {@sample.execution_id}
      </.link>
    </span>
    """
  end

  defp sample_link(%{sample: %{kind: :schedule} = sample} = assigns) do
    assigns = assign(assigns, :sample, sample)

    ~H"""
    <.link
      id={"affected-schedule-#{@sample.id}"}
      navigate={~p"/workflows/#{@sample.workflow_id}"}
      class="font-mono text-xs text-signal hover:underline"
    >
      Schedule {@sample.id}
    </.link>
    """
  end

  defp sample_link(assigns) do
    ~H"""
    <span class="font-mono text-xs text-muted">Unknown sample</span>
    """
  end

  attr :report, :map, required: true

  defp alerts_card(assigns) do
    ~H"""
    <.card id="operations-alerts">
      <:header>Alert recommendations</:header>
      <ul id="operations-alert-list" class="list-disc space-y-2 pl-5 text-sm text-ink">
        <li>
          Database ping at or above {format_ms(@report.alert_thresholds.database_latency_ms)}.
          Readiness fails at {format_ms(@report.readiness_thresholds.database_latency_ms)},
          or when the database is down.
        </li>
        <li>
          Oldest available job older than {format_ms(@report.alert_thresholds.oldest_available_job_ms)}. A single late job is not a ready failure; a backlog older than {format_ms(
            @report.readiness_thresholds.oldest_available_job_ms
          )} is stuck work.
        </li>
        <li>
          Any discarded (exhausted) job. Investigate; do not retry from SQL.
        </li>
        <li>
          Due-schedule lag above {format_ms(@report.alert_thresholds.schedule_lag_ms)} (dispatcher runs every minute).
        </li>
        <li>
          Any stale attempt (started longer than 30 minutes) or missing advance job
          that is not occupancy-parked.
        </li>
        <li>
          Retention sweep lag above {format_ms(@report.alert_thresholds.cleanup_lag_ms)} once maintenance is scheduled.
        </li>
      </ul>
    </.card>
    """
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    if socket.assigns.can_view do
      {:noreply, load_report(socket)}
    else
      {:noreply, socket}
    end
  end

  defp load_report(socket) do
    if socket.assigns.can_view do
      case Health.diagnostics(socket.assigns.scope) do
        {:ok, report} ->
          assign(socket, :report, report)

        {:error, %Error{} = error} ->
          socket
          |> assign(:report, nil)
          |> put_flash(:error, error.message)
      end
    else
      assign(socket, :report, nil)
    end
  end

  defp tone(:ok), do: "ok"
  defp tone(:degraded), do: "warn"
  defp tone(:unhealthy), do: "danger"
  defp tone(:unknown), do: "neutral"
  defp tone(_other), do: "neutral"

  defp status_label(:ok), do: "ok"
  defp status_label(:degraded), do: "degraded"
  defp status_label(:unhealthy), do: "unhealthy"
  defp status_label(:unknown), do: "unknown"
  defp status_label(other), do: to_string(other)

  defp check_title(:database_latency), do: "Database latency"
  defp check_title(:migrations), do: "Migration version"
  defp check_title(:oban), do: "Oban availability"
  defp check_title(:oldest_available_job), do: "Oldest available job"
  defp check_title(:discarded_jobs), do: "Discarded jobs"
  defp check_title(:schedule_lag), do: "Due schedule lag"
  defp check_title(:stale_attempts), do: "Stale attempts"
  defp check_title(:missing_jobs), do: "Missing jobs"
  defp check_title(:cleanup_lag), do: "Cleanup lag"
  defp check_title(name), do: Phoenix.Naming.humanize(name)

  defp format_value(%{unit: "ms", value: value}) when is_integer(value), do: format_ms(value)
  defp format_value(%{value: value, unit: unit}) when not is_nil(value), do: "#{value} #{unit}"
  defp format_value(_check), do: ""

  defp format_ms(ms) when is_integer(ms) and ms >= 3_600_000 do
    "#{div(ms, 3_600_000)}h"
  end

  defp format_ms(ms) when is_integer(ms) and ms >= 60_000 do
    "#{div(ms, 60_000)}m"
  end

  defp format_ms(ms) when is_integer(ms), do: "#{ms}ms"
  defp format_ms(_ms), do: ""

  defp sample_dom_id(%{kind: :execution, id: id}), do: "sample-execution-#{id}"
  defp sample_dom_id(%{kind: :job, id: id}), do: "sample-job-#{id}"
  defp sample_dom_id(%{kind: :schedule, id: id}), do: "sample-schedule-#{id}"
  defp sample_dom_id(_sample), do: "sample-unknown"
end
